#!/bin/bash
# idle hooks shared utilities
# Source this file in hooks: source "${BASH_SOURCE%/*}/utils.sh"

# Get project name from git remote or directory basename
get_project_name() {
    local cwd="${1:-.}"
    local name=""

    # Try git remote first
    if command -v git &>/dev/null; then
        name=$(git -C "$cwd" remote get-url origin 2>/dev/null | sed -E 's/.*[:/]([^/]+)\/([^/.]+)(\.git)?$/\2/' || true)
    fi

    # Fall back to directory basename
    if [[ -z "$name" ]]; then
        name=$(basename "$(cd "$cwd" && pwd)")
    fi

    echo "$name"
}

# Get current git branch
get_git_branch() {
    local cwd="${1:-.}"
    git -C "$cwd" branch --show-current 2>/dev/null || echo ""
}

# Get GitHub repo URL from git remote
get_repo_url() {
    local cwd="${1:-.}"
    local remote_url=""

    if command -v git &>/dev/null; then
        remote_url=$(git -C "$cwd" remote get-url origin 2>/dev/null || echo "")
    fi

    if [[ -z "$remote_url" ]]; then
        echo ""
        return
    fi

    # Convert SSH to HTTPS URL
    # git@github.com:user/repo.git -> https://github.com/user/repo
    if [[ "$remote_url" == git@* ]]; then
        remote_url=$(echo "$remote_url" | sed -E 's/git@([^:]+):/https:\/\/\1\//' | sed 's/\.git$//')
    fi

    # Clean up .git suffix from HTTPS URLs
    remote_url="${remote_url%.git}"

    echo "$remote_url"
}

# Unified notification function - dispatches to Discord or ntfy
# Usage: notify "title" "body" [priority] [emoji] [repo_url]
# Priority: 1=min, 2=low, 3=default, 4=high, 5=urgent
notify() {
    local title="$1"
    local body="$2"
    local priority="${3:-3}"
    local emoji="${4:-}"
    local repo_url="${5:-}"

    # Prefer Discord if configured, fall back to ntfy
    if [[ -n "${IDLE_DISCORD_WEBHOOK:-}" ]]; then
        discord_post "$title" "$body" "$priority" "$emoji" "$repo_url"
    elif [[ -n "${IDLE_NTFY_TOPIC:-}" ]]; then
        ntfy_post "$title" "$body" "$priority" "$emoji" "$repo_url"
    fi
}

# Post to Discord webhook with rich embed
# Colors: green=5763719, red=15548997, yellow=16705372, blue=5793266
discord_post() {
    local title="$1"
    local body="$2"
    local priority="${3:-3}"
    local emoji="${4:-}"
    local repo_url="${5:-}"

    local webhook="${IDLE_DISCORD_WEBHOOK:-}"
    if [[ -z "$webhook" ]]; then
        return 0
    fi

    # Map priority to color
    local color=5793266  # blue (default)
    case "$priority" in
        4|5) color=15548997 ;;  # red (high/urgent)
        1|2) color=8421504 ;;   # gray (low)
    esac

    # Map emoji tag to actual emoji
    local emoji_char=""
    case "$emoji" in
        rocket) emoji_char="🚀" ;;
        speech_balloon) emoji_char="💬" ;;
        white_check_mark) emoji_char="✅" ;;
        x) emoji_char="❌" ;;
        hourglass) emoji_char="⏳" ;;
    esac

    # Prepend emoji to title if present
    [[ -n "$emoji_char" ]] && title="$emoji_char $title"

    # Build JSON payload
    local payload
    if [[ -n "$repo_url" ]]; then
        payload=$(jq -n \
            --arg title "$title" \
            --arg desc "$body" \
            --argjson color "$color" \
            --arg url "$repo_url" \
            '{embeds: [{title: $title, description: $desc, color: $color, url: $url}]}')
    else
        payload=$(jq -n \
            --arg title "$title" \
            --arg desc "$body" \
            --argjson color "$color" \
            '{embeds: [{title: $title, description: $desc, color: $color}]}')
    fi

    # Post in background to not block hook
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$webhook" &>/dev/null &
}

# Post to ntfy with rich formatting (legacy, kept for compatibility)
ntfy_post() {
    local title="$1"
    local body="$2"
    local priority="${3:-3}"
    local tags="${4:-}"
    local click_url="${5:-}"

    local topic="${IDLE_NTFY_TOPIC:-}"
    if [[ -z "$topic" ]]; then
        return 0
    fi

    local server="${IDLE_NTFY_SERVER:-https://ntfy.sh}"
    local url="$server/$topic"

    local -a args=(
        -s
        -X POST
        -H "Title: $title"
        -H "Priority: $priority"
    )

    if [[ -n "$tags" ]]; then
        args+=(-H "Tags: $tags")
    fi

    if [[ -n "$click_url" ]]; then
        args+=(-H "Actions: view, Open Repo, $click_url")
    fi

    args+=(-d "$body" "$url")

    curl "${args[@]}" &>/dev/null &
}

# Format tool availability as checkmarks
format_tool_status() {
    local tool="$1"
    if command -v "$tool" &>/dev/null; then
        echo "✓"
    else
        echo "✗"
    fi
}
