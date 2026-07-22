#!/bin/bash
set -euo pipefail

NET="infra_network"
JENKINS_HOME="/var/jenkins_home"
CF_CONFIG_DIR="$HOME/.cloudflared"

CLOUDFLARED_VERSION="2025.2.0"
DOCKER_COMPOSE_VERSION="2.32.1"
JENKINS_VERSION="2.492.3-lts-jdk17"
PORTAINER_VERSION="2.27.3"
NPM_VERSION="2.11.1"
UPTIME_KUMA_VERSION="1.23.16"
WATCHTOWER_VERSION="1.7.1"

info() { printf "%b[INFO]%b %s\n" "\e[34m" "\e[0m" "$1"; }
ok()   { printf "%b[OK]%b   %s\n" "\e[32m" "\e[0m" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "\e[33m" "\e[0m" "$1"; }
err()  { printf "%b[ERR]%b  %s\n" "\e[31m" "\e[0m" "$1"; }
ask()  { printf "%b[INPUT]%b %s: " "\e[35m" "\e[0m" "$1" > /dev/tty; }

# ============================================================================
# Distro Contract — Ubuntu (apt-based)
# ============================================================================
pkg_update()    { sudo apt-get update -qq; }
pkg_install()   { sudo apt-get install -y "$@"; }
pkg_remove()    { sudo apt-get remove -y "$@" 2>/dev/null || true; }
svc_name_sshd() { echo "ssh"; }
svc_enable()    { sudo systemctl enable --now "$1"; }
svc_disable()   { sudo systemctl disable --now "$1" 2>/dev/null || true; }
svc_restart()   { sudo systemctl restart "$1"; }

install_cloudflared() {
    local version="$1"
    local arch
    arch=$(dpkg --print-architecture)
    [[ "$arch" == "amd64" || "$arch" == "x86_64" ]] && arch="amd64" || arch="arm64"
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/${version}/cloudflared-linux-${arch}.deb" -o /tmp/cloudflared.deb
    sudo dpkg -i /tmp/cloudflared.deb && rm -f /tmp/cloudflared.deb
}

remove_cloudflared()         { sudo apt-get remove -y cloudflared 2>/dev/null || true; }
firewall_allow_port()        { command -v ufw &>/dev/null && sudo ufw allow "$1" 2>/dev/null || true; }
firewall_deny_port()         { command -v ufw &>/dev/null && sudo ufw deny "$1" 2>/dev/null || true; }
selinux_apply_context()      { :; }

# ============================================================================
# Rollback
# ============================================================================
ROLLBACK_STACK=()

push_rollback() {
    ROLLBACK_STACK+=("$*")
}

ROLLBACK_IN_PROGRESS=0
rollback_all() {
    if [ "$ROLLBACK_IN_PROGRESS" -eq 1 ]; then
        return 0
    fi
    ROLLBACK_IN_PROGRESS=1
    err "Setup failed — rolling back all changes..."
    set -f
    local i
    for (( i=${#ROLLBACK_STACK[@]}-1; i>=0; i-- )); do
        info "  Undoing: ${ROLLBACK_STACK[$i]}"
        ${ROLLBACK_STACK[$i]} 2>/dev/null || warn "  Rollback step failed (safe to ignore): ${ROLLBACK_STACK[$i]}"
    done
    set +f
    err "Rollback complete. System restored to pre-run state."
    exit 1
}

trap 'rollback_all' ERR INT TERM

# ============================================================================
# prompt_config
# ============================================================================
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
        trap - ERR INT TERM
        exit 1
    fi
}

# ============================================================================
# 1. System Prerequisites
# ============================================================================
prep_system() {
    info "Checking Docker..."
    if ! command -v docker &> /dev/null; then
        warn "Docker not found. Installing..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        sudo usermod -aG docker "$USER"
        push_rollback "pkg_remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    else
        ok "Docker already installed."
    fi

    info "Checking Docker socket..."
    local tries=0
    while [ ! -S /var/run/docker.sock ] && [ $tries -lt 10 ]; do
        sleep 1
        tries=$((tries + 1))
    done
    if [ ! -S /var/run/docker.sock ]; then
        err "Docker socket not found at /var/run/docker.sock after install."
        exit 1
    fi
    DOCKER_SOCKET_GID=$(stat -c '%g' /var/run/docker.sock)
    ok "Docker socket group GID: $DOCKER_SOCKET_GID"

    if ! docker network inspect "$NET" >/dev/null 2>&1; then
        docker network create "$NET"
        push_rollback "docker network rm '$NET'"
    else
        ok "Network '$NET' already exists."
    fi
}

# ============================================================================
# 2. launch_container
# ============================================================================
launch_container() {
    local name=$1
    local args=$2

    if [ "$(docker ps -aq -f name=^/${name}$)" ]; then
        warn "Container '$name' already exists. Skipping."
        return
    fi

    docker run -d --name "$name" --restart always --network "$NET" $args
    push_rollback "docker rm -f '$name'"
}

# ============================================================================
# 3. Container Orchestration
# ============================================================================
deploy_stack() {
    info "Deploying Portainer..."
    launch_container "portainer" "-p 8000:8000 -p 9443:9443 --group-add ${DOCKER_SOCKET_GID} -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:${PORTAINER_VERSION}"

    info "Deploying Nginx Proxy Manager..."
    launch_container "nginx-proxy-manager" "-p 80:80 -p 81:81 -p 443:443 -v npm_data:/data -v npm_letsencrypt:/etc/letsencrypt jc21/nginx-proxy-manager:${NPM_VERSION}"

    info "Deploying Jenkins..."
    sudo mkdir -p "$JENKINS_HOME"
    sudo chown -R 1000:1000 "$JENKINS_HOME"
    selinux_apply_context "$JENKINS_HOME"
    push_rollback "sudo rm -rf '$JENKINS_HOME'"
    launch_container "jenkins" "-p 8080:8080 -p 50000:50000 --group-add ${DOCKER_SOCKET_GID} -v ${JENKINS_HOME}:${JENKINS_HOME} -v /var/run/docker.sock:/var/run/docker.sock jenkins/jenkins:${JENKINS_VERSION}"

    info "Deploying Uptime Kuma..."
    launch_container "uptime-kuma" "-p 3001:3001 --group-add ${DOCKER_SOCKET_GID} -v uptime_kuma_data:/app/data -v /var/run/docker.sock:/var/run/docker.sock louislam/uptime-kuma:${UPTIME_KUMA_VERSION}"

    info "Deploying Watchtower..."
    launch_container "watchtower" "--group-add ${DOCKER_SOCKET_GID} -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower:${WATCHTOWER_VERSION} --schedule \"0 0 4 * * *\" --cleanup"

    firewall_allow_port 80/tcp
    firewall_allow_port 443/tcp
    firewall_allow_port 8080/tcp
    firewall_allow_port 9443/tcp
    firewall_allow_port 3001/tcp
    firewall_allow_port 81/tcp
}

# ============================================================================
# 4. Jenkins Pipeline Dependencies
# ============================================================================
configure_pipeline_deps() {
    info "Preparing SSH keys for GitHub..."
    if [ ! -f ~/.ssh/id_ed25519 ]; then
        ssh-keygen -t ed25519 -C "$GITHUB_EMAIL" -N "" -f ~/.ssh/id_ed25519
        push_rollback "rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub"
    else
        ok "SSH key already exists."
    fi

    local vol_path
    vol_path=$(docker inspect jenkins \
        --format '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Source}}{{end}}{{end}}')
    if [ -z "$vol_path" ]; then
        err "Cannot detect Jenkins home path. Is the container running?"
        exit 1
    fi
    info "Jenkins home detected at: $vol_path"

    info "Waiting for Jenkins to initialize..."
    local max_attempts=150
    local attempt=0
    until sudo test -f "$vol_path/config.xml" || sudo test -d "$vol_path/secrets"; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            err "Jenkins failed to initialize within $((max_attempts * 2)) seconds."
            exit 1
        fi
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

    info "Checking Docker CLI inside Jenkins container..."
    if ! docker exec jenkins bash -c "command -v docker" &>/dev/null; then
        info "Installing Docker CLI binary inside Jenkins container..."
        docker exec -u root jenkins bash -c "apt-get update -qq && apt-get install -y -qq curl"
        docker exec -u root jenkins bash -c "
            curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.5.1.tgz \
                | tar -xz --strip-components=1 -C /usr/local/bin docker/docker && \
            chmod +x /usr/local/bin/docker
        "
        push_rollback "docker exec -u root jenkins rm -f /usr/local/bin/docker"
        ok "Docker CLI installed in Jenkins."
    else
        ok "Docker CLI already installed in Jenkins."
    fi

    info "Checking Docker Compose v2 plugin inside Jenkins container..."
    if ! docker exec jenkins bash -c "docker compose version" &>/dev/null; then
        info "Installing Docker Compose v2 plugin inside Jenkins container..."
        docker exec -u root jenkins bash -c "
            mkdir -p /usr/local/lib/docker/cli-plugins && \
            curl -fsSL https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64 \
                -o /usr/local/lib/docker/cli-plugins/docker-compose && \
            chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        "
        push_rollback "docker exec -u root jenkins rm -f /usr/local/lib/docker/cli-plugins/docker-compose"
        ok "Docker Compose v2 plugin installed in Jenkins."
    else
        ok "Docker Compose v2 already available in Jenkins."
    fi

    info "Configuring Jenkins workspace permissions..."
    docker exec -u root jenkins bash -c "
        echo 'umask 002' > /etc/profile.d/jenkins-umask.sh && \
        chmod +x /etc/profile.d/jenkins-umask.sh
    "
    sudo chown -R 1000:1000 "$vol_path/workspace" 2>/dev/null || true
    sudo chmod -R u+rwX "$vol_path/workspace" 2>/dev/null || true
    push_rollback "docker exec -u root jenkins rm -f /etc/profile.d/jenkins-umask.sh"
    ok "Jenkins workspace permissions configured."
}

# ============================================================================
# 5. SSH Server
# ============================================================================
configure_ssh_server() {
    info "Checking SSH daemon (sshd)..."
    if ! command -v sshd &>/dev/null; then
        warn "openssh-server not found. Installing..."
        pkg_update
        pkg_install openssh-server
        push_rollback "pkg_remove openssh-server"
    else
        ok "openssh-server already installed."
    fi

    local sshd_svc
    sshd_svc=$(svc_name_sshd)

    if ! sudo systemctl is-enabled "$sshd_svc" &>/dev/null || ! sudo systemctl is-active --quiet "$sshd_svc"; then
        svc_enable "$sshd_svc"
        push_rollback "svc_disable $sshd_svc"
    fi

    if ss -tlnp | grep -q ':22'; then
        ok "SSH daemon is listening on port 22."
    else
        err "SSH daemon is not listening on port 22 after start attempt."
        exit 1
    fi

    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME/.ssh/authorized_keys"
    ok "~/.ssh/authorized_keys is ready."

    firewall_allow_port 22/tcp
}

# ============================================================================
# 6. Cloudflare Tunnel
# ============================================================================
configure_cloudflare_tunnel() {
    info "Configuring Cloudflare Tunnel..."
    install_cloudflared "$CLOUDFLARED_VERSION"
    push_rollback "remove_cloudflared"

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
        push_rollback "cloudflared tunnel delete '$CF_TUNNEL_NAME'"
    else
        ok "Tunnel '$CF_TUNNEL_NAME' already exists."
    fi

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
        push_rollback "sudo cloudflared service uninstall; sudo rm -f /etc/cloudflared/config.yml"
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    prompt_config
    prep_system
    deploy_stack
    configure_pipeline_deps
    configure_ssh_server
    configure_cloudflare_tunnel

    trap - ERR INT TERM

    ok "Infrastructure is up!"
    echo "======================================================"
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
    echo "!!!  DEFAULT CREDENTIALS — CHANGE IMMEDIATELY  !!!"
    echo "  Nginx Proxy Manager : admin@example.com / changeme"
    echo "  Portainer           : set admin password on first login"
    echo "  Jenkins             : see admin password above"
    echo "======================================================"
}

{ main "$@"; } < /dev/tty
