# Infrastructure Setup — Rocky Linux

## 1. Fast Deployment

Run on a clean Rocky Linux 9 server:

```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/rocky/setup.sh | bash
```

The script will prompt for:
- **GitHub Email** — used to generate SSH key for GitHub Actions
- **Cloudflare Tunnel Name** — choose any name, default is `infra-tunnel`
- **Domain** — if provided, ingress will be auto-generated. Leave blank to skip

## 2. Services

| Service             | URL                    |
| ------------------- | ---------------------- |
| Portainer           | https://localhost:9443 |
| Uptime Kuma         | http://localhost:3001  |

If a domain is provided, services are accessible via Cloudflare Tunnel:
- `portainer.<YOUR_DOMAIN>`
- `uptime.<YOUR_DOMAIN>`

Watchtower auto-updates all containers daily at 04:00.

## 3. CI/CD with GitHub Actions

This branch uses **GitHub Actions** instead of Jenkins. After setup completes:

```bash
# Create a deploy key
ssh-keygen -t ed25519 -C "github-actions"
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
```

Add the private key to your GitHub repo: **Settings → Secrets and variables → Actions → New secret** named `SSH_KEY`.

Create `.github/workflows/deploy.yml` in your app repo:

```yaml
name: Deploy
on: [push]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.HOST }}
          username: ${{ secrets.USER }}
          key: ${{ secrets.SSH_KEY }}
          script: |
            cd /path/to/project
            git pull
            docker compose up -d --build
```

View build logs on GitHub → **Actions** tab → click the workflow run.

## 4. Remote SSH Access (Client Setup)

SSH into the server from any machine via Cloudflare Tunnel.

### Step 1 — Verify DNS record

```bash
dig ssh.<YOUR_DOMAIN>
```

Must show a CNAME to `*.cfargotunnel.com`. If missing:

```bash
cloudflared tunnel route dns <TUNNEL_NAME> ssh.<YOUR_DOMAIN>
```

### Step 2 — Install `cloudflared` on the client

**Linux (Rocky/RHEL)**
```bash
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm -o /tmp/cloudflared.rpm
sudo rpm -i /tmp/cloudflared.rpm
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
```

Copy output, then on the **server**:

```bash
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

**Windows** — use full path to `cloudflared.exe` in `ProxyCommand`.

### Step 6 — Connect

```bash
ssh ssh.<YOUR_DOMAIN>
```

### Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Could not resolve hostname` | DNS record missing | Re-check DNS |
| `Connection refused` | sshd not running | `sudo systemctl start sshd` |
| `Permission denied` | Key not authorized | Re-add public key |
| SELinux denial | Container bind mount | Already handled by setup script |

## 5. SELinux Notes

Rocky Linux has SELinux enforcing by default. The setup script automatically applies `container_file_t` context to all bind-mounted directories. If you add custom bind mounts:

```bash
sudo chcon -Rt container_file_t /path/to/bind/mount
```

## 6. Firewall

The setup script opens necessary ports via `firewalld`. All changes are persistent across reboots.

## 7. Note

This is the **rocky** branch. For Ubuntu, use the `ubuntu` branch instead.
