# System Requirements
- OS: Ubuntu Server 24.04 LTS.
- Resources: 2 vCPUs, 4GB RAM (Minimum).
- Storage: 30GB+ SSD.

#  Architecture: Docker-out-of-Docker (DooD)
Unlike traditional Jenkins setups, we mount the host's /var/run/docker.sock into the Jenkins container. This allows Jenkins to spin up "sibling" containers on the host, avoiding the overhead and complexity of "Docker-in-Docker" (DinD).

# Automatic Environment Setup
Run the provided setup-lab.sh script (see Part 2). This script automates:

1. **System Updates**: Essential packages and security patches.
2. **4GB Swap File**: Crucial for preventing "Out of Memory" (OOM) crashes on 4GB RAM systems.
3. **Docker Engine**: Clean installation of Docker and Docker Compose V2.
4. **Path Alignment**: Symbolic linking /var/jenkins_home to ensure host-container path parity (Fixes the "Mounting directory onto file" error).
5. **Socket Persistence**: Automated udev/crontab rules to keep Docker accessible to Jenkins after reboots.
6. **Jenkins DooD**: Launching Jenkins with optimized volume mappings and internal Docker CLI tools.

# Jenkins Configuration
1. **Unlock Jenkins**: Retrieve the initial password:
   ```bash
   sudo docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
   ```
3. **Plugins**: Install "Suggested Plugins" + "Pipeline" + "Git".
4. **Credentials**:
Github-key: SSH Private Key for repository access.
pro.env: Secret File (Upload your .env file).

#  Ngrok for Webhooks
To receive GitHub Webhooks on a local VM, run Ngrok with a static domain (to avoid URL changes):

```bash
  docker run -d --name ngrok --restart always \
  -e NGROK_AUTHTOKEN=<YOUR_TOKEN> \
  ngrok/ngrok:latest http 192.168.x.x:8080 --domain=your-static-id.ngrok-free.app
```

# Optimized Jenkins Pipeline
```groovy
pipeline {
    agent any
    stages {
        stage('Checkout') {
            steps {
                git branch: 'main', url: 'git@github.com:USER/REPO.git', credentialsId: 'Github-key'
            }
        }
        stage('Deploy') {
            steps {
                withCredentials([file(credentialsId: 'pro.env', variable: 'ENV_FILE')]) {
                    script {
                        sh 'cp $ENV_FILE infra/.env'
                        sh 'chmod -R 755 infra/docker || true'
                        
                        dir('infra') {
                            sh 'docker compose down --remove-orphans || true'
                            sh 'docker compose up -d --build'
                        }
                    }
                }
            }
        }
    }
    post {
        success { sh 'docker image prune -f' }
    }
}
```
