#!/bin/bash

set -euo pipefail # Fail fast, trace errors

# --- Config ---
GITHUB_EMAIL="tunganhngo207@gmail.com"
NET="infra_network"
JENKINS_HOME="jenkins_data"

# Styling
info() { printf "%b[INFO]%b %s\n" "\e[34m" "\e[0m" "$1"; }
ok()   { printf "%b[OK]%b   %s\n" "\e[32m" "\e[0m" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "\e[33m" "\e[0m" "$1"; }

# 1. System Prereqs
prep_system() {
    info "Checking Docker installation..."
    if ! command -v docker &> /dev/null; then
        warn "Docker not found. Installing..."
        curl -fsSL https://get.docker.com | sh
        sudo usermod -aG docker "$USER"
    fi

    info "Setting up Docker socket permissions & udev rules..."
    sudo chmod 666 /var/run/docker.sock
    echo 'KERNEL=="docker.sock", MODE="0666"' | sudo tee /etc/udev/rules.d/docker-socket.rules > /dev/null
    sudo udevadm control --reload-rules && sudo udevadm trigger

    if ! docker network inspect "$NET" >/dev/null 2>&1; then
        docker network create "$NET"
    fi
}


# 2. Container Orchestration
# Logic: Remove existing container if it exists to avoid name conflicts
launch_container() {
    local name=$1
    local args=$2
    if [ "$(docker ps -aq -f name=^/${name}$)" ]; then
        warn "Container '$name' exists. Recreating..."
        docker rm -f "$name" > /dev/null
    fi
    docker run -d --name "$name" --restart always --network "$NET" $args
}


deploy_stack() {
    info "Deploying Portainer..."
    launch_container "portainer" "-p 8000:8000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"

    info "Deploying Nginx Proxy Manager..."
    launch_container "nginx-proxy-manager" "-p 80:80 -p 81:81 -p 443:443 -v npm_data:/data -v npm_letsencrypt:/etc/letsencrypt jc21/nginx-proxy-manager:latest"

    info "Deploying Jenkins..."
    launch_container "jenkins" "-p 8080:8080 -p 50000:50000 -v ${JENKINS_HOME}:/var/jenkins_home -v /var/run/docker.sock:/var/run/docker.sock jenkins/jenkins:lts"
}


# 3. Jenkins & Git Config
configure_pipeline_deps() {
    info "Preparing SSH keys for GitHub..."
    [ ! -f ~/.ssh/id_ed25519 ] && ssh-keygen -t ed25519 -C "$GITHUB_EMAIL" -N "" -f ~/.ssh/id_ed25519

    # Wait for Jenkins to unlock the volume and create the directory
    info "Waiting for Jenkins to initialize volume..."
    local vol_path
    vol_path=$(docker volume inspect "$JENKINS_HOME" -f '{{.Mountpoint}}')
    
    until sudo test -d "$vol_path/secrets"; do
        printf "."
        sleep 2
    done
    echo ""

    info "Injecting SSH keys into Jenkins volume..."
    sudo mkdir -p "$vol_path/.ssh"
    sudo cp ~/.ssh/id_ed25519* "$vol_path/.ssh/"
    ssh-keyscan -t ed25519 github.com | sudo tee "$vol_path/.ssh/known_hosts" > /dev/null
    sudo chown -R 1000:1000 "$vol_path/.ssh"
    sudo chmod 700 "$vol_path/.ssh" && sudo chmod 600 "$vol_path/.ssh/id_ed25519"

    info "Installing Docker CLI inside Jenkins container..."
    docker exec -u root jenkins bash -c "apt-get update -qq && apt-get install -y -qq docker-ce-cli docker-compose-v2"
}


# --- Execution ---
main() {
    prep_system
    deploy_stack
    configure_pipeline_deps

    ok "Infrastructure is up!"
    echo "------------------------------------------------------"
    echo "Jenkins Admin Password:"
    sudo cat "$(docker volume inspect "$JENKINS_HOME" -f '{{.Mountpoint}}')/secrets/initialAdminPassword"
    echo "------------------------------------------------------"
    echo "Public SSH Key (Add to GitHub):"
    cat ~/.ssh/id_ed25519.pub
    echo "------------------------------------------------------"
}

main "$@"