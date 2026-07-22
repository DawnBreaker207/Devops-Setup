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
# Distro Contract — each distro branch implements these
# ============================================================================
__not_implemented() {
    err "Contract function '$1' is not implemented on this branch."
    err "Switch to a distro branch: git checkout ubuntu | rocky"
    exit 1
}

pkg_update()                 { __not_implemented "${FUNCNAME[0]}"; }
pkg_install()                { __not_implemented "${FUNCNAME[0]}"; }
pkg_remove()                 { __not_implemented "${FUNCNAME[0]}"; }
svc_name_sshd()              { __not_implemented "${FUNCNAME[0]}"; }
svc_enable()                 { __not_implemented "${FUNCNAME[0]}"; }
svc_disable()                { __not_implemented "${FUNCNAME[0]}"; }
svc_restart()                { __not_implemented "${FUNCNAME[0]}"; }
install_cloudflared()        { __not_implemented "${FUNCNAME[0]}"; }
remove_cloudflared()         { __not_implemented "${FUNCNAME[0]}"; }
firewall_allow_port()        { __not_implemented "${FUNCNAME[0]}"; }
firewall_deny_port()         { __not_implemented "${FUNCNAME[0]}"; }
selinux_apply_context()      { __not_implemented "${FUNCNAME[0]}"; }

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
# 3. Cloudflare Tunnel
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
    configure_cloudflare_tunnel

    trap - ERR INT TERM

    ok "Base infrastructure ready."
    echo "======================================================"
    echo "Docker is installed and the infra network is created."
    echo "Cloudflare Tunnel is configured."
    echo "======================================================"
}

{ main "$@"; } < /dev/tty
