#!/bin/sh
set -e

# idle installer
# Usage: curl -fsSL https://github.com/evil-mind-evil-sword/idle/releases/latest/download/install.sh | sh

REPO="evil-mind-evil-sword/idle"
PLUGIN_DIR="${IDLE_PLUGIN_DIR:-$HOME/.claude/plugins/idle}"

echo "Installing idle plugin..."
echo ""

# --- Install dependencies ---

echo "Checking dependencies..."

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
    echo "Installing jq..."
    if command -v brew >/dev/null 2>&1; then
        brew install jq
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y jq
    else
        echo "Error: jq not found. Please install jq manually."
        exit 1
    fi
fi

# Install jwz (zawinski)
if ! command -v jwz >/dev/null 2>&1; then
    echo "Installing jwz (zawinski)..."
    curl -fsSL https://github.com/femtomc/zawinski/releases/latest/download/install.sh | sh
fi

# Install tissue
if ! command -v tissue >/dev/null 2>&1; then
    echo "Installing tissue..."
    curl -fsSL https://github.com/femtomc/tissue/releases/latest/download/install.sh | sh
fi

echo "Dependencies installed."
echo ""

# --- Install plugin ---

# Get version
if [ -n "$IDLE_VERSION" ]; then
    VERSION="$IDLE_VERSION"
else
    VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
fi

TARBALL_URL="https://github.com/${REPO}/releases/download/${VERSION}/idle-plugin.tar.gz"

echo "Installing idle ${VERSION}..."

# Create plugin directory
mkdir -p "$PLUGIN_DIR"

# Download and extract plugin
curl -fsSL "$TARBALL_URL" | tar -xz -C "$PLUGIN_DIR"

echo "Plugin installed to $PLUGIN_DIR"
echo ""

# --- Register with Claude Code ---

CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# Create settings file if it doesn't exist
if [ ! -f "$CLAUDE_SETTINGS" ]; then
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    echo '{}' > "$CLAUDE_SETTINGS"
fi

# Enable plugin in settings
if command -v jq >/dev/null 2>&1; then
    # Backup settings
    cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak"

    # Add plugin path and enable it
    jq '.plugins = (.plugins // []) + [{"path": "'"$PLUGIN_DIR"'"}] | .plugins = (.plugins | unique_by(.path)) | .enabledPlugins.idle = true' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp"
    mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"

    echo "Plugin registered and enabled in Claude Code settings."
fi

echo ""
echo "Installation complete!"
echo ""
echo "The idle plugin is now active. Every exit will require alice review."
echo ""
echo "Commands:"
echo "  /alice  - Run alice review manually"
echo ""
echo "Dependencies installed:"
echo "  jwz     - Agent messaging"
echo "  tissue  - Issue tracking"
