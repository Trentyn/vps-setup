#!/bin/bash

step_install_base_dependencies() {
    local packages=()

    package_installed ca-certificates || packages+=(ca-certificates)
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
        apt-get install -y --no-install-recommends "${packages[@]}"
    else
        warn "Skipped base dependencies installation"
    fi
}

step_install_docker() {
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

step_configure_docker_group() {
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

step_ensure_actions_key() {
    local key_path="$CURRENT_HOME/.ssh/id_github_actions"
    local pub_path="${key_path}.pub"
    local created_key=0

    ensure_ssh_dir "$CURRENT_HOME" "$CURRENT_USER"

    if [[ -f "$key_path" && -f "$pub_path" ]]; then
        info "GitHub Actions SSH key already exists: $key_path"
    elif confirm "Generate dedicated SSH key for GitHub Actions secret?"; then
        require_command ssh-keygen "ssh-keygen is required. Install dependencies first."
        run_as_target_user ssh-keygen -t ed25519 -C "github-actions-deploy" -f "$key_path" -N ""
        info "Generated $key_path"
        created_key=1
    else
        warn "Skipped GitHub Actions SSH key generation"
        return
    fi

    ensure_public_key_in_authorized_keys "$pub_path" "$CURRENT_HOME" "$CURRENT_USER"

    if [[ $created_key -eq 1 ]]; then
        echo
        warn "Add this PRIVATE key to GitHub Actions secret SSH_KEY:"
        echo
        cat "$key_path"
        echo
        pause "Press Enter after saving the private key"
    elif confirm "Show the GitHub Actions private key now?"; then
        echo
        warn "Add this PRIVATE key to GitHub Actions secret SSH_KEY:"
        echo
        cat "$key_path"
        echo
        pause "Press Enter after saving the private key"
    fi
}

step_ensure_deploy_key() {
    local key_path="$CURRENT_HOME/.ssh/id_repo_deploy"
    local pub_path="${key_path}.pub"
    local created_key=0

    ensure_ssh_dir "$CURRENT_HOME" "$CURRENT_USER"

    if [[ -f "$key_path" && -f "$pub_path" ]]; then
        info "Repository deploy key already exists: $key_path"
    elif confirm "Generate dedicated deploy key for repository clone/pull?"; then
        require_command ssh-keygen "ssh-keygen is required. Install dependencies first."
        run_as_target_user ssh-keygen -t ed25519 -C "repo-deploy-key" -f "$key_path" -N ""
        info "Generated $key_path"
        created_key=1
    else
        warn "Skipped deploy key generation"
        return
    fi

    if [[ $created_key -eq 1 ]]; then
        echo
        warn "Add this PUBLIC deploy key to the target repository -> Settings -> Deploy keys:"
        echo
        cat "$pub_path"
        echo
        pause "Press Enter after adding the deploy key"
    elif confirm "Show the repository deploy public key now?"; then
        echo
        warn "Add this PUBLIC deploy key to the target repository -> Settings -> Deploy keys:"
        echo
        cat "$pub_path"
        echo
        pause "Press Enter after adding the deploy key"
    fi
}

step_configure_github_ssh() {
    local ssh_config="$CURRENT_HOME/.ssh/config"
    local managed_block

    if [[ ! -f "$CURRENT_HOME/.ssh/id_repo_deploy" ]]; then
        warn "Deploy key not found; SSH alias configuration skipped"
        return
    fi

    ensure_ssh_dir "$CURRENT_HOME" "$CURRENT_USER"

    managed_block=$"# codex-vps-setup deploy key\nHost ${GITHUB_DEPLOY_HOST}\n    HostName github.com\n    User git\n    IdentitiesOnly yes\n    IdentityFile ~/.ssh/id_repo_deploy"

    if file_contains "$ssh_config" "Host ${GITHUB_DEPLOY_HOST}"; then
        info "SSH alias ${GITHUB_DEPLOY_HOST} already exists"
        return
    fi

    if confirm "Configure SSH alias ${GITHUB_DEPLOY_HOST} for deploy key?"; then
        append_block_to_file "$managed_block" "$ssh_config"
        chown "$CURRENT_USER:$CURRENT_USER" "$ssh_config"
        chmod 600 "$ssh_config"
        info "Updated $ssh_config"
    else
        warn "Skipped SSH alias configuration"
    fi
}

step_test_github_connection() {
    local ssh_output

    if [[ ! -f "$CURRENT_HOME/.ssh/id_repo_deploy" ]]; then
        warn "Deploy key not found; GitHub connection test skipped"
        return
    fi

    if ! file_contains "$CURRENT_HOME/.ssh/config" "Host ${GITHUB_DEPLOY_HOST}"; then
        warn "SSH alias ${GITHUB_DEPLOY_HOST} is not configured; run github_ssh step first"
        return
    fi

    if ! confirm "Test GitHub deploy key now?"; then
        warn "Skipped GitHub connection test"
        return
    fi

    require_command ssh "ssh client is required. Install dependencies first."

    while true; do
        ssh_output=$(run_as_target_user ssh -T -o StrictHostKeyChecking=accept-new "git@${GITHUB_DEPLOY_HOST}" 2>&1 || true)

        if grep -Eq 'successfully authenticated|Hi .*! You'\''ve successfully authenticated' <<< "$ssh_output"; then
            if REPO_SLUG=$(extract_repo_slug_from_github_ssh_output "$ssh_output"); then
                info "GitHub deploy key verified for $REPO_SLUG"
            else
                warn "GitHub authenticated, but repository name was not detected"
            fi
            break
        fi

        warn "GitHub deploy key not verified yet"
        note "$ssh_output"
        if ! confirm "Retry GitHub deploy key test?"; then
            break
        fi
    done
}

step_clone_repository() {
    local repo_name target_dir repo_url

    require_command git "git is required. Install dependencies first."

    if [[ -z "$REPO_SLUG" ]]; then
        warn "Repository name is unknown. Run github_test after adding the deploy key."
        return
    fi

    repo_url="git@${GITHUB_DEPLOY_HOST}:${REPO_SLUG}.git"
    repo_name=$(basename "$REPO_SLUG")
    target_dir="$CURRENT_HOME/$repo_name"

    if [[ -e "$target_dir" ]]; then
        info "Repository already exists at $target_dir"
        return
    fi

    if confirm "Clone $REPO_SLUG into $target_dir?"; then
        run_as_target_user git clone "$repo_url" "$target_dir"
        info "Repository cloned to $target_dir"
    else
        warn "Clone skipped"
    fi
}

step_configure_git_identity() {
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

step_offer_bashrc_setup() {
    if confirm "Apply project bashrc template for $CURRENT_USER?"; then
        "$SCRIPT_DIR/bashrc.sh" "$CURRENT_USER"
    else
        warn "Skipped bashrc setup"
    fi
}
