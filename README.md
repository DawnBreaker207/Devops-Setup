# Infrastructure Setup — Rocky Linux

## 1. Fast Deployment

Run on a clean Rocky Linux 9 server:

```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/rocky/setup.sh | bash
```

The script will prompt for:
- **Cloudflare Tunnel Name** — default `infra-tunnel` (use a different name per VM)
- **Domain** — leave blank to skip tunnel ingress (e.g. example.com)
- **SSH subdomain** — default `ssh` (uses `<subdomain>.yourdomain.com`; use a different one per VM sharing a domain)
- **SSH username** — default current user
- **Expose SSH port 22 directly?** — `y/n`, default `n` (tunnel-only; opens `22/tcp` only on `y`)

On failure the script rolls back all changes automatically.

## 2. Services

| Service     | URL                    |
| ----------- | ---------------------- |
| Portainer   | https://localhost:9443 |
| Uptime Kuma | http://localhost:3001  |

Portainer and Uptime Kuma are LAN/localhost only (no public ingress). With a domain, the only public ingress is SSH admin access:
- `<SSH_SUBDOMAIN>.<YOUR_DOMAIN>` → `ssh://localhost:22` (default `ssh.<YOUR_DOMAIN>`)

## 3. CI/CD with GitHub Actions (self-hosted runner)

After setup, on the server run:

```bash
./install-runner.sh
```

It prompts for GitHub email, repo URL (blank = skip, prints an SSH key hint instead) and a runner registration token (repo Settings > Actions > Runners, expires in ~1h), then registers the runner as a systemd service (never as root).

Then in your app repo create `.github/workflows/deploy.yml`:

```yaml
name: Deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
      - run: docker compose build
      - run: docker compose up -d --force-recreate
```

## 4. Remote SSH Access (Client Setup)

SSH into the server from any machine via Cloudflare Tunnel ingress (`<SSH_SUBDOMAIN>.<YOUR_DOMAIN>` → `ssh://localhost:22`, default `ssh.<YOUR_DOMAIN>`).

### Step 1 — Verify DNS record

```bash
dig <SSH_SUBDOMAIN>.<YOUR_DOMAIN>
```
(default: `dig ssh.<YOUR_DOMAIN>`)

Must show a CNAME to `*.cfargotunnel.com`. If missing:

```bash
cloudflared tunnel route dns <TUNNEL_NAME> <SSH_SUBDOMAIN>.<YOUR_DOMAIN>
```

### Step 2 — Generate SSH key on your local machine

```bash
ssh-keygen -t ed25519 -C "your@email.com"
cat ~/.ssh/id_ed25519.pub
```

Copy the output and add it to the server's `~/.ssh/authorized_keys` (via VPS console or initial access).

### Step 3 — Connect via tunnel

```bash
ssh <SSH_USER>@<SSH_SUBDOMAIN>.<YOUR_DOMAIN>
```
(default: `ssh <SSH_USER>@ssh.<YOUR_DOMAIN>`)

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

The setup script opens `22/tcp` via `firewalld` only when SSH port exposure is enabled during setup (`y`). Nothing else is opened.

All changes are persistent across reboots.

## 7. Service Management

### Stop / Start an individual service

```bash
docker stop <container_name>
docker start <container_name>
```

Container names: `portainer`, `uptime-kuma`.

### Restart tunnel after config change

```bash
sudo systemctl restart cloudflared
```

### View logs

```bash
docker logs portainer
docker logs uptime-kuma
sudo journalctl -u cloudflared
```

### Clock drift

A wrong system clock breaks runner OAuth/token refresh (listener exits, service dead). Diagnose:

```bash
timedatectl status
chronyc tracking | grep -E "Leap|System time"
```

Fix:

```bash
sudo timedatectl set-ntp true
sudo systemctl enable --now chronyd
sleep 3
sudo chronyc makestep
sudo hwclock --systohc
```

Healthy when `System time` is `~0.000 seconds off NTP time`. Containers pick up the host clock; no restarts needed.

## 8. Cleanup / Re-deploy

### Full uninstall (`--cleanup`)

Removes all containers, volumes, Docker packages, cloudflared and firewall rules. Also stops the self-hosted runner service and removes `~/actions-runner` — delete the orphan runner manually afterwards: repo Settings > Actions > Runners. SSH daemon is **not** removed.

```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/rocky/setup.sh | bash -s -- --cleanup
```

### Nuclear purge (`--purge`)

Deletes **everything Docker**: all containers, images, volumes and build cache, plus everything `--cleanup` removes. Docker volumes may hold real data — this cannot be undone. Requires typing `YES`. SSH access is always kept.

```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/rocky/setup.sh | bash -s -- --purge
```

### Re-deploy preserving tunnel credentials (`--overwrite`)

Removes containers and config, but preserves cloudflared `cert.pem` and tunnel credentials — no headless re-login needed.

```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/rocky/setup.sh | bash -s -- --overwrite
```

## 9. Note

This is the **rocky** branch. For Ubuntu, use the `ubuntu` branch instead.

## 10. Update in place (`--update`)

Refreshes binaries/images to the pinned versions using saved inputs — no prompts, no re-entering anything. Tunnel cert/creds/config, `authorized_keys` and volumes are never touched; on failure it reports instead of rolling back.

Every successful setup saves non-secret inputs to `~/.infra-setup.env` (chmod 600). `--update` reuses them; on a machine without the file it prompts once, saves, then proceeds.

```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/rocky/setup.sh | bash -s -- --update
```

What it does: `prep_system` → upgrades `cloudflared` if the pin moved → pulls pinned Portainer/Uptime Kuma images and recreates those containers (data stays in volumes) → ensures sshd/firewall per saved `EXPOSE_SSH` → restarts cloudflared with the existing config untouched.
