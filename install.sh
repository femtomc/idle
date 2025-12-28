#!/bin/sh
set -e

# idle dependency installer
# Usage: curl -fsSL https://raw.githubusercontent.com/femtomc/idle/main/install.sh | sh

# Colors for output
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

info() { printf "${BLUE}info${NC}: %s\n" "$1"; }
success() { printf "${GREEN}success${NC}: %s\n" "$1"; }
warn() { printf "${YELLOW}warning${NC}: %s\n" "$1"; }
error() { printf "${RED}error${NC}: %s\n" "$1" >&2; exit 1; }

check_command() {
    command -v "$1" >/dev/null 2>&1
}

install_uv() {
    if check_command uv; then
        success "uv already installed"
        return
    fi
    info "Installing uv (Python package runner)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    success "uv installed"
}

install_gh() {
    if check_command gh; then
        success "gh already installed"
        return
    fi
    info "Installing gh (GitHub CLI)..."
    case "$(uname -s)" in
        Darwin*)
            if check_command brew; then
                brew install gh
                success "gh installed"
            else
                warn "Install Homebrew first, or install gh manually: https://cli.github.com/"
            fi
            ;;
        Linux*)
            if check_command apt-get; then
                (type -p wget >/dev/null || sudo apt-get install wget -y) \
                && sudo mkdir -p -m 755 /etc/apt/keyrings \
                && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
                && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
                && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
                && sudo apt-get update \
                && sudo apt-get install gh -y
                success "gh installed"
            elif check_command dnf; then
                sudo dnf install -y gh
                success "gh installed"
            elif check_command pacman; then
                sudo pacman -S --noconfirm github-cli
                success "gh installed"
            else
                warn "Install gh manually: https://cli.github.com/"
            fi
            ;;
        *)
            warn "Install gh manually: https://cli.github.com/"
            ;;
    esac
}

install_tissue() {
    if check_command tissue; then
        success "tissue already installed"
        return
    fi
    info "Installing tissue (issue tracker)..."
    if check_command cargo; then
        cargo install --git https://github.com/femtomc/tissue tissue
        success "tissue installed"
    else
        warn "Rust/Cargo not found. Install from https://rustup.rs/ then run:"
        warn "  cargo install --git https://github.com/femtomc/tissue tissue"
    fi
}

install_jwz() {
    if check_command jwz; then
        success "jwz already installed"
        return
    fi
    info "Installing jwz (async messaging)..."
    if check_command cargo; then
        cargo install --git https://github.com/femtomc/zawinski jwz
        success "jwz installed"
    else
        warn "Rust/Cargo not found. Install from https://rustup.rs/ then run:"
        warn "  cargo install --git https://github.com/femtomc/zawinski jwz"
    fi
}

check_optional_deps() {
    printf "\n"
    info "Checking optional dependencies for enhanced multi-model support..."
    printf "\n"

    if check_command codex; then
        success "codex found - oracle/reviewer will use OpenAI for diverse perspectives"
    else
        info "codex not found - agents will use Claude for second opinions"
        printf "    To enable OpenAI diversity: npm install -g @openai/codex\n"
    fi

    if check_command gemini; then
        success "gemini found - documenter will use Gemini for writing"
    else
        info "gemini not found - documenter will use Claude for writing"
        printf "    To enable Gemini diversity: npm install -g @google/gemini-cli\n"
    fi
}

main() {
    printf "\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    printf "\n"
    printf "  ${BLUE}idle${NC} - dependency installer\n"
    printf "\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    printf "\n"

    # Required dependencies
    info "Installing required dependencies..."
    install_uv
    install_gh
    install_tissue
    install_jwz

    # Optional dependencies (just check, don't install)
    check_optional_deps

    printf "\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    printf "\n"
    success "Dependencies installed!"
    printf "\n"

    # Install the Claude Code plugin
    if check_command claude; then
        info "Installing idle plugin..."
        claude plugin marketplace add trivial/idle 2>/dev/null || true
        if claude plugin install idle@trivial 2>/dev/null; then
            success "idle plugin installed!"
        else
            warn "Plugin install failed. Try manually in Claude Code:"
            printf "  ${GREEN}/plugin marketplace add trivial/idle${NC}\n"
            printf "  ${GREEN}/plugin install idle@trivial${NC}\n"
        fi
    else
        warn "claude CLI not found. Install the plugin manually in Claude Code:"
        printf "\n"
        printf "  ${GREEN}/plugin marketplace add trivial/idle${NC}\n"
        printf "  ${GREEN}/plugin install idle@trivial${NC}\n"
    fi

    printf "\n"
    printf "Start using idle:\n"
    printf "\n"
    printf "  ${BLUE}tissue init${NC}      # Initialize issue tracker\n"
    printf "  ${BLUE}jwz init${NC}         # Initialize messaging\n"
    printf "  ${BLUE}/grind${NC}           # Work through issues\n"
    printf "  ${BLUE}/review${NC}          # Code review\n"
    printf "\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
}

main
