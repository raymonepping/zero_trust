#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
# Treat unset variables as an error
# Catch failures in piped commands
set -euo pipefail

# Base directory (defaults to current directory if not specified)
BASE_DIR="${1:-.}"

echo "🚀 Bootstrapping workshop structure in: $(realpath "$BASE_DIR")"

# Array of directories to create
DIRS=(
    "terraform"
    "app"
    "workshop/examples"
    "db"
    "scripts"
    "docs"
)

# Array of files to create
FILES=(
    "terraform/main.tf"
    "terraform/vault.tf"
    "terraform/variables.tf"
    "terraform/outputs.tf"
    "terraform/terraform.tfvars.example"
    "app/Dockerfile"
    "app/server.js"
    "app/tools.js"
    "app/package.json"
    "app/.env.example"
    "workshop/credential-provider.js"
    "workshop/examples/phase-0-hardcoded.js"
    "workshop/examples/phase-1-env.js"
    "workshop/examples/phase-2-vault.js"
    "db/seed.sql"
    "docker-compose.yml"
    "scripts/lab_setup.sh"
    "scripts/lab_teardown.sh"
    "scripts/seed_db.sh"
    "scripts/validate_lab.sh"
    "docs/WORKSHOP.md"
    "docs/FACILITATOR.md"
    "README.md"
)

# 1. Create Directories
echo "📂 Creating directories..."
for dir in "${DIRS[@]}"; do
    mkdir -p "$BASE_DIR/$dir"
done

# 2. Create Files
echo "📄 Creating files..."
for file in "${FILES[@]}"; do
    # Using touch to create empty files without overwriting existing ones
    touch "$BASE_DIR/$file"
done

# 3. Apply Executable Permissions
echo "🔧 Setting executable permissions on scripts..."
chmod +x "$BASE_DIR/scripts/"*.sh

echo "✅ Project structure successfully created!"