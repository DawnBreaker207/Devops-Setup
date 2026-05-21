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

## 4. Remote SSH Access (Client Setup)

SSH into the home server from any machine via Cloudflare Tunnel — no open ports or NAT required.

### Step 1 — Verify DNS record exists on the server

Before setting up the client, confirm the DNS CNAME for `ssh.<YOUR_DOMAIN>` has been registered. Run this on the **server**:

```bash
dig ssh.<YOUR_DOMAIN>
```

The output must have an `ANSWER SECTION` with a CNAME pointing to `*.cfargotunnel.com`. If you see `NXDOMAIN` (no answer), the record is missing — register it manually:

```bash
cloudflared tunnel route dns <TUNNEL_NAME> ssh.<YOUR_DOMAIN>
```

> **Common mistake:** the domain you see in the output log may differ from what you typed. For example, `cloudflared tunnel route dns VPS ssh.dawn.io.com` might actually create `ssh.dawn.io.vn` if your registered domain is `dawn.io.vn`. Always read the log line carefully:
> ```
> INF Added CNAME ssh.dawn.io.vn which will route to this tunnel
> ```
> Use the domain from that log line everywhere below, not what you typed.

---

### Step 2 — Install `cloudflared` on the client machine

**Linux (Debian/Ubuntu)**
```bash
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
```

Verify:
```bash
cloudflared --version
```

**macOS**
```bash
brew install cloudflare/cloudflare/cloudflared
```

**Windows** — download the installer from [cloudflare/cloudflared releases](https://github.com/cloudflare/cloudflared/releases/latest), run it, then open a new PowerShell window and verify:
```powershell
cloudflared --version
```

---

### Step 3 — Generate SSH key pair on the client

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "your@email.com"
```

When prompted, press **Enter** three times to accept defaults (do not type a path manually):

```
Enter file in which to save the key (/home/youruser/.ssh/id_ed25519): [Enter]
Enter passphrase (empty for no passphrase): [Enter]
Enter same passphrase again: [Enter]
```

Verify both files were created:
```bash
ls ~/.ssh/
# Expected: id_ed25519  id_ed25519.pub
```

> **Note:** When `ssh-keygen` asks for the file path interactively, do not type `~/.ssh/id_ed25519` — the shell does not expand `~` here and the command will fail with `No such file or directory`. Just press Enter to use the default.

---

### Step 4 — Add the client public key to the server

Print your public key:
```bash
cat ~/.ssh/id_ed25519.pub
```

Copy the entire output, then on the **server** run:
```bash
echo "paste_your_public_key_here" >> ~/.ssh/authorized_keys
```

The setup script pre-creates `~/.ssh/authorized_keys` with correct permissions, so no `chmod` is needed.

---

### Step 5 — Configure SSH on the client

```bash
nano ~/.ssh/config
```

Paste the following, replacing the placeholders:

```ssh-config
Host ssh.<YOUR_DOMAIN>
  HostName ssh.<YOUR_DOMAIN>
  User <SSH_USER>
  IdentityFile ~/.ssh/id_ed25519
  ProxyCommand cloudflared access ssh --hostname %h
```

- `<YOUR_DOMAIN>` — the actual domain from the DNS log in Step 1 (e.g. `domain.gg`)
- `<SSH_USER>` — your Linux username on the server (e.g. `dawnbreaker`)

Save: `Ctrl+O` → `Enter` → `Ctrl+X`, then lock down permissions:

```bash
chmod 600 ~/.ssh/config
```

**Windows** — create the file at `C:\Users\<youruser>\.ssh\config` using Notepad or VSCode. The `ProxyCommand` line must include the full path to `cloudflared.exe` if it contains spaces:

```ssh-config
Host ssh.<YOUR_DOMAIN>
  HostName ssh.<YOUR_DOMAIN>
  User <SSH_USER>
  IdentityFile ~/.ssh/id_ed25519
  ProxyCommand "C:\Program Files\cloudflared\cloudflared.exe" access ssh --hostname %h
```

Find the correct path with:
```powershell
where.exe cloudflared
```

---

### Step 6 — Connect

```bash
ssh ssh.<YOUR_DOMAIN>
```

`cloudflared` intercepts the connection and routes it through the Cloudflare Tunnel transparently. No ports need to be open on the router.

#### Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `Could not resolve hostname` | DNS record missing or wrong domain | Re-check Step 1, use the domain from the CNAME log |
| `Connection refused` | `sshd` not running on server | `sudo systemctl start ssh` on server |
| `Permission denied (publickey)` | Public key not in `authorized_keys` | Re-do Step 4 |
| `too many arguments` (Windows) | Space in `cloudflared.exe` path, missing quotes | Wrap full path in double quotes in `ProxyCommand` |

---

## 5. CI/CD Pipeline

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