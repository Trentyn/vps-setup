#!/bin/bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
prompt(){ echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

trap 'error "Setup failed at line $LINENO. Check the output above."' ERR

if [[ $EUID -ne 0 ]]; then
    error "Run this script as root: sudo bash setup.sh"
    exit 1
fi

info "Installing curl..."
apt install -y curl

if command -v docker &>/dev/null; then
    info "Docker already installed — skipping"
else
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
fi

if [[ -n "$SUDO_USER" ]]; then
    usermod -aG docker "$SUDO_USER"
    info "Added $SUDO_USER to docker group"
else
    info "Running as root — skipping docker group (root already has access)"
fi

if [[ -f ~/.ssh/id_ed25519 ]]; then
    prompt "SSH key ~/.ssh/id_ed25519 already exists — skipping generation"
else
    info "Generating SSH key for GitHub Actions..."
    ssh-keygen -t ed25519 -C "github-action-deploy" -f ~/.ssh/id_ed25519 -N ""
fi

cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

echo ""
prompt "Add this PRIVATE key to GitHub → Settings → Secrets → Actions → New secret (name it SSH_KEY):"
echo ""
cat ~/.ssh/id_ed25519
echo ""
read -p "Done? Press Enter to continue..."

if [[ -f ~/.ssh/id_deploy ]]; then
    prompt "Deploy key ~/.ssh/id_deploy already exists — skipping generation"
else
    info "Generating deploy key for git pull..."
    ssh-keygen -t ed25519 -C "deploy-key-only" -f ~/.ssh/id_deploy -N ""
fi

echo ""
prompt "Add this PUBLIC key to GitHub → Settings → Deploy keys → Add deploy key:"
echo ""
cat ~/.ssh/id_deploy.pub
echo ""
read -p "Done? Press Enter to continue..."

if ! grep -q "IdentityFile ~/.ssh/id_deploy" ~/.ssh/config 2>/dev/null; then
    info "Writing SSH config..."
    cat >> ~/.ssh/config << 'SSHEOF'

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_deploy
SSHEOF
    chmod 600 ~/.ssh/config
else
    prompt "SSH config for github.com already exists — skipping"
fi

info "Testing GitHub connection..."
until ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; do
    prompt "Could not verify GitHub connection — make sure the deploy key was added correctly"
    read -p "Press Enter to try again..."
done
info "GitHub connection OK"

echo ""
read -p "Clone a repository? (y/n): " CLONE
if [[ "$CLONE" == "y" ]]; then
    read -p "Repository URL (e.g. https://github.com/user/repo): " REPO_URL
    # Convert https://github.com/user/repo to git@github.com:user/repo.git
    SSH_URL=$(echo "$REPO_URL" | sed 's|https://github.com/|git@github.com:|' | sed 's|\.git$||')".git"
    REPO=$(basename "$REPO_URL" .git)
    git clone "$SSH_URL" ~/"$REPO"
    info "Cloned to ~/$REPO"
fi

echo ""
read -p "Configure git identity for pushing from this VPS? (y/n): " GITCONFIG
if [[ "$GITCONFIG" == "y" ]]; then
    read -p "Email: " GIT_EMAIL
    read -p "Name: " GIT_NAME
    git config --global user.email "$GIT_EMAIL"
    git config --global user.name "$GIT_NAME"
    info "Git identity set"
fi

echo ""
info "Setup complete!"
