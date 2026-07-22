# Infrastructure Setup

This is the **main** (template) branch — it contains the shared core logic.

## Branch Structure

```
main ── Template core (contract stubs, Docker, network, Cloudflare tunnel)
 ├── ubuntu ── Full setup for Ubuntu 24.04 (Jenkins, Portainer, NPM, Kuma)
 └── rocky  ── Full setup for Rocky Linux 9 (Portainer, Kuma, GitHub Actions CI/CD)
```

Each distro branch implements the contract functions (`pkg_*`, `svc_*`, `firewall_*`, `selinux_*`) and adds its own services on top of the shared core.

## Quick Start

Pick your distro and run:

**Ubuntu**
```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/ubuntu/setup.sh | bash
```

**Rocky Linux**
```bash
curl -sSL https://raw.githubusercontent.com/DawnBreaker207/Devops-Setup/rocky/setup.sh | bash
```

## What's on each branch

| Service               | main (template) | ubuntu | rocky |
|-----------------------|:---------------:|:------:|:-----:|
| Docker + Network      | ✅              | ✅     | ✅    |
| Cloudflare Tunnel     | stub            | ✅     | ✅    |
| SSH Server            | stub            | ✅     | ✅    |
| Portainer             | —               | ✅     | ✅    |
| Uptime Kuma           | —               | ✅     | ✅    |
| Watchtower            | —               | ✅     | ✅    |
| Nginx Proxy Manager   | —               | ✅     | —     |
| Jenkins CI/CD         | —               | ✅     | —     |
| GitHub Actions CI/CD  | —               | —      | ✅    |

## Development

Fix shared logic → commit on `main`, then rebase distro branches:

```bash
git checkout main
# edit shared code
git commit -am "fix: ..."
git checkout ubuntu && git rebase main
git checkout rocky && git rebase main
```

To add a new distro:

```bash
git checkout -b <distro> main
# implement all contract functions in setup.sh
# add distro-specific services
# update README
```
