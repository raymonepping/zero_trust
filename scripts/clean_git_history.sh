#!/bin/bash
# Script to remove sensitive tokens from git history
# This will rewrite git history - use with caution!

set -e

echo "=========================================="
echo "  Git History Cleanup - Remove Tokens"
echo "=========================================="
echo ""
echo "⚠️  WARNING: This will rewrite git history!"
echo "⚠️  All collaborators will need to re-clone the repository."
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "==> Removing sensitive tokens from git history..."
echo ""

# The token that needs to be removed
OLD_TOKEN="hvs.REDACTED_TOKEN"
REPLACEMENT="hvs.REPLACE_WITH_YOUR_TOKEN"

# Files that contain the token
FILES=(
    "docs/README_LINUX_ROTATION.md"
    "scripts/setup_os_secrets_engine.sh"
    "scripts/setup_vault_os_ssh.sh"
)

# Use git filter-repo if available, otherwise use filter-branch
if command -v git-filter-repo &> /dev/null; then
    echo "Using git-filter-repo (recommended)..."
    
    # Create a replacement file
    cat > /tmp/git-replacements.txt <<EOF
${OLD_TOKEN}==>${REPLACEMENT}
EOF
    
    git filter-repo --replace-text /tmp/git-replacements.txt --force
    rm /tmp/git-replacements.txt
    
else
    echo "Using git filter-branch (slower)..."
    echo "Consider installing git-filter-repo: pip install git-filter-repo"
    echo ""
    
    # Use filter-branch to rewrite history
    git filter-branch --force --index-filter \
        "git ls-files -z | xargs -0 sed -i '' 's/${OLD_TOKEN}/${REPLACEMENT}/g'" \
        --prune-empty --tag-name-filter cat -- --all
fi

echo ""
echo "==> Cleaning up..."
rm -rf .git/refs/original/
git reflog expire --expire=now --all
git gc --prune=now --aggressive

echo ""
echo "=========================================="
echo "  ✓ Git history cleaned!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Verify the changes: git log --all --oneline"
echo "  2. Force push to remote: git push origin --force --all"
echo "  3. Force push tags: git push origin --force --tags"
echo ""
echo "⚠️  Important:"
echo "  - All collaborators must re-clone the repository"
echo "  - Notify team members before force pushing"
echo "  - Backup your repository before proceeding"
echo ""

# Made with Bob
