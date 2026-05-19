# Infrastructure Setup

## 1. Fast Deployment

Run this on a clean Ubuntu 24.04 LTS server:

```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/main/setup.sh | bash
```

The script will prompt for:

- **GitHub Email** — used to generate SSH key
- **Cloudflare Tunnel Name** — choose any name, default is `infra-tunnel`
- **Domain** — if provided, ingress will be auto-generated. Leave blank to skip

## 2. Services

| Service             | URL                    |
| ------------------- | ---------------------- |
| Jenkins             | http://localhost:8080  |
| Portainer           | https://localhost:9443 |
| Nginx Proxy Manager | http://localhost:81    |
| Uptime Kuma         | http://localhost:3001  |

If a domain is provided, all services will be accessible via Cloudflare Tunnel at:

- `jenkins.<YOUR_DOMAIN>`
- `portainer.<YOUR_DOMAIN>`
- `npm.<YOUR_DOMAIN>`
- `uptime.<YOUR_DOMAIN>`

## 3. Jenkins Initialization

Unlock password:

```bash
sudo docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

Required Credentials — go to **Manage Jenkins → Credentials → Add**:

| ID                | Type            | Value                              |
| ----------------- | --------------- | ---------------------------------- |
| `Github-key`      | SSH Private Key | content of `~/.ssh/id_ed25519`     |
| `pro.env`         | Secret File     | upload your production `.env` file |
| `discord-webhook` | Secret text     | Discord Webhook URL                |

## 4. CI/CD Pipeline

### Step 1 — Create `deploy.config` in your project repo

Place this file at the root of each repo you want to deploy:

```ini
# deploy.config
REPO_URL    = git@github.com:yourusername/project.git
BRANCH      = main
COMPOSE_DIR = infra
ENV_FILE_ID = pro.env
APP_PORT    = 8888
APP_NAME    = Example
```

| Key           | Description                                        |
| ------------- | -------------------------------------------------- |
| `REPO_URL`    | SSH URL of the repo — must start with `git@`       |
| `BRANCH`      | Branch to deploy, default is `main`                |
| `COMPOSE_DIR` | Directory containing `docker-compose.yml`          |
| `ENV_FILE_ID` | Credential ID of the `.env` file stored in Jenkins |
| `APP_PORT`    | Port the app exposes for health check              |
| `APP_NAME`    | Name displayed in Discord notifications            |

### Step 2 — Create a Jenkins Pipeline job

New Item → Pipeline → paste the following script into the **Pipeline script** field:

```groovy
pipeline {
    agent any

    parameters {
        string(name: 'REPO_URL',       defaultValue: '', description: 'Override: Git SSH URL')
        string(name: 'BRANCH',         defaultValue: '', description: 'Override: Branch to deploy')
        string(name: 'COMPOSE_DIR',    defaultValue: '', description: 'Override: Directory containing docker-compose.yml')
        string(name: 'ENV_FILE_ID',    defaultValue: '', description: 'Override: Jenkins credential ID for .env file')
        string(name: 'APP_PORT',       defaultValue: '', description: 'Override: App port for health check')
        string(name: 'APP_NAME',       defaultValue: '', description: 'Override: App name for Discord notification')
    }

    environment {
        DISCORD_WEBHOOK = credentials('discord-webhook')
    }

    stages {
        stage('Load Config') {
            steps {
                script {
                    def config = [:]

                    if (fileExists('deploy.config')) {
                        readFile('deploy.config').split('\n').each { line ->
                            line = line.trim()
                            if (line && !line.startsWith('#')) {
                                def parts = line.split('=', 2)
                                if (parts.size() == 2) {
                                    config[parts[0].trim()] = parts[1].trim()
                                }
                            }
                        }
                    }

                    env.CFG_REPO_URL    = params.REPO_URL    ?: config.REPO_URL    ?: error('REPO_URL is required')
                    env.CFG_BRANCH      = params.BRANCH      ?: config.BRANCH      ?: 'main'
                    env.CFG_COMPOSE_DIR = params.COMPOSE_DIR ?: config.COMPOSE_DIR ?: 'infra'
                    env.CFG_ENV_FILE_ID = params.ENV_FILE_ID ?: config.ENV_FILE_ID ?: 'pro.env'
                    env.CFG_APP_PORT    = params.APP_PORT    ?: config.APP_PORT    ?: '8080'
                    env.CFG_APP_NAME    = params.APP_NAME    ?: config.APP_NAME    ?: 'App'

                    echo "====== Deploy Config ======"
                    echo "Repo       : ${env.CFG_REPO_URL}"
                    echo "Branch     : ${env.CFG_BRANCH}"
                    echo "Compose Dir: ${env.CFG_COMPOSE_DIR}"
                    echo "Env File ID: ${env.CFG_ENV_FILE_ID}"
                    echo "App Port   : ${env.CFG_APP_PORT}"
                    echo "App Name   : ${env.CFG_APP_NAME}"
                    echo "==========================="
                }
            }
        }

        stage('Checkout') {
            steps {
                git branch: "${env.CFG_BRANCH}",
                    url: "${env.CFG_REPO_URL}",
                    credentialsId: 'Github-key'
            }
        }

        stage('Deploy') {
            steps {
                withCredentials([file(credentialsId: "${env.CFG_ENV_FILE_ID}", variable: 'ENV_FILE')]) {
                    script {
                        sh "cp \$ENV_FILE ${env.CFG_COMPOSE_DIR}/.env"
                        sh "chmod -R 755 ${env.CFG_COMPOSE_DIR}/docker || true"
                        dir("${env.CFG_COMPOSE_DIR}") {
                            sh 'ls -la'
                            sh 'docker compose down --remove-orphans || true'
                            sh 'docker compose up -d --build'
                        }
                    }
                }
            }
        }

        stage('Health Check') {
            steps {
                script {
                    def maxRetries = 10
                    def retryInterval = 10
                    def healthy = false

                    for (int i = 1; i <= maxRetries; i++) {
                        echo "Health check attempt ${i}/${maxRetries}..."
                        def status = sh(
                            script: "curl -s -o /dev/null -w \"%{http_code}\" http://localhost:${env.CFG_APP_PORT} || echo '000'",
                            returnStdout: true
                        ).trim()

                        if (status == '200' || status == '302') {
                            echo "Service is up! (HTTP ${status})"
                            healthy = true
                            break
                        }

                        echo "Not ready yet (HTTP ${status}). Waiting ${retryInterval}s..."
                        sleep retryInterval
                    }

                    if (!healthy) {
                        error("Service failed to start after ${maxRetries} attempts.")
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
            script {
                sh """
                    curl -s -X POST "$DISCORD_WEBHOOK" \
                    -H "Content-Type: application/json" \
                    -d '{
                        "embeds": [{
                            "title": "✅ Deployment Successful",
                            "description": "**${env.CFG_APP_NAME}** deployed successfully.",
                            "color": 3066993,
                            "fields": [
                                { "name": "Branch", "value": "${env.CFG_BRANCH}", "inline": true },
                                { "name": "Build", "value": "#${env.BUILD_NUMBER}", "inline": true }
                            ],
                            "footer": { "text": "Jenkins CI/CD" }
                        }]
                    }'
                """
            }
        }
        failure {
            script {
                sh """
                    curl -s -X POST "$DISCORD_WEBHOOK" \
                    -H "Content-Type: application/json" \
                    -d '{
                        "embeds": [{
                            "title": "❌ Deployment Failed",
                            "description": "**${env.CFG_APP_NAME}** deployment failed. Check Jenkins logs.",
                            "color": 15158332,
                            "fields": [
                                { "name": "Branch", "value": "${env.CFG_BRANCH}", "inline": true },
                                { "name": "Build", "value": "#${env.BUILD_NUMBER}", "inline": true },
                                { "name": "Logs", "value": "${env.BUILD_URL}console", "inline": false }
                            ],
                            "footer": { "text": "Jenkins CI/CD" }
                        }]
                    }'
                """
            }
        }
    }
}
```

### Step 3 — Override when triggering manually (optional)

When building with **Build with Parameters**, any field left empty will fall back to values from `deploy.config`. Only fill in fields you want to override — for example, deploying a different branch without editing the config file.
