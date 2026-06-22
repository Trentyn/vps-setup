#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/setup-common.sh
source "$SCRIPT_DIR/lib/setup-common.sh"
# shellcheck source=lib/setup-steps.sh
source "$SCRIPT_DIR/lib/setup-steps.sh"

trap 'error "Setup failed at line $LINENO. Check the output above."' ERR

STEP_ORDER=(
    packages
    docker
    docker_group
    actions_key
    deploy_key
    github_ssh
    github_test
    clone
    git_config
    bashrc
)

usage() {
    cat <<'EOF'
Usage:
  sudo bash setup.sh
  sudo bash setup.sh --all
  sudo bash setup.sh --step packages --step docker --step deploy_key

Available steps:
  packages      Install missing base packages
  docker        Install Docker if needed
  docker_group  Add target user to docker group
  actions_key   Generate GitHub Actions SSH key
  deploy_key    Generate repository deploy key
  github_ssh    Configure SSH alias for deploy key
  github_test   Test deploy key and detect repository slug
  clone         Clone detected repository
  git_config    Configure global git name/email
  bashrc        Apply project bashrc template
EOF
}

for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

require_root "$@"

CURRENT_USER=$(detect_target_user)
CURRENT_HOME=$(target_home "$CURRENT_USER")
REPO_SLUG=""
GITHUB_DEPLOY_HOST="github.com-deploy"

step_exists() {
    local wanted="$1"
    local step

    for step in "${STEP_ORDER[@]}"; do
        if [[ "$step" == "$wanted" ]]; then
            return 0
        fi
    done

    return 1
}

run_step_by_name() {
    case "$1" in
        packages) step_install_base_dependencies ;;
        docker) step_install_docker ;;
        docker_group) step_configure_docker_group ;;
        actions_key) step_ensure_actions_key ;;
        deploy_key) step_ensure_deploy_key ;;
        github_ssh) step_configure_github_ssh ;;
        github_test) step_test_github_connection ;;
        clone) step_clone_repository ;;
        git_config) step_configure_git_identity ;;
        bashrc) step_offer_bashrc_setup ;;
        *)
            error "Unknown step: $1"
            return 1
            ;;
    esac
}

run_all_steps() {
    local step

    for step in "${STEP_ORDER[@]}"; do
        run_step_by_name "$step"
    done
}

prompt_custom_steps() {
    local answer
    local selected=()
    local step

    while true; do
        echo
        note "Available steps:"
        for step in "${STEP_ORDER[@]}"; do
            printf '  - %s\n' "$step"
        done
        echo

        read -r -p "Enter comma-separated step names: " answer
        answer=${answer// /}

        if [[ -z "$answer" ]]; then
            warn "No steps selected"
            continue
        fi

        IFS=',' read -r -a selected <<< "$answer"
        for step in "${selected[@]}"; do
            if ! step_exists "$step"; then
                error "Unknown step in selection: $step"
                selected=()
                break
            fi
        done

        if [[ ${#selected[@]} -eq 0 ]]; then
            continue
        fi

        for step in "${selected[@]}"; do
            run_step_by_name "$step"
        done
        return 0
    done
}

main() {
    local run_mode=""
    local requested_steps=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                run_mode="all"
                shift
                ;;
            --step)
                [[ $# -lt 2 ]] && die "Missing value after --step"
                requested_steps+=("$2")
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    info "Interactive VPS setup started"
    info "Target user: $CURRENT_USER"

    if [[ ${#requested_steps[@]} -gt 0 ]]; then
        local step
        for step in "${requested_steps[@]}"; do
            step_exists "$step" || die "Unknown step: $step"
            run_step_by_name "$step"
        done
    elif [[ "$run_mode" == "all" ]]; then
        run_all_steps
    else
        echo
        if confirm "Run full setup flow?"; then
            run_all_steps
        else
            prompt_custom_steps
        fi
    fi

    echo
    info "Setup complete"
}

main "$@"
