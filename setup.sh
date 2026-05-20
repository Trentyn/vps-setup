#!/bin/bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
prompt(){ echo -e "${YELLOW}[!]${NC} $1"; }

info "Installing curl..."
apt install -y curl

info "Installing Docker..."
curl -fsSL https://get.docker.com | sh
usermod -aG docker $USER

info "Generating SSH key for GitHub Actions..."
ssh-keygen -t ed25519 -C "github-action-deploy" -f ~/.ssh/id_ed25519 -N ""

cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

echo ""
prompt "Add this PRIVATE key to GitHub → Settings → Secrets → Actions → New secret (name it SSH_KEY):"
echo ""
cat ~/.ssh/id_ed25519
echo ""
read -p "Done? Press Enter to continue..."

info "Generating deploy key for git pull..."
ssh-keygen -t ed25519 -C "deploy-key-only" -f ~/.ssh/id_deploy -N ""

echo ""
prompt "Add this PUBLIC key to GitHub → Settings → Deploy keys → Add deploy key:"
echo ""
cat ~/.ssh/id_deploy.pub
echo ""
read -p "Done? Press Enter to continue..."

info "Writing SSH config..."
cat >> ~/.ssh/config << 'SSHEOF'

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_deploy
SSHEOF
chmod 600 ~/.ssh/config

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
    REPO=$(basename "$REPO_URL" .git)
    git clone "$REPO_URL" ~/
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
