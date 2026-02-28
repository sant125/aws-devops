output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas"
  value       = module.vpc.public_subnets
}

output "eks_cluster_name" {
  description = "Nome do cluster EKS"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Endpoint da API do EKS"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority" {
  description = "CA do cluster (usado no kubeconfig)"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "ecr_repository_url" {
  description = "URL do repositório ECR"
  value       = module.ecr.repository_url
}

output "s3_backup_bucket" {
  description = "Nome do bucket S3 de backup"
  value       = module.s3_backup.s3_bucket_id
}

output "karpenter_iam_role_arn" {
  description = "IAM Role ARN do controller Karpenter (IRSA)"
  value       = module.karpenter.iam_role_arn
}

output "karpenter_node_role_name" {
  description = "Nome da IAM Role dos nós gerenciados pelo Karpenter — usar no EC2NodeClass"
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_queue_name" {
  description = "Nome da fila SQS para interrupção Spot"
  value       = module.karpenter.queue_name
}

output "s3_reports_bucket" {
  description = "Bucket S3 para reports de CI/CD (lint, cobertura, vuln, ZAP)"
  value       = module.s3_reports.s3_bucket_id
}

output "jenkins_agent_role_arn" {
  description = "IAM Role ARN do Jenkins agent — atualizar em manifests/jenkins/values.yaml"
  value       = aws_iam_role.jenkins_agent.arn
}
