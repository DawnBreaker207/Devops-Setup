# Infrastructure Setup

## 1. Fast Deployment

Run this on a clean Ubuntu 24.04 LTS server:

```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/main/setup.sh | bash
```

## 2. Jenkins Initialization

- Unlock Password:

```bash
sudo docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

- Required Credentials:
  - Github-key: SSH Private Key (for repository access).
  - pro.env: Secret File (upload your production .env).

## 3. CI/CD Pipeline

Create a Jenkins Pipeline job and use the following script:

```groovy
pipeline {
    agent any

    stages {
        stage('Checkout') {
            steps {
                git branch: 'main',
                    url: 'git@github.com:tunganhngo207/CinePlex.git',
                    credentialsId: 'Github-key'
            }
        }

        stage('Deploy') {
            steps {
                withCredentials([file(credentialsId: 'pro.env', variable: 'ENV_FILE')]) {
                    script {
                        sh 'cp $ENV_FILE infra/.env'
                        sh 'chmod -R 755 infra/docker || true'
                        dir('infra') {
                            sh 'ls -la'
                            sh 'docker compose down --remove-orphans || true'
                            sh 'docker compose up -d --build'
                        }
                    }
                }
            }
        }
    }
    post {
        always {
            sh 'docker image prune -f'
        }
        success {
            echo 'Deployment completed successfully!'
        }
        failure {
            echo 'Deployment failed. Please check the logs.'
        }
    }
}
```

## 4. Optional: Expose via Ngrok

```bash
docker run -d --name ngrok --restart always --network infra_network \
  -e NGROK_AUTHTOKEN=<YOUR_TOKEN> \
  ngrok/ngrok:latest http jenkins:8080
```
