# Infrastructure Setup — Ubuntu

## 1. Fast Deployment

Run on a clean Ubuntu 24.04 LTS server:

```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/ubuntu/setup.sh | bash
```

The script will prompt for:
- **GitHub Email** — used to generate SSH key for Jenkins
- **Cloudflare Tunnel Name** — choose any name, default is `infra-tunnel`
- **Domain** — if provided, ingress will be auto-generated. Leave blank to skip

## 2. Services

| Service             | URL                    |
| ------------------- | ---------------------- |
| Jenkins             | http://localhost:8080  |
| Portainer           | https://localhost:9443 |
| Nginx Proxy Manager | http://localhost:81    |
| Uptime Kuma         | http://localhost:3001  |

If a domain is provided, all services accessible via Cloudflare Tunnel:
- `jenkins.<YOUR_DOMAIN>`
- `portainer.<YOUR_DOMAIN>`
- `npm.<YOUR_DOMAIN>`
- `uptime.<YOUR_DOMAIN>`

Watchtower auto-updates all containers daily at 04:00.

## 3. Jenkins Initialization

Unlock password:

```bash
sudo docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

Required Credentials — **Manage Jenkins → Credentials → Add**:

| ID                | Type            | Value                              |
| ----------------- | --------------- | ---------------------------------- |
| `Github-key`      | SSH Private Key | content of `~/.ssh/id_ed25519`     |
| `pro.env`         | Secret File     | upload your production `.env` file |
| `discord-webhook` | Secret text     | Discord Webhook URL                |

## 4. CI/CD Pipeline

### Step 1 — Create `deploy.config` in your project repo

```ini
# deploy.config
REPO_URL    = git@github.com:yourusername/project.git
BRANCH      = main
COMPOSE_DIR = infra
ENV_FILE_ID = pro.env
APP_PORT    = 8888
APP_NAME    = Example
```

### Step 2 — Create a Jenkins Pipeline job

New Item → Pipeline → paste the Jenkinsfile from this repo into the **Pipeline script** field.

### Step 3 — Override when triggering manually (optional)

When building with **Build with Parameters**, leave fields empty to use `deploy.config` defaults.

## 5. Remote SSH Access (Client Setup)

SSH into the server from any machine via Cloudflare Tunnel.

### Step 1 — Verify DNS

```bash
dig ssh.<YOUR_DOMAIN>
```

Must show a CNAME to `*.cfargotunnel.com`. If missing:

```bash
cloudflared tunnel route dns <TUNNEL_NAME> ssh.<YOUR_DOMAIN>
```

### Step 2 — Install `cloudflared` on client

**Linux (Debian/Ubuntu)**
```bash
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
```

**macOS**
```bash
brew install cloudflare/cloudflare/cloudflared
```

**Windows** — download from [releases](https://github.com/cloudflare/cloudflared/releases/latest)

### Step 3 — Generate SSH key on client

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "your@email.com"
```

### Step 4 — Add public key to server

```bash
cat ~/.ssh/id_ed25519.pub
echo "paste_your_public_key_here" >> ~/.ssh/authorized_keys
```

### Step 5 — Configure SSH on client

```bash
nano ~/.ssh/config
```

```ssh-config
Host ssh.<YOUR_DOMAIN>
  HostName ssh.<YOUR_DOMAIN>
  User <SSH_USER>
  IdentityFile ~/.ssh/id_ed25519
  ProxyCommand cloudflared access ssh --hostname %h
```

### Step 6 — Connect

```bash
ssh ssh.<YOUR_DOMAIN>
```

### Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Could not resolve hostname` | DNS missing | Re-check DNS |
| `Connection refused` | sshd not running | `sudo systemctl start ssh` |
| `Permission denied` | Key not authorized | Re-add public key |

## 6. Note

This is the **ubuntu** branch. For Rocky Linux, use the `rocky` branch instead.
