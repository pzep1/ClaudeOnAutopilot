#!/usr/bin/env bash
# Autonomous Claude Code Workflow - Stop Controller
# Gracefully stops the workflow or force-kills if needed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
CONFIG_FILE="$SCRIPT_DIR/config.json"
STATE_FILE="$SCRIPT_DIR/state.json"
STOP_FILE="$SCRIPT_DIR/STOP"
LOG_FILE="$SCRIPT_DIR/run.log"
LOCK_FILE="$SCRIPT_DIR/.lock"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Discord notification (reuse from main script)
DISCORD_WEBHOOK_URL=""
if [[ -f "$CONFIG_FILE" ]]; then
    DISCORD_WEBHOOK_URL=$(jq -r '.discord_webhook_url // ""' "$CONFIG_FILE" 2>/dev/null)
fi

# ============================================================================
# HELPERS
# ============================================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" >> "$LOG_FILE" 2>/dev/null || true
    echo -e "$msg"
}

discord_notify() {
    local title="$1"
    local description="$2"
    local color="${3:-9807270}"
    
    if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
        return 0
    fi
    
    local repo_name=$(basename "$PROJECT_DIR")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    curl -s -H "Content-Type: application/json" \
        -X POST \
        -d "{
            \"embeds\": [{
                \"title\": \"$title\",
                \"description\": \"$description\",
                \"color\": $color,
                \"footer\": {\"text\": \"$repo_name • Autonomous Workflow\"},
                \"timestamp\": \"$timestamp\"
            }]
        }" \
        "$DISCORD_WEBHOOK_URL" > /dev/null 2>&1 || true
}

get_pid() {
    if [[ -f "$LOCK_FILE" ]]; then
        cat "$LOCK_FILE" 2>/dev/null
    else
        echo ""
    fi
}

is_running() {
    local pid=$(get_pid)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

print_status() {
    if is_running; then
        local pid=$(get_pid)
        echo -e "${GREEN}●${NC} Workflow is ${GREEN}running${NC} (PID: $pid)"
    else
        echo -e "${DIM}○${NC} Workflow is ${DIM}not running${NC}"
    fi
    
    if [[ -f "$STOP_FILE" ]]; then
        echo -e "${YELLOW}⚠${NC} Stop already requested"
    fi
}

# ============================================================================
# STOP MODES
# ============================================================================

graceful_stop() {
    echo -e "\n${BOLD}${BLUE}Graceful Stop${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    print_status
    echo ""
    
    if ! is_running; then
        echo -e "${YELLOW}Nothing to stop.${NC}"
        # Clean up stale files
        rm -f "$LOCK_FILE" "$STOP_FILE" 2>/dev/null || true
        return 0
    fi
    
    if [[ -f "$STOP_FILE" ]]; then
        echo -e "${YELLOW}Stop already requested. Use --force to kill immediately.${NC}"
        return 0
    fi
    
    echo -e "Creating stop file..."
    touch "$STOP_FILE"
    log "[STOP] Graceful stop requested by user"
    
    echo -e "${GREEN}✓${NC} Stop requested. Workflow will halt after current iteration."
    echo -e "${DIM}  This may take several minutes if Claude is mid-task.${NC}"
    echo -e "${DIM}  Use '$0 --force' to kill immediately.${NC}"
    
    discord_notify "⏹️ Stop Requested" "Graceful shutdown initiated - will halt after current iteration" "15105570"
}

force_stop() {
    echo -e "\n${BOLD}${RED}Force Stop${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    print_status
    echo ""
    
    local pid=$(get_pid)
    
    if [[ -z "$pid" ]]; then
        echo -e "${YELLOW}No PID found in lock file.${NC}"
        rm -f "$LOCK_FILE" "$STOP_FILE" 2>/dev/null || true
        return 0
    fi
    
    if ! kill -0 "$pid" 2>/dev/null; then
        echo -e "${YELLOW}Process $pid is not running.${NC}"
        rm -f "$LOCK_FILE" "$STOP_FILE" 2>/dev/null || true
        return 0
    fi
    
    echo -e "${YELLOW}Killing process tree for PID $pid...${NC}"
    
    # Kill child processes first (including claude)
    pkill -TERM -P "$pid" 2>/dev/null || true
    sleep 1
    pkill -KILL -P "$pid" 2>/dev/null || true
    
    # Kill main process
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    
    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${YELLOW}Process still alive, sending SIGKILL...${NC}"
        kill -KILL "$pid" 2>/dev/null || true
        sleep 1
    fi
    
    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${RED}✗${NC} Failed to kill process $pid"
        return 1
    fi
    
    # Cleanup
    rm -f "$LOCK_FILE" "$STOP_FILE" 2>/dev/null || true
    
    log "[STOP] Force stop executed - process $pid killed"
    echo -e "${GREEN}✓${NC} Process killed and cleaned up."
    
    discord_notify "🛑 Force Stopped" "Workflow forcefully terminated" "15158332"
}

cancel_stop() {
    echo -e "\n${BOLD}${BLUE}Cancel Stop${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    if [[ ! -f "$STOP_FILE" ]]; then
        echo -e "${YELLOW}No pending stop request to cancel.${NC}"
        return 0
    fi
    
    rm -f "$STOP_FILE"
    log "[STOP] Stop request cancelled by user"
    
    echo -e "${GREEN}✓${NC} Stop request cancelled. Workflow will continue."
    
    discord_notify "▶️ Stop Cancelled" "Workflow will continue processing" "3066993"
}

wait_for_stop() {
    local timeout="${1:-300}"  # Default 5 minutes
    
    echo -e "\n${BOLD}${BLUE}Waiting for Graceful Stop${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    if ! is_running; then
        echo -e "${GREEN}✓${NC} Workflow is not running."
        return 0
    fi
    
    # Request stop if not already
    if [[ ! -f "$STOP_FILE" ]]; then
        touch "$STOP_FILE"
        log "[STOP] Graceful stop requested (with wait)"
    fi
    
    echo -e "Waiting up to ${timeout}s for workflow to stop..."
    echo -e "${DIM}Press Ctrl+C to force kill${NC}\n"
    
    local pid=$(get_pid)
    local elapsed=0
    local spinner=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0
    
    trap "echo ''; force_stop; exit 0" INT
    
    while [[ $elapsed -lt $timeout ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo -e "\n${GREEN}✓${NC} Workflow stopped gracefully."
            rm -f "$LOCK_FILE" "$STOP_FILE" 2>/dev/null || true
            return 0
        fi
        
        printf "\r  ${YELLOW}${spinner[$i]}${NC} Waiting... (${elapsed}s / ${timeout}s)  "
        i=$(( (i + 1) % ${#spinner[@]} ))
        
        sleep 1
        ((elapsed++))
    done
    
    echo -e "\n${YELLOW}Timeout reached.${NC}"
    read -p "Force kill? [y/N] " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        force_stop
    else
        echo -e "${DIM}Workflow still running. Use '$0 --force' to kill.${NC}"
    fi
}

cleanup_stale() {
    echo -e "\n${BOLD}${BLUE}Cleanup Stale Files${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    local cleaned=0
    
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$LOCK_FILE"
            echo -e "${GREEN}✓${NC} Removed stale lock file (PID $pid not running)"
            ((cleaned++))
        else
            echo -e "${YELLOW}⚠${NC} Lock file is valid (PID $pid is running)"
        fi
    fi
    
    if [[ -f "$STOP_FILE" ]] && ! is_running; then
        rm -f "$STOP_FILE"
        echo -e "${GREEN}✓${NC} Removed orphaned stop file"
        ((cleaned++))
    fi
    
    if [[ $cleaned -eq 0 ]]; then
        echo -e "${DIM}No stale files to clean.${NC}"
    fi
}

# ============================================================================
# USAGE
# ============================================================================

usage() {
    cat <<EOF
${BOLD}Autonomous Workflow Stop Controller${NC}

${BOLD}Usage:${NC} $0 [COMMAND]

${BOLD}Commands:${NC}
  ${GREEN}(default)${NC}      Graceful stop - halt after current iteration
  ${GREEN}--force, -f${NC}    Force kill immediately
  ${GREEN}--cancel, -c${NC}   Cancel a pending stop request
  ${GREEN}--wait, -w${NC}     Request stop and wait for completion
  ${GREEN}--cleanup${NC}      Remove stale lock/stop files
  ${GREEN}--status, -s${NC}   Show current status
  ${GREEN}--help, -h${NC}     Show this help

${BOLD}Examples:${NC}
  $0              # Request graceful stop
  $0 --wait       # Stop and wait (with timeout)
  $0 --force      # Kill immediately
  $0 --cancel     # Continue if stop was requested

${BOLD}Files:${NC}
  Lock file:  $LOCK_FILE
  Stop file:  $STOP_FILE
  State:      $STATE_FILE
EOF
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-}" in
    -h|--help)
        usage
        ;;
    -f|--force)
        force_stop
        ;;
    -c|--cancel)
        cancel_stop
        ;;
    -w|--wait)
        wait_for_stop "${2:-300}"
        ;;
    --cleanup)
        cleanup_stale
        ;;
    -s|--status)
        echo ""
        print_status
        echo ""
        ;;
    "")
        graceful_stop
        ;;
    *)
        echo -e "${RED}Unknown option: $1${NC}"
        echo ""
        usage
        exit 1
        ;;
esac