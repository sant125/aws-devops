"""
Gera os diagramas de arquitetura do projeto gin-tattoo.
Requer: pip install diagrams && apt install graphviz

Uso: python3 docs/diagrams/generate.py
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EKS, ECR
from diagrams.aws.storage import S3
from diagrams.aws.management import SystemsManager
from diagrams.onprem.ci import Jenkins
from diagrams.onprem.gitops import ArgoCD
from diagrams.onprem.vcs import Github
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.monitoring import Prometheus, Grafana
from diagrams.onprem.security import Vault
from diagrams.k8s.compute import Deployment
from diagrams.k8s.network import Service
from diagrams.k8s.clusterconfig import HPA
from diagrams.programming.language import Go

GRAPH_ATTR = {
    "fontsize": "13",
    "bgcolor": "white",
    "pad": "1.0",
    "splines": "ortho",
    "nodesep": "0.6",
    "ranksep": "0.8",
}

OUT = "docs/diagrams"


# ── 1. Arquitetura Geral ──────────────────────────────────────────────────────
with Diagram(
    "gin-tattoo — Arquitetura Geral",
    filename=f"{OUT}/architecture",
    outformat="png",
    graph_attr=GRAPH_ATTR,
    direction="LR",
    show=False,
):
    github = Github("GitHub\ngin-tattoo + aws-devops")

    with Cluster("AWS"):
        ecr = ECR("ECR\ngin-tattoo")
        s3  = S3("S3\nCNPG backup")

        with Cluster("EKS Cluster"):
            with Cluster("jenkins"):
                jenkins = Jenkins("Jenkins\nMultibranch")

            with Cluster("argocd"):
                argocd = ArgoCD("ArgoCD\nApp-of-Apps")

            with Cluster("sonarqube"):
                sonar = Go("SonarQube")

            with Cluster("observability"):
                prom    = Prometheus("Prometheus")
                grafana = Grafana("Grafana")

            with Cluster("database"):
                pg = PostgreSQL("CloudNativePG\n3 instâncias HA")

            with Cluster("homolog"):
                app_hom = Deployment("gin-tattoo")

            with Cluster("prod"):
                app_prod = Deployment("gin-tattoo")

    github >> Edge(label="push") >> jenkins
    jenkins >> Edge(label="build & push") >> ecr
    jenkins >> Edge(label="atualiza manifest") >> github
    github >> Edge(label="gitops sync") >> argocd
    argocd >> app_hom
    argocd >> app_prod
    ecr >> app_hom
    ecr >> app_prod
    app_hom  >> Edge(label="schema: homolog") >> pg
    app_prod >> Edge(label="schema: prod")    >> pg
    sonar >> pg
    pg >> s3
    app_prod >> Edge(label="/metrics") >> prom
    app_hom  >> Edge(label="/metrics", style="dashed") >> prom
    prom >> grafana


# ── 2. Pipeline CI/CD ─────────────────────────────────────────────────────────
with Diagram(
    "gin-tattoo — Pipeline CI/CD",
    filename=f"{OUT}/pipeline",
    outformat="png",
    graph_attr={**GRAPH_ATTR, "splines": "curved"},
    direction="LR",
    show=False,
):
    with Cluster("feature/* — CI only"):
        feat    = Github("feature branch")
        ci_feat = Jenkins("vet · test\ngovulncheck · SonarQube\nTrivy")
        feat >> ci_feat

    with Cluster("developer — CI + Deploy homolog"):
        dev        = Github("developer")
        ci_dev     = Jenkins("vet · test\ngovulncheck · SonarQube\nTrivy")
        build_dev  = ECR("build & push\ndev-{sha}")
        deploy_dev = ArgoCD("sync → homolog")
        dev >> ci_dev >> build_dev >> deploy_dev

    with Cluster("main — CI + Deploy prod"):
        main        = Github("main")
        ci_main     = Jenkins("vet · test\ngovulncheck · SonarQube\nTrivy")
        build_main  = ECR("build & push\n{sha}")
        deploy_main = ArgoCD("sync → prod")
        main >> ci_main >> build_main >> deploy_main


# ── 3. Namespaces K8s ─────────────────────────────────────────────────────────
with Diagram(
    "gin-tattoo — Kubernetes Namespaces",
    filename=f"{OUT}/namespaces",
    outformat="png",
    graph_attr=GRAPH_ATTR,
    direction="TB",
    show=False,
):
    with Cluster("homolog"):
        dep_h = Deployment("gin-tattoo\n1 réplica")
        svc_h = Service("Service :80")
        hpa_h = HPA("HPA 1→3")
        dep_h - svc_h
        dep_h - hpa_h

    with Cluster("prod"):
        dep_p = Deployment("gin-tattoo\n2 réplicas")
        svc_p = Service("Service :80")
        hpa_p = HPA("HPA 2→10")
        dep_p - svc_p
        dep_p - hpa_p

    with Cluster("database"):
        primary = PostgreSQL("primary (rw)")
        r1      = PostgreSQL("replica 1 (ro)")
        r2      = PostgreSQL("replica 2 (ro)")
        primary >> r1
        primary >> r2

    with Cluster("observability"):
        prom    = Prometheus("Prometheus")
        grafana = Grafana("Grafana")
        prom >> grafana

    with Cluster("jenkins"):
        j = Jenkins("Jenkins")

    with Cluster("argocd"):
        a = ArgoCD("ArgoCD")

    dep_h >> Edge(label="homolog schema") >> primary
    dep_p >> Edge(label="prod schema")    >> primary
    dep_h >> Edge(label="/metrics") >> prom
    dep_p >> Edge(label="/metrics") >> prom
    j     >> Edge(style="dashed")   >> dep_h
    j     >> Edge(style="dashed")   >> dep_p
    a     >> dep_h
    a     >> dep_p


print("Gerado: docs/diagrams/architecture.png")
print("Gerado: docs/diagrams/pipeline.png")
print("Gerado: docs/diagrams/namespaces.png")
