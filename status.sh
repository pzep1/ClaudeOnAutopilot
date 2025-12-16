#!/usr/bin/env bash
# Autonomous Claude Code Workflow - Status Checker
# Shows current state, active processes, and recent activity

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
CONFIG_FILE="$SCRIPT_DIR/config.json"
STATE_FILE="$SCRIPT_DIR/state.json"
STOP_FILE="$SCRIPT_DIR/STOP"
LOG_FILE="$SCRIPT_DIR/run.log"
LOCK_FILE="$SCRIPT_DIR/.lock"
GH="/home/linuxbrew/.linuxbrew/bin/gh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================================
# HELPERS
# ============================================================================

print_header() {
    echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_section() {
    echo -e "\n${BOLD}${CYAN}▸ $1${NC}"
}

print_kv() {
    local key="$1"
    local value="$2"
    local color="${3:-$NC}"
    printf "  ${DIM}%-20s${NC} ${color}%s${NC}\n" "$key:" "$value"
}

print_status_badge() {
    local status="$1"
    case "$status" in
        "running"|"active"|"passed"|"completed"|"success")
            echo -e "${GREEN}● $status${NC}"
            ;;
        "stopped"|"inactive"|"failed"|"error")
            echo -e "${RED}● $status${NC}"
            ;;
        "pending"|"waiting"|"pending_merge")
            echo -e "${YELLOW}● $status${NC}"
            ;;
        *)
            echo -e "${DIM}○ $status${NC}"
            ;;
    esac
}

human_time_diff() {
    local seconds="$1"
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s"
    elif [[ $seconds -lt 3600 ]]; then
        echo "$((seconds / 60))m $((seconds % 60))s"
    elif [[ $seconds -lt 86400 ]]; then
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
    else
        echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h"
    fi
}

# ============================================================================
# STATUS CHECKS
# ============================================================================

check_process_status() {
    print_section "Process Status"
    
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            print_kv "Workflow" "$(print_status_badge "running")"
            print_kv "PID" "$pid"
            
            # Get process runtime
            local start_time=$(ps -o lstart= -p "$pid" 2>/dev/null | xargs -I{} date -d "{}" +%s 2>/dev/null || echo "")
            if [[ -n "$start_time" ]]; then
                local now=$(date +%s)
                local runtime=$((now - start_time))
                print_kv "Runtime" "$(human_time_diff $runtime)"
            fi
            
            # Check what it's doing (look for claude process)
            local claude_pid=$(pgrep -P "$pid" -f "claude" 2>/dev/null | head -1 || echo "")
            if [[ -n "$claude_pid" ]]; then
                print_kv "Claude" "$(print_status_badge "active") (PID: $claude_pid)"
            fi
        else
            print_kv "Workflow" "$(print_status_badge "stopped")"
            print_kv "Note" "${DIM}Stale lock file exists (PID: $pid not running)${NC}"
        fi
    else
        print_kv "Workflow" "$(print_status_badge "inactive")"
    fi
    
    # Check for stop file
    if [[ -f "$STOP_FILE" ]]; then
        print_kv "Stop Requested" "${YELLOW}Yes - will halt after current iteration${NC}"
    fi
}

check_last_state() {
    print_section "Last Known State"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        echo -e "  ${DIM}No state file found${NC}"
        return
    fi
    
    local iteration=$(jq -r '.last_iteration // "?"' "$STATE_FILE")
    local issue=$(jq -r '.last_issue // "?"' "$STATE_FILE")
    local status=$(jq -r '.last_status // "unknown"' "$STATE_FILE")
    local timestamp=$(jq -r '.timestamp // ""' "$STATE_FILE")
    
    print_kv "Iteration" "$iteration"
    print_kv "Issue" "#$issue"
    print_kv "Status" "$(print_status_badge "$status")"
    
    if [[ -n "$timestamp" ]]; then
        local state_time=$(date -d "$timestamp" +%s 2>/dev/null || echo "")
        if [[ -n "$state_time" ]]; then
            local now=$(date +%s)
            local age=$((now - state_time))
            print_kv "Last Update" "$(human_time_diff $age) ago"
        else
            print_kv "Timestamp" "$timestamp"
        fi
    fi
}

check_config() {
    print_section "Configuration"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "  ${RED}Config file not found: $CONFIG_FILE${NC}"
        return
    fi
    
    local max_iter=$(jq -r '.max_iterations // 10' "$CONFIG_FILE")
    local auto_merge=$(jq -r '.auto_merge // false' "$CONFIG_FILE")
    local ci_required=$(jq -r '.ci_required // true' "$CONFIG_FILE")
    local discord=$(jq -r '.discord_webhook_url // ""' "$CONFIG_FILE")
    local labels=$(jq -r '.labels_to_process // [] | join(", ")' "$CONFIG_FILE")
    
    print_kv "Max Iterations" "$max_iter"
    print_kv "Auto Merge" "$auto_merge"
    print_kv "CI Required" "$ci_required"
    print_kv "Discord" "$([ -n "$discord" ] && echo "${GREEN}configured${NC}" || echo "${DIM}not set${NC}")"
    print_kv "Labels" "$([ -n "$labels" ] && echo "$labels" || echo "${DIM}all${NC}")"
}

check_github_status() {
    print_section "GitHub Status"
    
    cd "$PROJECT_DIR" 2>/dev/null || {
        echo -e "  ${RED}Cannot access project directory${NC}"
        return
    }
    
    # Current branch
    local branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    print_kv "Current Branch" "$branch"
    
    # Open issues count
    local open_issues=$($GH issue list --state open --json number 2>/dev/null | jq 'length' || echo "?")
    print_kv "Open Issues" "$open_issues"
    
    # Open PRs from workflow
    local workflow_prs=$($GH pr list --state open --search "head:issue-" --json number,title,headRefName 2>/dev/null || echo "[]")
    local pr_count=$(echo "$workflow_prs" | jq 'length')
    print_kv "Workflow PRs" "$pr_count"
    
    if [[ "$pr_count" -gt 0 ]]; then
        echo ""
        echo "$workflow_prs" | jq -r '.[] | "    \u001b[33m#\(.number)\u001b[0m \(.title) \u001b[2m(\(.headRefName))\u001b[0m"'
    fi
}

check_recent_activity() {
    print_section "Recent Log Activity"
    
    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "  ${DIM}No log file found${NC}"
        return
    fi
    
    local log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
    print_kv "Log Size" "$log_size"
    
    echo -e "\n  ${DIM}Last 10 entries:${NC}"
    tail -n 10 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
        # Colorize log levels
        line=$(echo "$line" | sed -E \
            -e "s/\[INFO\]/${BLUE}[INFO]${NC}/g" \
            -e "s/\[SUCCESS\]/${GREEN}[SUCCESS]${NC}/g" \
            -e "s/\[WARN\]/${YELLOW}[WARN]${NC}/g" \
            -e "s/\[ERROR\]/${RED}[ERROR]${NC}/g")
        echo -e "    $line"
    done
}

check_statistics() {
    print_section "Session Statistics"
    
    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "  ${DIM}No log file for statistics${NC}"
        return
    fi
    
    local total_iterations=$(grep -c "^.*ITERATION [0-9]* of" "$LOG_FILE" 2>/dev/null || echo "0")
    local completed=$(grep -c '\[SUCCESS\].*Completed issue' "$LOG_FILE" 2>/dev/null || echo "0")
    local failed=$(grep -c '\[ERROR\].*failed' "$LOG_FILE" 2>/dev/null || echo "0")
    local prs_created=$(grep -c '\[SUCCESS\].*Created PR' "$LOG_FILE" 2>/dev/null || echo "0")
    
    print_kv "Total Iterations" "$total_iterations"
    print_kv "Completed" "${GREEN}$completed${NC}"
    print_kv "Failed" "${RED}$failed${NC}"
    print_kv "PRs Created" "$prs_created"
    
    if [[ $total_iterations -gt 0 ]]; then
        local success_rate=$((completed * 100 / total_iterations))
        print_kv "Success Rate" "${success_rate}%"
    fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    print_header "Autonomous Workflow Status"
    
    echo -e "\n${DIM}Project: $PROJECT_DIR${NC}"
    echo -e "${DIM}Time: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    
    check_process_status
    check_last_state
    check_config
    check_github_status
    check_recent_activity
    check_statistics
    
    echo ""
}

# Handle arguments
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  -h, --help     Show this help"
        echo "  -w, --watch    Continuous monitoring (refresh every 5s)"
        echo "  -l, --log      Show full log (last 50 lines)"
        echo "  -j, --json     Output status as JSON"
        exit 0
        ;;
    -w|--watch)
        while true; do
            clear
            main
            echo -e "\n${DIM}Refreshing in 5s... (Ctrl+C to exit)${NC}"
            sleep 5
        done
        ;;
    -l|--log)
        if [[ -f "$LOG_FILE" ]]; then
            tail -n 50 "$LOG_FILE"
        else
            echo "No log file found"
        fi
        exit 0
        ;;
    -j|--json)
        # JSON output for programmatic access
        running="false"
        pid=""
        if [[ -f "$LOCK_FILE" ]]; then
            pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if kill -0 "$pid" 2>/dev/null; then
                running="true"
            fi
        fi
        
        stop_requested="false"
        [[ -f "$STOP_FILE" ]] && stop_requested="true"
        
        state="{}"
        [[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
        
        cat <<EOF
{
  "running": $running,
  "pid": "$pid",
  "stop_requested": $stop_requested,
  "state": $state,
  "timestamp": "$(date -Iseconds)"
}
EOF
        exit 0
        ;;
    *)
        main
        ;;
esac