#!/bin/bash
set -euo pipefail

NET="infra_network"
CF_CONFIG_DIR="$HOME/.cloudflared"

CLOUDFLARED_VERSION="2026.7.3"
DOCKER_COMPOSE_VERSION="2.32.1"
PORTAINER_VERSION="2.27.3"
UPTIME_KUMA_VERSION="1.23.16"
WATCHTOWER_VERSION="1.7.1"

info() { printf "%b[INFO]%b %s\n" "\e[34m" "\e[0m" "$1"; }
ok()   { printf "%b[OK]%b   %s\n" "\e[32m" "\e[0m" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "\e[33m" "\e[0m" "$1"; }
err()  { printf "%b[ERR]%b  %s\n" "\e[31m" "\e[0m" "$1"; }
ask()  { printf "%b[INPUT]%b %s: " "\e[35m" "\e[0m" "$1" > /dev/tty; }

# ============================================================================
# Distro Contract — Rocky Linux (dnf-based)
# ============================================================================
pkg_update()    { sudo dnf check-update -q || true; }
pkg_install()   { sudo dnf install -y "$@"; }
pkg_remove()    { sudo dnf remove -y "$@" 2>/dev/null || true; }
svc_name_sshd() { echo "sshd"; }
svc_enable()    { sudo systemctl enable --now "$1"; }
svc_disable()   { sudo systemctl disable --now "$1" 2>/dev/null || true; }
svc_restart()   { sudo systemctl restart "$1"; }

install_cloudflared() {
    local version="$1"
    local arch
    arch=$(uname -m)
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/${version}/cloudflared-linux-${arch}.rpm" -o /tmp/cloudflared.rpm
    sudo rpm -i /tmp/cloudflared.rpm && rm -f /tmp/cloudflared.rpm
}

remove_cloudflared()         { sudo dnf remove -y cloudflared 2>/dev/null || true; }

firewall_allow_port() {
    if command -v firewall-cmd &>/dev/null; then
        sudo firewall-cmd --permanent --add-port="$1" && sudo firewall-cmd --reload
    fi
}

firewall_deny_port() {
    if command -v firewall-cmd &>/dev/null; then
        sudo firewall-cmd --permanent --remove-port="$1" && sudo firewall-cmd --reload
    fi
}

selinux_apply_context() {
    if command -v selinuxenabled &>/dev/null && selinuxenabled; then
        sudo chcon -Rt container_file_t "$1" 2>/dev/null || true
    fi
}

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

    ask "Expose SSH port 22 directly? (not recommended if using Cloudflare Tunnel) (y/n)"
    read -r EXPOSE_SSH < /dev/tty
    EXPOSE_SSH="${EXPOSE_SSH:-y}"

    echo "----------------------------------------------"
    echo "  GitHub Email : $GITHUB_EMAIL"
    echo "  Tunnel Name  : $CF_TUNNEL_NAME"
    echo "  Domain       : ${USER_DOMAIN:-"(skipped)"}"
    echo "  SSH User     : $SSH_USER"
    echo "  Expose SSH   : $EXPOSE_SSH"
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
        if ! sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null; then
            sudo dnf install -y dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
        fi
        pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo rm -f /var/run/docker.sock
        sudo systemctl daemon-reload
        sudo systemctl enable --now docker
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

    if ! id -nG | grep -qw docker; then
        sudo chmod 666 /var/run/docker.sock
    fi

    if ! docker network inspect "$NET" >/dev/null 2>&1; then
        docker network create "$NET"
        push_rollback "docker network rm '$NET'"
    else
        ok "Network '$NET' already exists."
    fi

    info "Checking Docker Compose plugin..."
    if ! docker compose version &> /dev/null; then
        warn "docker-compose-plugin not found. Installing..."
        pkg_install "docker-compose-plugin-${DOCKER_COMPOSE_VERSION}"
        push_rollback "pkg_remove docker-compose-plugin"
    else
        ok "Docker Compose plugin already installed."
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

    local -a extra_args=($args)
    docker run -d --name "$name" --restart always --network "$NET" "${extra_args[@]}"
    push_rollback "docker rm -f '$name'"
}

# ============================================================================
# 3. Container Orchestration
# ============================================================================
deploy_stack() {
    selinux_apply_context /var/run/docker.sock

    info "Deploying Portainer..."
    launch_container "portainer" "-p 8000:8000 -p 9443:9443 --group-add ${DOCKER_SOCKET_GID} -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data -l com.centurylinklogs.watchtower=true portainer/portainer-ce:${PORTAINER_VERSION}"

    info "Deploying Uptime Kuma..."
    launch_container "uptime-kuma" "-p 3001:3001 --group-add ${DOCKER_SOCKET_GID} -v uptime_kuma_data:/app/data -v /var/run/docker.sock:/var/run/docker.sock -l com.centurylinklogs.watchtower=true louislam/uptime-kuma:${UPTIME_KUMA_VERSION}"

    info "Deploying Watchtower..."
    launch_container "watchtower" "--group-add ${DOCKER_SOCKET_GID} -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower:${WATCHTOWER_VERSION} --schedule \"0 0 4 * * *\" --cleanup --label-enable"

    firewall_allow_port 9443/tcp
    firewall_allow_port 3001/tcp
}

# ============================================================================
# 4. SSH Server
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

    if [ "$EXPOSE_SSH" = "y" ] || [ "$EXPOSE_SSH" = "Y" ] || [ -z "${USER_DOMAIN:-}" ]; then
        firewall_allow_port 22/tcp
    fi
}

# ============================================================================
# 5. Cloudflare Tunnel
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
  - hostname: portainer.${USER_DOMAIN}
    service: https://localhost:9443
    originRequest:
      noTLSVerify: true
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
# Cleanup / Overwrite
# ============================================================================
cleanup_all() {
    local mode="${1:-full}"
    warn "Cleaning up all infrastructure (mode: $mode)..."

    docker rm -f portainer uptime-kuma watchtower 2>/dev/null || true
    docker network rm "$NET" 2>/dev/null || true
    docker volume rm portainer_data uptime_kuma_data 2>/dev/null || true

    sudo systemctl stop cloudflared 2>/dev/null || true
    sudo cloudflared service uninstall 2>/dev/null || true

    if [ "$mode" = "full" ]; then
        local existing_tunnel
        existing_tunnel=$(grep '^tunnel:' "$CF_CONFIG_DIR/config.yml" 2>/dev/null | awk '{print $2}' || true)
        if [ -n "$existing_tunnel" ]; then
            cloudflared tunnel delete "$existing_tunnel" 2>/dev/null || true
        fi

        rm -rf "$CF_CONFIG_DIR"
        sudo rm -f /etc/cloudflared/config.yml

        sudo systemctl disable --now docker docker.socket 2>/dev/null || true
        sudo rm -f /var/run/docker.sock

        pkg_remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        remove_cloudflared 2>/dev/null || true
        pkg_remove openssh-server 2>/dev/null || true

        firewall_deny_port 9443/tcp
        firewall_deny_port 3001/tcp

        sudo systemctl daemon-reload 2>/dev/null || true
    else
        sudo rm -f /etc/cloudflared/config.yml
        rm -f "$CF_CONFIG_DIR/config.yml"
    fi

    ok "Cleanup complete (mode: $mode)."
}

# ============================================================================
# Main
# ============================================================================
main() {
    if [ "${1:-}" = "--cleanup" ]; then
        cleanup_all full
        trap - ERR INT TERM
        exit 0
    fi

    if [ "${1:-}" = "--overwrite" ]; then
        cleanup_all overwrite
        echo ""
        info "Proceeding with fresh setup..."
    fi

    prompt_config
    prep_system
    deploy_stack
    configure_ssh_server
    configure_cloudflare_tunnel

    trap - ERR INT TERM

    ok "Infrastructure is up!"
    echo "======================================================"
    echo "Cloudflare Tunnel Config : $CF_CONFIG_DIR/config.yml"
    echo "Tunnel Status            : sudo systemctl status cloudflared"
    echo "Portainer                : https://localhost:9443"
    echo "Uptime Kuma              : http://localhost:3001"
    echo "Watchtower               : auto-update daily at 04:00"
    if [ -n "${USER_DOMAIN:-}" ]; then
    echo "SSH Tunnel               : ssh.${USER_DOMAIN}"
    echo "Portainer                : https://portainer.${USER_DOMAIN}"
    echo "Uptime Kuma              : https://uptime.${USER_DOMAIN}"
    fi
    echo "======================================================"
    echo "!!!  DEFAULT CREDENTIALS — CHANGE IMMEDIATELY  !!!"
    echo "  Portainer : set admin password on first login"
    echo "======================================================"
    echo ""
    echo "Next step: add a GitHub Actions deploy key"
    echo "  1. ssh-keygen -t ed25519 -C 'github-actions'"
    echo "  2. cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys"
    echo "  3. Add private key to GitHub repo Secrets as SSH_KEY"
    echo "  4. Create .github/workflows/deploy.yml in your app repo"
    echo "======================================================"
}

{ main "$@"; } < /dev/tty
