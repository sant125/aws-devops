locals {
  name_prefix = var.project_name

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

# ─── VPC ────────────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs            = var.availability_zones
  public_subnets = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 8, i)]

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags exigidas pelo EKS/Karpenter para descoberta de subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${local.name_prefix}" = "owned"
  }

  tags = local.tags
}

# ─── S3 (backup CloudNativePG) ───────────────────────────────────────────────
module "s3_backup" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.name_prefix}-cnpg-backup"

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "expire-old-backups"
      enabled = true
      expiration = {
        days = 30
      }
    }
  ]

  tags = local.tags
}

# ─── S3 (reports CI/CD) ──────────────────────────────────────────────────────
module "s3_reports" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.name_prefix}-reports"

  # Reports são temporários — expira após 90 dias
  lifecycle_rule = [
    {
      id      = "expire-reports"
      enabled = true
      expiration = {
        days = 90
      }
    }
  ]

  tags = local.tags
}

# ─── IAM role para Jenkins agent (ECR push + S3 reports) ─────────────────────
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "jenkins_agent" {
  name = "${local.name_prefix}-jenkins-agent"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:jenkins:jenkins-agent"
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "jenkins_agent" {
  name = "jenkins-agent-policy"
  role = aws_iam_role.jenkins_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = "*"
      },
      {
        Sid    = "S3Reports"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          module.s3_reports.s3_bucket_arn,
          "${module.s3_reports.s3_bucket_arn}/*",
        ]
      }
    ]
  })
}

# ─── ECR ─────────────────────────────────────────────────────────────────────
module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 2.0"

  repository_name = "${local.name_prefix}-app"

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Manter apenas as últimas 10 imagens"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })

  tags = local.tags
}

# ─── IAM ROLE para nós (Karpenter precisa antes do cluster) ──────────────────
resource "aws_iam_role" "karpenter_node" {
  name = "${local.name_prefix}-karpenter-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

# ─── EKS ─────────────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${local.name_prefix}-cluster"
  cluster_version = var.eks_cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  # Endpoint público para acesso via kubectl
  cluster_endpoint_public_access = true

  # Sem node group gerenciado — Karpenter cuida dos nós
  eks_managed_node_groups = {}

  # Add-ons essenciais
  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    aws-ebs-csi-driver     = { most_recent = true }
  }

  # IRSA habilitado para Karpenter, ALB Controller, etc.
  enable_irsa = true

  # Access entry para que os nós do Karpenter consigam se registrar
  access_entries = {
    karpenter_node = {
      kubernetes_groups = []
      principal_arn     = aws_iam_role.karpenter_node.arn
      type              = "EC2_LINUX"
    }
  }

  tags = local.tags
}

# ─── KARPENTER (IAM + SQS + EventBridge) ─────────────────────────────────────
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name           = module.eks.cluster_name
  irsa_oidc_provider_arn = module.eks.oidc_provider_arn

  # Reutiliza a role de nó criada acima
  create_node_iam_role = false
  node_iam_role_arn    = aws_iam_role.karpenter_node.arn

  tags = local.tags
}

# ─── KARPENTER CONTROLLER (Helm) ─────────────────────────────────────────────
resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.1.1"

  values = [
    jsonencode({
      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = module.karpenter.iam_role_arn
        }
      }
      controller = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
    })
  ]

  depends_on = [module.eks]
}
