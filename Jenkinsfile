// Jenkinsfile — gin-tattoo
// Referência: este arquivo vai na raiz do repositório sant125/gin-tattoo
//
// Fluxo por branch:
//   feature/*  → lint · test · vuln · sonar · quality gate · reports → S3
//   developer  → tudo acima + build → ECR + update manifest + ZAP → homolog + reports → S3
//   main       → tudo acima (sem ZAP) + update manifest → prod + reports → S3

def ECR_URL    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/projetin-app"
def S3_REPORTS = "s3://projetin-reports/${env.BRANCH_NAME}/${env.BUILD_NUMBER}"
def DEPLOY_NS  = env.BRANCH_NAME == 'main' ? 'prod' : 'homolog'
def IMAGE_TAG  = env.BRANCH_NAME == 'main'
                   ? env.GIT_COMMIT[0..6]
                   : "dev-${env.GIT_COMMIT[0..6]}"

pipeline {
  agent {
    kubernetes {
      yaml """
apiVersion: v1
kind: Pod
spec:
  tolerations:
    - key: workload
      operator: Equal
      value: spot
      effect: NoSchedule
  nodeSelector:
    capacity-type: spot
  containers:
    - name: golang
      image: golang:1.22-alpine
      command: [sleep]
      args: [infinity]
      env:
        - name: GOPATH
          value: /go
        - name: GOFLAGS
          value: -mod=readonly
    - name: docker
      image: docker:24-dind
      securityContext:
        privileged: true
      volumeMounts:
        - name: docker-sock
          mountPath: /var/run/docker.sock
    - name: sonar
      image: sonarsource/sonar-scanner-cli:5
      command: [sleep]
      args: [infinity]
    - name: kubectl
      image: dtzar/helm-kubectl:latest   # inclui kubectl + helm + yq + git
      command: [sleep]
      args: [infinity]
    - name: zap
      image: ghcr.io/zaproxy/zaproxy:stable
      command: [sleep]
      args: [infinity]
      volumeMounts:
        - name: reports
          mountPath: /zap/wrk
  volumes:
    - name: docker-sock
      hostPath:
        path: /var/run/docker.sock
    - name: reports
      emptyDir: {}
"""
    }
  }

  options {
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  stages {

    stage('Lint') {
      steps {
        container('golang') {
          sh '''
            mkdir -p reports
            go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
            golangci-lint run --out-format json ./... > reports/lint.json 2>&1 || true
          '''
        }
      }
    }

    stage('Test') {
      steps {
        container('golang') {
          sh '''
            go test ./... \
              -coverprofile=reports/coverage.out \
              -json > reports/test.json 2>&1
            go tool cover -html=reports/coverage.out -o reports/coverage.html
          '''
        }
      }
    }

    // govulncheck e Trivy rodando em paralelo
    stage('Vulnerability Scan') {
      parallel {
        stage('govulncheck') {
          steps {
            container('golang') {
              sh '''
                go install golang.org/x/vuln/cmd/govulncheck@latest
                govulncheck -json ./... > reports/govulncheck.json 2>&1 || true
              '''
            }
          }
        }
        stage('Trivy') {
          steps {
            container('docker') {
              sh """
                docker run --rm \
                  -v /var/run/docker.sock:/var/run/docker.sock \
                  -v \$(pwd)/reports:/reports \
                  aquasec/trivy:latest fs \
                  --format json \
                  --output /reports/trivy-fs.json \
                  . || true
              """
            }
          }
        }
      }
    }

    stage('SonarQube') {
      steps {
        container('sonar') {
          withSonarQubeEnv('sonarqube') {
            sh '''
              sonar-scanner \
                -Dsonar.projectKey=gin-tattoo \
                -Dsonar.sources=. \
                -Dsonar.go.coverage.reportPaths=reports/coverage.out \
                -Dsonar.go.tests.reportPaths=reports/test.json
            '''
          }
        }
      }
    }

    stage('Quality Gate') {
      steps {
        timeout(time: 5, unit: 'MINUTES') {
          // Bloqueia o pipeline se o quality gate falhar
          waitForQualityGate abortPipeline: true
        }
      }
    }

    stage('Build & Push') {
      when { not { branch 'feature/*' } }
      steps {
        container('docker') {
          sh """
            aws ecr get-login-password --region us-east-1 \
              | docker login --username AWS --password-stdin ${ECR_URL}
            docker build -t ${ECR_URL}:${IMAGE_TAG} .
            docker push ${ECR_URL}:${IMAGE_TAG}

            # Trivy na imagem final
            docker run --rm \
              -v /var/run/docker.sock:/var/run/docker.sock \
              -v \$(pwd)/reports:/reports \
              aquasec/trivy:latest image \
              --format json \
              --output /reports/trivy-image.json \
              ${ECR_URL}:${IMAGE_TAG} || true
          """
        }
      }
    }

    // Atualiza o manifest no repositório de infra — ArgoCD sincroniza o resto
    stage('Update GitOps') {
      when { not { branch 'feature/*' } }
      steps {
        container('kubectl') {
          withCredentials([string(credentialsId: 'github-token', variable: 'GH_TOKEN')]) {
            sh """
              git clone https://\${GH_TOKEN}@github.com/sant125/aws-devops.git /tmp/infra
              cd /tmp/infra

              # yq atualiza só o campo .spec.template.spec.containers[0].image
              # sed seria frágil se o manifest tiver múltiplos containers ou mudar de formato
              yq e '.spec.template.spec.containers[0].image = "${ECR_URL}:${IMAGE_TAG}"' \
                -i manifests/gin-tattoo-${DEPLOY_NS}/deployment.yaml

              git config user.email "jenkins@ci.local"
              git config user.name "Jenkins"
              git commit -am "ci: gin-tattoo → ${IMAGE_TAG} [${DEPLOY_NS}]"
              git push
            """
          }
        }
      }
    }

    // ZAP roda contra o namespace que este build deployou
    // developer → homolog.svc  |  main → prod.svc
    stage('Dynamic — OWASP ZAP') {
      when { not { branch 'feature/*' } }
      steps {
        container('zap') {
          sh """
            zap-baseline.py \
              -t http://gin-tattoo.${DEPLOY_NS}.svc.cluster.local \
              -r /zap/wrk/reports/zap.html \
              -J /zap/wrk/reports/zap.json \
              -x /zap/wrk/reports/zap.xml \
              -I
          """
          // -I: não falha por alertas informativos — bloqueia só HIGH/MEDIUM
        }
      }
    }

    stage('Publish Reports → S3') {
      steps {
        container('kubectl') {
          sh """
            aws s3 cp reports/ ${S3_REPORTS}/ \
              --recursive \
              --exclude '*' \
              --include '*.json' \
              --include '*.html' \
              --include '*.xml'

            # Gera índice simples com links dos reports
            cat > /tmp/index.html <<EOF
<html><body>
<h2>gin-tattoo — ${env.BRANCH_NAME} #${env.BUILD_NUMBER}</h2>
<ul>
  <li><a href="lint.json">golangci-lint</a></li>
  <li><a href="test.json">go test</a></li>
  <li><a href="coverage.html">cobertura</a></li>
  <li><a href="govulncheck.json">govulncheck</a></li>
  <li><a href="trivy-fs.json">trivy (filesystem)</a></li>
  <li><a href="trivy-image.json">trivy (image)</a></li>
  <li><a href="zap.html">OWASP ZAP</a></li>
</ul>
</body></html>
EOF
            aws s3 cp /tmp/index.html ${S3_REPORTS}/index.html
          """
        }
      }
    }

  }

  post {
    always {
      archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
      echo "Reports: ${S3_REPORTS}/index.html"
    }
    failure {
      echo "Pipeline falhou — quality gate ou vuln crítica. Ver reports em ${S3_REPORTS}"
    }
  }
}
