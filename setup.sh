#!/bin/bash
set -euo pipefail


NET="infra_network"
# Bind mount at the same path on host and container so Docker daemon can
# resolve docker-compose volume paths correctly (fixes DinD path mismatch).
JENKINS_HOME="/var/jenkins_home"
CF_CONFIG_DIR="$HOME/.cloudflared"

info() { printf "%b[INFO]%b %s\n" "\e[34m" "\e[0m" "$1"; }
ok()   { printf "%b[OK]%b   %s\n" "\e[32m" "\e[0m" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "\e[33m" "\e[0m" "$1"; }
err()  { printf "%b[ERR]%b  %s\n" "\e[31m" "\e[0m" "$1"; }
ask()  { printf "%b[INPUT]%b %s: " "\e[35m" "\e[0m" "$1" > /dev/tty; }

# ---------------------------------------------------------------------------
# Rollback registry — LIFO, executed on any ERR
# ---------------------------------------------------------------------------
ROLLBACK_STACK=()

push_rollback() {
    ROLLBACK_STACK+=("$1")
}

rollback_all() {
    err "Setup failed — rolling back all changes..."
    local i
    for (( i=${#ROLLBACK_STACK[@]}-1; i>=0; i-- )); do
        local cmd="${ROLLBACK_STACK[$i]}"
        info "  Undoing: $cmd"
        eval "$cmd" 2>/dev/null || warn "  Rollback step failed (safe to ignore): $cmd"
    done
    err "Rollback complete. System restored to pre-run state."
    exit 1
}

trap 'rollback_all' ERR

# ---------------------------------------------------------------------------
prompt_config() {
    echo "=============================================="
    echo "         Infrastructure Setup Config"
    echo "=============================================="

    ask "GitHub Email"
    read -r GITHUB_EMAIL < /dev/tty

    ask "Cloudflare Tunnel Name (default: infra-tunnel)"
    read -r CF_TUNNEL_NAME < /dev/tty
    CF_TUNNEL_NAME="${CF_TUNNEL_NAME:-infra-tunnel}"

    ask "Your Domain (e.g. example.com) — leave blank to skip tunnel ingress"
    read -r USER_DOMAIN < /dev/tty

    ask "SSH username on this server (default: $USER)"
    read -r SSH_USER < /dev/tty
    SSH_USER="${SSH_USER:-$USER}"

    echo "----------------------------------------------"
    echo "  GitHub Email : $GITHUB_EMAIL"
    echo "  Tunnel Name  : $CF_TUNNEL_NAME"
    echo "  Domain       : ${USER_DOMAIN:-"(skipped)"}"
    echo "  SSH User     : $SSH_USER"
    echo "----------------------------------------------"
    ask "Confirm? (y/n)"
    read -r CONFIRM < /dev/tty
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Aborted."
        trap - ERR
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 1. System Prerequisites
# ---------------------------------------------------------------------------
prep_system() {
    info "Checking Docker..."
    if ! command -v docker &> /dev/null; then
        warn "Docker not found. Installing..."
        curl -fsSL https://get.docker.com | sh
        sudo usermod -aG docker "$USER"
        push_rollback "sudo apt-get remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true"
    else
        ok "Docker already installed."
    fi

    info "Checking Docker socket permissions..."
    local current_perms
    current_perms=$(stat -c "%a" /var/run/docker.sock 2>/dev/null || echo "000")
    if [ "$current_perms" != "666" ]; then
        local old_perms="$current_perms"
        sudo chmod 666 /var/run/docker.sock
        push_rollback "sudo chmod ${old_perms} /var/run/docker.sock"
        if [ ! -f /etc/udev/rules.d/docker-socket.rules ]; then
            # Persist socket permission across reboots
            echo 'KERNEL=="docker.sock", MODE="0666"' | sudo tee /etc/udev/rules.d/docker-socket.rules > /dev/null
            sudo udevadm control --reload-rules && sudo udevadm trigger
            push_rollback "sudo rm -f /etc/udev/rules.d/docker-socket.rules"
        fi
    else
        ok "Docker socket permissions already correct."
    fi

    if ! docker network inspect "$NET" >/dev/null 2>&1; then
        docker network create "$NET"
        push_rollback "docker network rm '$NET' 2>/dev/null || true"
    else
        ok "Network '$NET' already exists."
    fi

    info "Checking cloudflared..."
    if ! command -v cloudflared &> /dev/null; then
        warn "cloudflared not found. Installing..."
        local ARCH
        ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
        if [[ "$ARCH" == "amd64" || "$ARCH" == "x86_64" ]]; then
            curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
        else
            curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb -o /tmp/cloudflared.deb
        fi
        sudo dpkg -i /tmp/cloudflared.deb
        rm -f /tmp/cloudflared.deb
        push_rollback "sudo apt-get remove -y cloudflared 2>/dev/null || true"
    else
        ok "cloudflared already installed."
    fi
}

# ---------------------------------------------------------------------------
# 2. Container Orchestration
# ---------------------------------------------------------------------------
launch_container() {
    local name=$1
    local args=$2

    if [ "$(docker ps -aq -f name=^/${name}$)" ]; then
        warn "Container '$name' already exists. Skipping."
        return
    fi

    docker run -d --name "$name" --restart always --network "$NET" $args
    push_rollback "docker rm -f '$name' 2>/dev/null || true"
}

deploy_stack() {
    info "Deploying Portainer..."
    launch_container "portainer" "-p 8000:8000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"

    info "Deploying Nginx Proxy Manager..."
    launch_container "nginx-proxy-manager" "-p 80:80 -p 81:81 -p 443:443 -v npm_data:/data -v npm_letsencrypt:/etc/letsencrypt jc21/nginx-proxy-manager:latest"

    info "Deploying Jenkins..."
    # Pre-create the directory on host so the bind mount path exists before the container starts
    sudo mkdir -p "$JENKINS_HOME"
    sudo chown -R 1000:1000 "$JENKINS_HOME"
    push_rollback "sudo rm -rf '$JENKINS_HOME'"
    launch_container "jenkins" "-p 8080:8080 -p 50000:50000 -v ${JENKINS_HOME}:${JENKINS_HOME} -v /var/run/docker.sock:/var/run/docker.sock jenkins/jenkins:lts"

    info "Deploying Uptime Kuma..."
    launch_container "uptime-kuma" "-p 3001:3001 -v uptime_kuma_data:/app/data -v /var/run/docker.sock:/var/run/docker.sock louislam/uptime-kuma:latest"

    info "Deploying Watchtower..."
    launch_container "watchtower" "-v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --schedule \"0 0 4 * * *\" --cleanup"
}

# ---------------------------------------------------------------------------
# 3. Jenkins Pipeline Dependencies
# ---------------------------------------------------------------------------
configure_pipeline_deps() {
    info "Preparing SSH keys for GitHub..."
    if [ ! -f ~/.ssh/id_ed25519 ]; then
        ssh-keygen -t ed25519 -C "$GITHUB_EMAIL" -N "" -f ~/.ssh/id_ed25519
        push_rollback "rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub"
    else
        ok "SSH key already exists."
    fi

    # Auto-detect Jenkins home from the actual mount source — works for both
    # bind mounts and named volumes, so the script is resilient to pre-existing
    # containers that were not created with the expected bind mount path.
    local vol_path
    vol_path=$(docker inspect jenkins \
        --format '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Source}}{{end}}{{end}}')
    if [ -z "$vol_path" ]; then
        err "Cannot detect Jenkins home path. Is the container running?"
        exit 1
    fi
    info "Jenkins home detected at: $vol_path"

    # Wait for Jenkins to be ready.
    # Use config.xml as the readiness signal — it is created on first boot and
    # persists after the setup wizard, unlike secrets/ which may be absent on
    # subsequent runs.
    info "Waiting for Jenkins to initialize..."
    until sudo test -f "$vol_path/config.xml" || sudo test -d "$vol_path/secrets"; do
        printf "."
        sleep 2
    done
    echo ""
    ok "Jenkins is ready."

    if ! sudo test -f "$vol_path/.ssh/id_ed25519"; then
        info "Injecting SSH keys into Jenkins home..."
        sudo mkdir -p "$vol_path/.ssh"
        sudo cp ~/.ssh/id_ed25519* "$vol_path/.ssh/"
        ssh-keyscan -t ed25519 github.com | sudo tee "$vol_path/.ssh/known_hosts" > /dev/null
        sudo chown -R 1000:1000 "$vol_path/.ssh"
        sudo chmod 700 "$vol_path/.ssh" && sudo chmod 600 "$vol_path/.ssh/id_ed25519"
        push_rollback "sudo rm -rf '${vol_path}/.ssh'"
    else
        ok "SSH keys already injected into Jenkins home."
    fi

    # Install Docker CLI using the official static binary instead of docker.io
    # (docker.io from Ubuntu repo is outdated and lacks the Compose v2 plugin)
    info "Checking Docker CLI inside Jenkins container..."
    if ! docker exec jenkins bash -c "command -v docker" &>/dev/null; then
        info "Installing Docker CLI binary inside Jenkins container..."
        docker exec -u root jenkins bash -c "apt-get update -qq && apt-get install -y -qq curl"
        docker exec -u root jenkins bash -c "
            curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.5.1.tgz \
                | tar -xz --strip-components=1 -C /usr/local/bin docker/docker && \
            chmod +x /usr/local/bin/docker
        "
        push_rollback "docker exec -u root jenkins rm -f /usr/local/bin/docker 2>/dev/null || true"
        ok "Docker CLI installed in Jenkins."
    else
        ok "Docker CLI already installed in Jenkins."
    fi

    info "Checking Docker Compose v2 plugin inside Jenkins container..."
    if ! docker exec jenkins bash -c "docker compose version" &>/dev/null; then
        info "Installing Docker Compose v2 plugin inside Jenkins container..."
        docker exec -u root jenkins bash -c "
            mkdir -p /usr/local/lib/docker/cli-plugins && \
            curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
                -o /usr/local/lib/docker/cli-plugins/docker-compose && \
            chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        "
        push_rollback "docker exec -u root jenkins rm -f /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null || true"
        ok "Docker Compose v2 plugin installed in Jenkins."
    else
        ok "Docker Compose v2 already available in Jenkins."
    fi

    info "Configuring Jenkins workspace permissions..."
    # umask 002: new files default to 664, preventing read-only files (e.g. .env)
    # from blocking future pipeline runs that need to overwrite them
    docker exec -u root jenkins bash -c "
        echo 'umask 002' > /etc/profile.d/jenkins-umask.sh && \
        chmod +x /etc/profile.d/jenkins-umask.sh
    "
    sudo chown -R 1000:1000 "$vol_path/workspace" 2>/dev/null || true
    sudo chmod -R u+rwX "$vol_path/workspace" 2>/dev/null || true
    push_rollback "docker exec -u root jenkins rm -f /etc/profile.d/jenkins-umask.sh 2>/dev/null || true"
    ok "Jenkins workspace permissions configured."
}

# ---------------------------------------------------------------------------
# 4. SSH Server
# ---------------------------------------------------------------------------
configure_ssh_server() {
    info "Checking SSH daemon (sshd)..."

    # Cài openssh-server nếu chưa có
    if ! command -v sshd &>/dev/null; then
        warn "openssh-server not found. Installing..."
        sudo apt-get install -y openssh-server
        push_rollback "sudo apt-get remove -y openssh-server 2>/dev/null || true"
    else
        ok "openssh-server already installed."
    fi

    # Bật và start service
    if ! sudo systemctl is-enabled ssh &>/dev/null; then
        sudo systemctl enable ssh
        push_rollback "sudo systemctl disable ssh 2>/dev/null || true"
    fi

    if ! sudo systemctl is-active --quiet ssh; then
        sudo systemctl start ssh
        push_rollback "sudo systemctl stop ssh 2>/dev/null || true"
    fi

    # Xác nhận đang listen :22
    if ss -tlnp | grep -q ':22'; then
        ok "SSH daemon is listening on port 22."
    else
        err "SSH daemon is not listening on port 22 after start attempt."
        exit 1
    fi

    # Tạo ~/.ssh/authorized_keys nếu chưa có (để client có thể inject key)
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME/.ssh/authorized_keys"
    ok "~/.ssh/authorized_keys is ready."
}

# ---------------------------------------------------------------------------
# 5. Cloudflare Tunnel
# ---------------------------------------------------------------------------
configure_cloudflare_tunnel() {
    info "Configuring Cloudflare Tunnel..."
    mkdir -p "$CF_CONFIG_DIR"

    if [ ! -f "$CF_CONFIG_DIR/cert.pem" ]; then
        info "Logging in to Cloudflare (browser will open)..."
        cloudflared tunnel login
        push_rollback "rm -f '$CF_CONFIG_DIR/cert.pem'"
    else
        ok "Cloudflare cert already exists. Skipping login."
    fi

    if ! cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$CF_TUNNEL_NAME"; then
        info "Creating tunnel: $CF_TUNNEL_NAME"
        cloudflared tunnel create "$CF_TUNNEL_NAME"
        push_rollback "cloudflared tunnel delete '$CF_TUNNEL_NAME' 2>/dev/null || true"
    else
        ok "Tunnel '$CF_TUNNEL_NAME' already exists."
    fi

    # Exact name match to avoid resolving a partial/wrong tunnel ID
    local TUNNEL_ID
    TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | awk -v name="$CF_TUNNEL_NAME" '$2==name {print $1}')
    if [ -z "$TUNNEL_ID" ]; then
        err "Cannot resolve tunnel ID for '$CF_TUNNEL_NAME'. Aborting."
        exit 1
    fi

    local CREDS_FILE="$CF_CONFIG_DIR/${TUNNEL_ID}.json"
    if [ ! -f "$CREDS_FILE" ]; then
        err "Credentials file not found: $CREDS_FILE"
        err "Tunnel may have been created under a different account or deleted."
        exit 1
    fi

    local CONFIG_FILE="$CF_CONFIG_DIR/config.yml"
    local EXISTING_ID=""
    if [ -f "$CONFIG_FILE" ]; then
        EXISTING_ID=$(grep '^tunnel:' "$CONFIG_FILE" 2>/dev/null | awk '{print $2}' || true)
    fi

    if [ ! -f "$CONFIG_FILE" ] || [ "$EXISTING_ID" != "$TUNNEL_ID" ]; then
        if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "$TUNNEL_ID" ]; then
            warn "Config has stale tunnel ID '$EXISTING_ID', overwriting with '$TUNNEL_ID'..."
        fi
        info "Writing tunnel config to $CONFIG_FILE"

        if [ -n "${USER_DOMAIN:-}" ]; then
            cat > "$CONFIG_FILE" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDS_FILE}

ingress:
  - hostname: jenkins.${USER_DOMAIN}
    service: http://localhost:8080
  - hostname: portainer.${USER_DOMAIN}
    service: https://localhost:9443
    originRequest:
      noTLSVerify: true
  - hostname: npm.${USER_DOMAIN}
    service: http://localhost:81
  - hostname: uptime.${USER_DOMAIN}
    service: http://localhost:3001
  - hostname: ssh.${USER_DOMAIN}
    service: ssh://localhost:22
  - service: http_status:404
EOF
            ok "Tunnel config written with domain: $USER_DOMAIN (includes SSH ingress)"
        else
            cat > "$CONFIG_FILE" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDS_FILE}

ingress:
  - service: http_status:404
EOF
            warn "No domain provided. Ingress left empty — edit $CONFIG_FILE manually when ready."
        fi
        push_rollback "rm -f '$CONFIG_FILE'"
    else
        ok "Tunnel config already exists and tunnel ID matches. Skipping."

        # Bổ sung SSH ingress vào config hiện có nếu chưa có
        if [ -n "${USER_DOMAIN:-}" ] && ! grep -q "ssh://localhost:22" "$CONFIG_FILE"; then
            warn "Existing config missing SSH ingress — patching..."
            local ESCAPED_DOMAIN
            ESCAPED_DOMAIN=$(printf '%s' "$USER_DOMAIN" | sed 's/\./\\./g')
            sed -i "s|  - service: http_status:404|  - hostname: ssh.${ESCAPED_DOMAIN}\n    service: ssh://localhost:22\n  - service: http_status:404|" "$CONFIG_FILE"
            ok "SSH ingress rule patched into existing config."
        else
            ok "SSH ingress rule already present in config."
        fi
    fi

    # Đăng ký DNS record cho SSH subdomain
    if [ -n "${USER_DOMAIN:-}" ]; then
        info "Registering DNS CNAME for ssh.${USER_DOMAIN}..."
        if cloudflared tunnel route dns "$CF_TUNNEL_NAME" "ssh.${USER_DOMAIN}" 2>/dev/null; then
            ok "DNS record created: ssh.${USER_DOMAIN}"
        else
            warn "DNS record may already exist or failed — verify manually with: cloudflared tunnel route dns $CF_TUNNEL_NAME ssh.${USER_DOMAIN}"
        fi
    fi

    sudo mkdir -p /etc/cloudflared
    sudo cp "$CF_CONFIG_DIR/config.yml" /etc/cloudflared/config.yml

    if sudo test -f /etc/systemd/system/cloudflared.service; then
        ok "cloudflared service already installed — reloading config..."
        sudo systemctl restart cloudflared
    else
        info "Installing cloudflared as a system service..."
        sudo cloudflared service install
        sudo systemctl enable cloudflared
        sudo systemctl start cloudflared
        push_rollback "sudo cloudflared service uninstall 2>/dev/null || true; sudo rm -f /etc/cloudflared/config.yml"
    fi
}

# ---------------------------------------------------------------------------
# Main Entrypoint
# ---------------------------------------------------------------------------
main() {
    prompt_config
    prep_system
    deploy_stack
    configure_pipeline_deps
    configure_ssh_server
    configure_cloudflare_tunnel

    trap - ERR

    ok "Infrastructure is up!"
    echo "======================================================"
    # initialAdminPassword only exists before the setup wizard is completed.
    # On subsequent runs it will be absent — handle both cases gracefully.
    local jenkins_vol
    jenkins_vol=$(docker inspect jenkins \
        --format '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || echo "")
    if [ -n "$jenkins_vol" ] && sudo test -f "${jenkins_vol}/secrets/initialAdminPassword"; then
        echo "Jenkins Admin Password:"
        sudo cat "${jenkins_vol}/secrets/initialAdminPassword"
    else
        echo "Jenkins Admin Password: (already configured — check Jenkins UI)"
    fi
    echo "======================================================"
    echo "Public SSH Key (Add to GitHub):"
    cat ~/.ssh/id_ed25519.pub
    echo "======================================================"
    echo "Cloudflare Tunnel Config : $CF_CONFIG_DIR/config.yml"
    echo "Tunnel Status            : sudo systemctl status cloudflared"
    echo "Uptime Kuma              : http://localhost:3001"
    echo "Watchtower               : auto-update daily at 04:00"
    if [ -n "${USER_DOMAIN:-}" ]; then
    echo "SSH Tunnel               : ssh.${USER_DOMAIN}"
    fi
    echo "======================================================"
}

{ main "$@"; } < /dev/tty