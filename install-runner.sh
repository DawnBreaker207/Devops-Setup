#!/bin/bash
set -euo pipefail

# Self-hosted GitHub Actions runner installer (Rocky/dnf). Run after setup.sh.
# Blank repo URL = print ssh-keygen hint and exit. No rollback; failures print manual cleanup.

readonly RUNNER_VERSION="v2.337.0"
readonly SCRIPT_VERSION="1.0.0"

info() { printf "%b[INFO]%b %s\n" "\e[34m" "\e[0m" "$1"; }
ok()   { printf "%b[OK]%b   %s\n" "\e[32m" "\e[0m" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "\e[33m" "\e[0m" "$1"; }
err()  { printf "%b[ERR]%b  %s\n" "\e[31m" "\e[0m" "$1"; }
ask()  { printf "%b[INPUT]%b %s: " "\e[35m" "\e[0m" "$1" > /dev/tty; }

pkg_install() { sudo dnf install -y "$@"; }

prompt_runner() {
    GITHUB_EMAIL=""
    GITHUB_REPO_URL=""
    RUNNER_TOKEN=""

    ask "GitHub repo URL for the self-hosted runner (e.g. https://github.com/owner/repo) — blank to skip"
    read -r GITHUB_REPO_URL < /dev/tty

    if [[ -z "$GITHUB_REPO_URL" ]]; then
        ask "GitHub Email (used as the ssh-keygen -C comment)"
        read -r GITHUB_EMAIL < /dev/tty
        ok "No repo URL — skipping runner install."
        echo "SSH key hint (for admin access to the server):"
        echo "  1. ssh-keygen -t ed25519 -C \"${GITHUB_EMAIL}\"   # if you don't have one yet"
        echo "  2. cat ~/.ssh/id_ed25519.pub                     # copy the output"
        echo "  3. Paste it into the server's ~/.ssh/authorized_keys"
        exit 0
    fi

    ask "Runner registration token (repo Settings > Actions > Runners > New self-hosted runner)"
    read -r RUNNER_TOKEN < /dev/tty
    if [[ -z "$RUNNER_TOKEN" ]]; then
        err "RUNNER_TOKEN is required when providing a repo URL."
        exit 1
    fi

    echo "----------------------------------------------"
    echo "  Runner Repo  : $GITHUB_REPO_URL"
    echo "----------------------------------------------"
    ask "Confirm? (Y/n)"
    read -r CONFIRM < /dev/tty
    CONFIRM="${CONFIRM:-y}"
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Aborted."
        exit 1
    fi
}

# Systemd unit created by svc.sh install (actions.runner.*.service).
runner_svc_unit() {
    local f
    for f in /etc/systemd/system/actions.runner.*.service; do
        [[ -e "$f" ]] || return 1
        basename "$f" .service
        return 0
    done
    return 1
}

# Build + load gh_runner SELinux module from fresh AVC denials on stdin.
selinux_remediate() {
    if ! command -v audit2allow &>/dev/null; then
        info "Installing SELinux policy tools..."
        pkg_install policycoreutils-python-utils || return 1
    fi
    local fresh
    fresh=$(grep -v "clr-debug-pipe" || true)
    if [[ -z "$fresh" ]]; then
        warn "No fresh SELinux denials — cannot auto-remediate."
        return 1
    fi
    printf '%s\n' "$fresh" | (cd "$HOME" && audit2allow -M gh_runner) || return 1
    sudo semodule -i "$HOME/gh_runner.pp" || return 1
    ok "Loaded SELinux module gh_runner."
}

# Start the runner service; auto-remediate SELinux denials in a bounded loop.
start_runner_service() {
    local svc_unit
    svc_unit=$(runner_svc_unit || true)
    if [[ -z "$svc_unit" ]]; then
        err "Runner service unit not found under /etc/systemd/system."
        return 1
    fi

    sudo ./svc.sh start || true
    local since_epoch
    since_epoch=$(date +%s)

    local round
    for round in 1 2 3 4 5 6; do
        sleep 12
        if sudo systemctl is-active --quiet "$svc_unit"; then
            ok "Runner service is active."
            return 0
        fi
        if ! command -v getenforce &>/dev/null || [[ "$(getenforce 2>/dev/null)" != "Enforcing" ]]; then
            break
        fi
        warn "Service not active (round $round/6) — rebuilding SELinux policy from fresh denials..."
        if sudo grep "type=AVC" /var/log/audit/audit.log 2>/dev/null \
            | awk -F'[():]' -v s="$since_epoch" '$2+0>=s' \
            | selinux_remediate; then
            sudo systemctl restart "$svc_unit" || true
        else
            break
        fi
    done

    err "Runner service '$svc_unit' is not active after remediation attempts."
    err "Manual runbook: sudo ausearch -m avc -ts recent | audit2allow -M gh_runner && sudo semodule -i gh_runner.pp && sudo systemctl restart $svc_unit"
    return 1
}

install_runner() {
    if [[ "$(id -u)" -eq 0 ]]; then
        err "The Actions runner refuses to run as root (config.sh limitation)."
        err "Run install-runner.sh as a non-root admin user."
        return 1
    fi

    if ! command -v git &>/dev/null; then
        info "Installing git (required by the Actions runner)..."
        pkg_install git
    fi

    local runner_arch runner_ver tarball url runner_dir
    case "$(uname -m)" in
        x86_64)  runner_arch="x64" ;;
        aarch64) runner_arch="arm64" ;;
        *) err "Unsupported architecture for the Actions runner: $(uname -m)"; return 1 ;;
    esac

    runner_ver="$RUNNER_VERSION"
    tarball="actions-runner-linux-${runner_arch}-${runner_ver#v}.tar.gz"
    url="https://github.com/actions/runner/releases/download/${runner_ver}/${tarball}"

    runner_dir="$HOME/actions-runner"
    if [[ -d "$runner_dir" ]]; then
        warn "Existing runner dir found — tearing it down cleanly before reinstall..."
        (cd "$runner_dir" && sudo ./svc.sh stop 2>/dev/null) || true
        (cd "$runner_dir" && sudo ./svc.sh uninstall 2>/dev/null) || true
        (cd "$runner_dir" && ./config.sh remove --token "$RUNNER_TOKEN" 2>/dev/null) || true
    fi
    info "Installing Actions runner ${runner_ver} into ${runner_dir}..."
    rm -rf "$runner_dir"
    mkdir -p "$runner_dir"

    if ! curl -fsSL "$url" -o /tmp/actions-runner.tar.gz; then
        err "Failed to download $tarball — release ${runner_ver} may not exist."
        err "Update RUNNER_VERSION in install-runner.sh (github.com/actions/runner/releases), or retry later."
        return 1
    fi
    if ! tar -xzf /tmp/actions-runner.tar.gz -C "$runner_dir"; then
        err "Failed to extract $tarball — the download may be corrupt."
        err "Manual cleanup: rm -rf ${runner_dir}"
        err "Then re-run install-runner.sh."
        return 1
    fi
    rm -f /tmp/actions-runner.tar.gz

    cd "$runner_dir"
    if ! ./config.sh --url "$GITHUB_REPO_URL" --token "$RUNNER_TOKEN" --unattended --replace; then
        err "Runner registration failed. Check GITHUB_REPO_URL and RUNNER_TOKEN."
        err "Manual cleanup: rm -rf ${runner_dir}"
        err "Then re-run install-runner.sh with a fresh token."
        return 1
    fi

    if ! sudo ./svc.sh install "$USER"; then
        err "svc.sh install failed."
        err "Manual cleanup: (cd ${runner_dir} && ./config.sh remove --token \"${RUNNER_TOKEN}\")"
        return 1
    fi

    if ! start_runner_service; then
        return 1
    fi
    ok "Self-hosted runner registered and running as a systemd service."
    echo "install-runner.sh version: $SCRIPT_VERSION"
    echo ""
    echo "Repo CI/CD: create <app-repo>/.github/workflows/deploy.yml with"
    echo "  runs-on: self-hosted"
    echo "  steps: actions/checkout@v4 / docker compose build / docker compose up -d --force-recreate"
}

main() {
    prompt_runner
    install_runner
}

{ main "$@"; } < /dev/tty