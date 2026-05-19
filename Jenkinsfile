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