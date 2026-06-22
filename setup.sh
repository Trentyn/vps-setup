#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/setup-common.sh
source "$SCRIPT_DIR/lib/setup-common.sh"

trap 'error "Setup failed at line $LINENO. Check the output above."' ERR

require_root "$@"

CURRENT_USER=$(detect_target_user)
CURRENT_HOME=$(target_home "$CURRENT_USER")
REPO_SLUG=""

info "Interactive VPS setup started"
info "Target user: $CURRENT_USER"

install_base_dependencies() {
    local packages=()

    package_installed curl || packages+=(curl)
    package_installed git || packages+=(git)
    package_installed openssh-client || packages+=(openssh-client)
    package_installed openssh-server || packages+=(openssh-server)

    if [[ ${#packages[@]} -eq 0 ]]; then
        info "Base dependencies already installed"
        return
    fi

    if confirm "Install missing base dependencies: ${packages[*]}?"; then
        apt-get update
        apt-get install -y "${packages[@]}"
    else
        warn "Skipped base dependencies installation"
    fi
}

install_docker() {
    if command_exists docker; then
        info "Docker already installed"
        return
    fi

    if ! confirm "Install Docker?"; then
        warn "Skipped Docker installation"
        return
    fi

    require_command curl "curl is required to install Docker. Install dependencies first."
    curl -fsSL https://get.docker.com | sh
    info "Docker installed"
}

configure_docker_group() {
    if [[ "$CURRENT_USER" == "root" ]]; then
        info "Docker group step skipped for root user"
        return
    fi

    if ! command_exists docker; then
        warn "Docker is not installed; docker group configuration skipped"
        return
    fi

    if id -nG "$CURRENT_USER" | tr ' ' '\n' | grep -Fxq docker; then
        info "User $CURRENT_USER is already in docker group"
        return
    fi

    if confirm "Add user $CURRENT_USER to docker group?"; then
        usermod -aG docker "$CURRENT_USER"
        info "Added $CURRENT_USER to docker group"
        warn "User needs to re-login for docker group changes to apply"
    else
        warn "Skipped docker group configuration"
    fi
}

ensure_actions_key() {
    local key_path="$CURRENT_HOME/.ssh/id_ed25519"
    local pub_path="${key_path}.pub"

    ensure_ssh_dir "$CURRENT_HOME" "$CURRENT_USER"

    if [[ -f "$key_path" && -f "$pub_path" ]]; then
        info "GitHub Actions SSH key already exists: $key_path"
    elif confirm "Generate SSH key for GitHub Actions secret (private key)?"; then
        require_command ssh-keygen "ssh-keygen is required. Install dependencies first."
        run_as_target_user ssh-keygen -t ed25519 -C "github-action-deploy" -f "$key_path" -N ""
        info "Generated $key_path"
    else
        warn "Skipped GitHub Actions SSH key generation"
        return
    fi

    ensure_line_in_file "$(cat "$pub_path")" "$CURRENT_HOME/.ssh/authorized_keys"
    chown "$CURRENT_USER:$CURRENT_USER" "$CURRENT_HOME/.ssh/authorized_keys"
    chmod 600 "$CURRENT_HOME/.ssh/authorized_keys"
    info "authorized_keys updated"

    echo
    warn "Add this PRIVATE key to GitHub Actions secret SSH_KEY:"
    echo
    cat "$key_path"
    echo
    pause "Press Enter after saving the private key"
}

ensure_deploy_key() {
    local key_path="$CURRENT_HOME/.ssh/id_deploy"
    local pub_path="${key_path}.pub"

    ensure_ssh_dir "$CURRENT_HOME" "$CURRENT_USER"

    if [[ -f "$key_path" && -f "$pub_path" ]]; then
        info "Deploy key already exists: $key_path"
    elif confirm "Generate deploy key for git pull/clone?"; then
        require_command ssh-keygen "ssh-keygen is required. Install dependencies first."
        run_as_target_user ssh-keygen -t ed25519 -C "deploy-key-only" -f "$key_path" -N ""
        info "Generated $key_path"
    else
        warn "Skipped deploy key generation"
        return
    fi

    echo
    warn "Add this PUBLIC deploy key to the target GitHub repository -> Settings -> Deploy keys:"
    echo
    cat "$pub_path"
    echo
    pause "Press Enter after adding the deploy key"
}

configure_github_ssh() {
    local ssh_config="$CURRENT_HOME/.ssh/config"
    local managed_block

    if [[ ! -f "$CURRENT_HOME/.ssh/id_deploy" ]]; then
        warn "Deploy key not found; GitHub SSH config skipped"
        return
    fi

    ensure_ssh_dir "$CURRENT_HOME" "$CURRENT_USER"

    managed_block=$'# codex-vps-setup github deploy key\nHost github.com\n    HostName github.com\n    User git\n    IdentitiesOnly yes\n    IdentityFile ~/.ssh/id_deploy'

    if file_contains "$ssh_config" "IdentityFile ~/.ssh/id_deploy"; then
        info "GitHub SSH config already contains deploy key"
        return
    fi

    if confirm "Configure ~/.ssh/config for github.com deploy key?"; then
        {
            [[ -f "$ssh_config" ]] && cat "$ssh_config"
            printf '\n%s\n' "$managed_block"
        } > "${ssh_config}.tmp"
        mv "${ssh_config}.tmp" "$ssh_config"
        chown "$CURRENT_USER:$CURRENT_USER" "$ssh_config"
        chmod 600 "$ssh_config"
        info "Updated $ssh_config"
    else
        warn "Skipped GitHub SSH config"
    fi
}

test_github_connection() {
    local ssh_output

    if [[ ! -f "$CURRENT_HOME/.ssh/id_deploy" ]]; then
        warn "Deploy key not found; GitHub connection test skipped"
        return
    fi

    if ! confirm "Test GitHub SSH connection now?"; then
        warn "Skipped GitHub connection test"
        return
    fi

    require_command ssh "ssh client is required. Install dependencies first."

    while true; do
        ssh_output=$(run_as_target_user ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)

        if grep -Eq 'successfully authenticated|Hi .*! You'\''ve successfully authenticated' <<< "$ssh_output"; then
            if REPO_SLUG=$(extract_repo_slug_from_github_ssh_output "$ssh_output"); then
                info "GitHub SSH connection verified for $REPO_SLUG"
            else
                info "GitHub SSH connection verified"
            fi
            break
        fi

        warn "GitHub SSH connection not verified yet"
        note "$ssh_output"
        if ! confirm "Retry GitHub SSH connection test?"; then
            break
        fi
    done
}

clone_repository() {
    local repo_name target_dir repo_url

    if ! confirm "Clone a repository?"; then
        return
    fi

    require_command git "git is required. Install dependencies first."

    if [[ -z "$REPO_SLUG" ]]; then
        warn "Repository name is unknown. Run GitHub SSH test first or add the deploy key correctly."
        return
    fi

    repo_url="git@github.com:${REPO_SLUG}.git"
    repo_name=$(basename "$REPO_SLUG")
    target_dir="$CURRENT_HOME/$repo_name"

    if [[ -e "$target_dir" ]]; then
        warn "Target path already exists: $target_dir"
        return
    fi

    if confirm "Clone $REPO_SLUG into $target_dir?"; then
        run_as_target_user git clone "$repo_url" "$target_dir"
        info "Repository cloned to $target_dir"
    else
        warn "Clone skipped"
    fi
}

configure_git_identity() {
    local current_email current_name git_email git_name

    require_command git "git is required. Install dependencies first."

    current_email=$(run_as_target_user git config --global --get user.email || true)
    current_name=$(run_as_target_user git config --global --get user.name || true)

    if [[ -n "$current_name" || -n "$current_email" ]]; then
        info "Current git identity: ${current_name:-<empty>} <${current_email:-empty}>"
        if ! confirm "Update git identity?"; then
            return
        fi
    elif ! confirm "Configure git identity for $CURRENT_USER?"; then
        return
    fi

    read -r -p "Git name: " git_name
    read -r -p "Git email: " git_email

    if [[ -z "$git_name" || -z "$git_email" ]]; then
        warn "Git name or email is empty; git identity not changed"
        return
    fi

    run_as_target_user git config --global user.name "$git_name"
    run_as_target_user git config --global user.email "$git_email"
    info "Git identity configured"
}

offer_bashrc_setup() {
    if confirm "Apply project bashrc template for $CURRENT_USER?"; then
        "$SCRIPT_DIR/bashrc.sh" "$CURRENT_USER"
    else
        warn "Skipped bashrc setup"
    fi
}

install_base_dependencies
install_docker
configure_docker_group
ensure_actions_key
ensure_deploy_key
configure_github_ssh
test_github_connection
clone_repository
configure_git_identity
offer_bashrc_setup

echo
info "Setup complete"
