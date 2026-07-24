# Infrastructure Setup — Rocky Linux

## 1. Fast Deployment

Run on a clean Rocky Linux 9 server:

```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/rocky/setup.sh | bash
```

The script will prompt for:
- **GitHub Email** — used for SSH key generation hint
- **Cloudflare Tunnel Name** — choose any name, default is `infra-tunnel`
- **Domain** — if provided, ingress will be auto-generated. Leave blank to skip
- **SSH Username** — default is current user
- **Only SSH via Cloudflare Tunnel?** — default `y` (no direct port 22, tunnel-only)
- **Deploy Webhook Token** — auto-generated if left blank

## 2. Services

| Service             | URL                      |
| ------------------- | ------------------------ |
| Portainer           | https://localhost:9443   |
| Uptime Kuma         | http://localhost:3001    |
| Deploy Webhook      | http://localhost:9000    |

If a domain is provided, services are accessible via Cloudflare Tunnel:
- `portainer.<YOUR_DOMAIN>`
- `uptime.<YOUR_DOMAIN>`
- `deploy.<YOUR_DOMAIN>`

Watchtower auto-updates all labeled containers daily at 04:00 (fallback). Deploy Webhook provides on-demand triggers from CI/CD.

## 3. CI/CD with GitHub Actions (Webhook)

Deploy via HTTP POST instead of SSH — no public SSH port needed.

### Setup

1. Add **repository secret** `DEPLOY_WEBHOOK_TOKEN` with the token printed at setup end
2. Add **repository variable** `DEPLOY_DOMAIN` = `deploy.<YOUR_DOMAIN>`

### Workflow

In your app repo's `.github/workflows/deploy.yml`:

```yaml
- name: Deploy via webhook
  run: |
    curl -sf -X POST "https://deploy.${{ vars.DEPLOY_DOMAIN }}/hooks/deploy" \
      -H "X-Deploy-Token: ${{ secrets.DEPLOY_WEBHOOK_TOKEN }}" \
      -H "Content-Type: application/json" \
      -d "{\"image_tag\": \"${{ steps.tag.outputs.tag }}\"}"
```

The webhook runs `deploy.sh` on the server which executes `docker compose pull && up -d` with the specified tag.

### Manual test

```bash
curl -X POST https://deploy.<YOUR_DOMAIN>/hooks/deploy \
  -H "X-Deploy-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{"image_tag": "v1.0.0"}'
```

## 4. Remote SSH Access (Client Setup)

SSH into the server from any machine via Cloudflare Tunnel ingress (`ssh.<YOUR_DOMAIN>` → `ssh://localhost:22`).

### Step 1 — Verify DNS record

```bash
dig ssh.<YOUR_DOMAIN>
```

Must show a CNAME to `*.cfargotunnel.com`. If missing:

```bash
cloudflared tunnel route dns <TUNNEL_NAME> ssh.<YOUR_DOMAIN>
```

### Step 2 — Generate SSH key on your local machine

```bash
ssh-keygen -t ed25519 -C "your@email.com"
cat ~/.ssh/id_ed25519.pub
```

Copy the output and add it to the server's `~/.ssh/authorized_keys` (via VPS console or initial access).

### Step 3 — Connect via tunnel

```bash
ssh <SSH_USER>@ssh.<YOUR_DOMAIN>
```

No `cloudflared` client installation needed — Cloudflare Tunnel handles the connection transparently as long as the ingress rule `ssh://localhost:22` is active.

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

The setup script opens necessary ports via `firewalld`:
- `9443/tcp` — Portainer
- `3001/tcp` — Uptime Kuma
- `22/tcp` — only if SSH port exposure is enabled during setup

All changes are persistent across reboots. Port `9000` (webhook) is not exposed — accessed only via Cloudflare Tunnel.

## 7. Note

This is the **rocky** branch. For Ubuntu, use the `ubuntu` branch instead.
