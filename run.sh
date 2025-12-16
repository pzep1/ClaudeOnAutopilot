#!/usr/bin/env bash
# Autonomous Claude Code Workflow Runner
# Runs Claude Code in a loop: fetch issue -> work -> PR -> CI -> review -> merge
#
# STOP MECHANISM: Create .claude/autonomous/STOP file to halt after current iteration
# Or press Ctrl+C to interrupt

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
NC='\033[0m'

# Discord embed colors (decimal)
DISCORD_COLOR_SUCCESS=3066993    # Green
DISCORD_COLOR_ERROR=15158332     # Red
DISCORD_COLOR_WARNING=15105570   # Orange
DISCORD_COLOR_INFO=3447003       # Blue
DISCORD_COLOR_PENDING=9807270    # Gray

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" >> "$LOG_FILE"
    echo -e "$msg" >&2
}

log_info() { log "${BLUE}[INFO]${NC} $1"; }
log_success() { log "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { log "${YELLOW}[WARN]${NC} $1"; }
log_error() { log "${RED}[ERROR]${NC} $1"; }
log_debug() { [[ "$DEBUG" == "true" ]] && log "${PURPLE}[DEBUG]${NC} $1"; }

# ============================================================================
# DISCORD NOTIFICATIONS
# ============================================================================

discord_send() {
    local payload="$1"
    
    if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
        log_debug "Discord webhook not configured, skipping notification"
        return 0
    fi
    
    curl -s -H "Content-Type: application/json" \
        -X POST \
        -d "$payload" \
        "$DISCORD_WEBHOOK_URL" > /dev/null 2>&1 || log_warn "Failed to send Discord notification"
}

discord_notify() {
    local title="$1"
    local description="$2"
    local color="${3:-$DISCORD_COLOR_INFO}"
    local fields="${4:-[]}"
    local url="${5:-}"
    
    local url_field=""
    if [[ -n "$url" ]]; then
        url_field="\"url\": \"$url\","
    fi
    
    local repo_name=$(basename "$PROJECT_DIR")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local payload=$(cat <<EOF
{
    "embeds": [{
        "title": "$title",
        $url_field
        "description": "$description",
        "color": $color,
        "fields": $fields,
        "footer": {
            "text": "$repo_name • Autonomous Workflow"
        },
        "timestamp": "$timestamp"
    }]
}
EOF
)
    
    discord_send "$payload"
}

discord_workflow_start() {
    local iterations="$1"
    discord_notify \
        "🤖 Autonomous Workflow Started" \
        "Beginning automated issue processing" \
        "$DISCORD_COLOR_INFO" \
        "[{\"name\": \"Max Iterations\", \"value\": \"$iterations\", \"inline\": true}, {\"name\": \"Auto Merge\", \"value\": \"$AUTO_MERGE\", \"inline\": true}]"
}

discord_workflow_end() {
    local completed="$1"
    local failed="$2"
    discord_notify \
        "🏁 Autonomous Workflow Complete" \
        "Finished processing issues" \
        "$DISCORD_COLOR_SUCCESS" \
        "[{\"name\": \"Completed\", \"value\": \"$completed\", \"inline\": true}, {\"name\": \"Failed\", \"value\": \"$failed\", \"inline\": true}]"
}

discord_issue_start() {
    local issue_num="$1"
    local title="$2"
    local issue_url="$3"
    discord_notify \
        "📋 Processing Issue #$issue_num" \
        "$title" \
        "$DISCORD_COLOR_INFO" \
        "[]" \
        "$issue_url"
}

discord_pr_created() {
    local pr_num="$1"
    local issue_num="$2"
    local pr_url="$3"
    discord_notify \
        "🔀 PR #$pr_num Created" \
        "Automated PR for issue #$issue_num" \
        "$DISCORD_COLOR_PENDING" \
        "[{\"name\": \"Status\", \"value\": \"Awaiting CI\", \"inline\": true}]" \
        "$pr_url"
}

discord_ci_status() {
    local pr_num="$1"
    local status="$2"
    local pr_url="$3"
    
    local color="$DISCORD_COLOR_PENDING"
    local emoji="⏳"
    
    case "$status" in
        "success"|"passed")
            color="$DISCORD_COLOR_SUCCESS"
            emoji="✅"
            ;;
        "failure"|"failed")
            color="$DISCORD_COLOR_ERROR"
            emoji="❌"
            ;;
        "pending"|"running")
            color="$DISCORD_COLOR_PENDING"
            emoji="🔄"
            ;;
    esac
    
    discord_notify \
        "$emoji CI Status: $status" \
        "PR #$pr_num CI checks $status" \
        "$color" \
        "[]" \
        "$pr_url"
}

discord_pr_merged() {
    local pr_num="$1"
    local issue_num="$2"
    local pr_url="$3"
    discord_notify \
        "🎉 PR #$pr_num Merged" \
        "Issue #$issue_num has been resolved" \
        "$DISCORD_COLOR_SUCCESS" \
        "[]" \
        "$pr_url"
}

discord_error() {
    local title="$1"
    local description="$2"
    local issue_num="${3:-}"
    
    local fields="[]"
    if [[ -n "$issue_num" ]]; then
        fields="[{\"name\": \"Issue\", \"value\": \"#$issue_num\", \"inline\": true}]"
    fi
    
    discord_notify \
        "❌ $title" \
        "$description" \
        "$DISCORD_COLOR_ERROR" \
        "$fields"
}

# ============================================================================
# CI STATUS CHECKS
# ============================================================================

get_pr_check_status() {
    local pr_number="$1"
    
    # Get combined status of all checks
    local checks_json=$($GH pr checks "$pr_number" --json name,state,conclusion 2>/dev/null || echo "[]")
    
    if [[ "$checks_json" == "[]" || -z "$checks_json" ]]; then
        echo "no_checks"
        return
    fi
    
    # Check if any are still running
    local pending=$(echo "$checks_json" | jq '[.[] | select(.state == "PENDING" or .state == "QUEUED" or .state == "IN_PROGRESS")] | length')
    if [[ "$pending" -gt 0 ]]; then
        echo "pending"
        return
    fi
    
    # Check if any failed
    local failed=$(echo "$checks_json" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT")] | length')
    if [[ "$failed" -gt 0 ]]; then
        echo "failed"
        return
    fi
    
    # All passed
    echo "passed"
}

wait_for_ci() {
    local pr_number="$1"
    local max_wait="${2:-30}"  # Default 30 minutes
    local check_interval="${3:-30}"  # Check every 30 seconds
    
    log_info "Waiting for CI checks on PR #$pr_number (max ${max_wait}m)..."
    
    local elapsed=0
    local max_seconds=$((max_wait * 60))
    
    while [[ $elapsed -lt $max_seconds ]]; do
        check_stop
        
        local status=$(get_pr_check_status "$pr_number")
        
        case "$status" in
            "passed")
                log_success "CI checks passed for PR #$pr_number"
                return 0
                ;;
            "failed")
                log_error "CI checks failed for PR #$pr_number"
                return 1
                ;;
            "no_checks")
                log_info "No CI checks configured, proceeding..."
                return 0
                ;;
            "pending")
                log_debug "CI still running... (${elapsed}s elapsed)"
                ;;
        esac
        
        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done
    
    log_error "CI timeout after ${max_wait} minutes for PR #$pr_number"
    return 2
}

get_ci_failure_logs() {
    local pr_number="$1"
    
    # Get failed check details
    local checks_json=$($GH pr checks "$pr_number" --json name,state,conclusion,detailsUrl 2>/dev/null || echo "[]")
    
    local failed_checks=$(echo "$checks_json" | jq -r '.[] | select(.conclusion == "FAILURE") | "\(.name): \(.detailsUrl)"')
    
    echo "$failed_checks"
}

# ============================================================================
# LOCK FILE MANAGEMENT
# ============================================================================

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            log_error "Another instance is running (PID: $pid)"
            exit 1
        else
            log_warn "Stale lock file found, removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    log_debug "Lock acquired (PID: $$)"
}

release_lock() {
    rm -f "$LOCK_FILE"
    log_debug "Lock released"
}

# ============================================================================
# CORE FUNCTIONS
# ============================================================================

check_stop() {
    if [[ -f "$STOP_FILE" ]]; then
        log_warn "STOP file detected. Halting autonomous workflow."
        rm -f "$STOP_FILE"
        discord_notify "⏹️ Workflow Stopped" "Stop file detected, halting gracefully" "$DISCORD_COLOR_WARNING"
        release_lock
        exit 0
    fi
}

cleanup() {
    log_info "Cleanup triggered. Finishing current iteration..."
    touch "$STOP_FILE"
}

trap cleanup SIGINT SIGTERM
trap release_lock EXIT

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    REVIEW_WAIT=$(jq -r '.review_wait_minutes // 5' "$CONFIG_FILE")
    MAX_ITERATIONS=$(jq -r '.max_iterations // 10' "$CONFIG_FILE")
    STOP_ON_NO_ISSUES=$(jq -r '.stop_on_no_issues // true' "$CONFIG_FILE")
    AUTO_MERGE=$(jq -r '.auto_merge // false' "$CONFIG_FILE")
    REQUIRE_APPROVAL=$(jq -r '.require_approval // true' "$CONFIG_FILE")
    MAIN_BRANCH=$(jq -r '.main_branch // "main"' "$CONFIG_FILE")
    DISCORD_WEBHOOK_URL=$(jq -r '.discord_webhook_url // empty' "$CONFIG_FILE")
    DEBUG=$(jq -r '.debug // false' "$CONFIG_FILE")
    
    # CI settings
    CI_WAIT_MINUTES=$(jq -r '.ci_wait_minutes // 30' "$CONFIG_FILE")
    CI_CHECK_INTERVAL=$(jq -r '.ci_check_interval_seconds // 30' "$CONFIG_FILE")
    CI_REQUIRED=$(jq -r '.ci_required // true' "$CONFIG_FILE")
    CI_RETRY_ON_FAILURE=$(jq -r '.ci_retry_on_failure // false' "$CONFIG_FILE")
    CI_MAX_RETRIES=$(jq -r '.ci_max_retries // 2' "$CONFIG_FILE")
    
    # Claude settings
    CLAUDE_TIMEOUT=$(jq -r '.claude_timeout_minutes // 30' "$CONFIG_FILE")
    
    # Labels to filter
    LABELS=$(jq -r '.labels_to_process // [] | join(",")' "$CONFIG_FILE")
    EXCLUDE=$(jq -r '.exclude_labels // [] | join(",")' "$CONFIG_FILE")
}

fetch_next_issue() {
    log_info "Fetching next open issue..."
    
    # Build label search - handle multiple labels correctly
    local label_search=""
    if [[ -n "$LABELS" ]]; then
        for label in $(echo "$LABELS" | tr ',' ' '); do
            label_search="$label_search label:\"$label\""
        done
    fi
    
    local issue_json=$($GH issue list --state open --limit 1 --search "sort:created-asc $label_search" --json number,title,body,labels,url 2>/dev/null || echo "[]")
    
    if [[ "$issue_json" == "[]" || -z "$issue_json" ]]; then
        echo ""
        return
    fi
    
    local issue_num=$(echo "$issue_json" | jq -r '.[0].number // empty')
    
    if [[ -z "$issue_num" ]]; then
        echo ""
        return
    fi
    
    # Check exclude labels
    if [[ -n "$EXCLUDE" ]]; then
        local issue_labels=$(echo "$issue_json" | jq -r '.[0].labels[].name' | tr '\n' ',' | sed 's/,$//')
        for excl in $(echo "$EXCLUDE" | tr ',' ' '); do
            if [[ "$issue_labels" == *"$excl"* ]]; then
                log_info "Issue #$issue_num has excluded label: $excl, skipping..."
                echo ""
                return
            fi
        done
    fi
    
    echo "$issue_num"
}

get_issue_details() {
    local issue_num=$1
    $GH issue view "$issue_num" --json number,title,body,labels,url
}

get_repo_url() {
    $GH repo view --json url --jq '.url' 2>/dev/null || echo ""
}

create_branch() {
    local issue_num=$1
    local branch_name="issue-${issue_num}"
    
    log_info "Creating branch: $branch_name"
    
    cd "$PROJECT_DIR"
    git fetch origin "$MAIN_BRANCH" >&2
    git checkout "$MAIN_BRANCH" >&2
    git pull origin "$MAIN_BRANCH" >&2
    
    # Check if branch exists locally
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
        git branch -D "$branch_name" >&2
    fi
    
    # Check if branch exists remotely
    if git ls-remote --heads origin "$branch_name" | grep -q "$branch_name"; then
        log_warn "Remote branch $branch_name exists, deleting..."
        git push origin --delete "$branch_name" >&2 || true
    fi
    
    git checkout -b "$branch_name" >&2
    echo "$branch_name"
}

run_claude_on_issue() {
    local issue_num=$1
    local issue_json=$2
    
    local title=$(echo "$issue_json" | jq -r '.title')
    local body=$(echo "$issue_json" | jq -r '.body')
    
    log_info "Running Claude Code on issue #$issue_num: $title"
    
    cd "$PROJECT_DIR"
    
    # Build the prompt for Claude
    local prompt="You are working on issue #$issue_num.

ISSUE TITLE: $title

ISSUE BODY:
$body

INSTRUCTIONS:
1. First, read CLAUDE.md to understand project context and conventions
2. Analyze the issue requirements and success criteria
3. Implement the solution following the project's coding standards
4. Run any tests if they exist
5. Commit your changes with a meaningful commit message referencing #$issue_num
6. When done, output TASK_COMPLETE

Do not ask for clarification - make reasonable assumptions based on the codebase."
    
    # Run Claude with timeout
    local timeout_seconds=$((CLAUDE_TIMEOUT * 60))
    
    if timeout "$timeout_seconds" claude --dangerously-skip-permissions -p "$prompt" --output-format text 2>&1 | tee -a "$LOG_FILE"; then
        # Verify Claude actually made commits
        local commits_made=$(git log "$MAIN_BRANCH"..HEAD --oneline 2>/dev/null | wc -l)
        if [[ "$commits_made" -eq 0 ]]; then
            log_error "Claude completed but made no commits"
            return 1
        fi
        log_success "Claude made $commits_made commit(s)"
        return 0
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_error "Claude timed out after ${CLAUDE_TIMEOUT} minutes"
        else
            log_error "Claude failed with exit code $exit_code"
        fi
        return 1
    fi
}

create_pr() {
    local issue_num=$1
    local branch_name=$2
    local issue_json=$3
    
    local title=$(echo "$issue_json" | jq -r '.title')
    
    log_info "Creating PR for issue #$issue_num"
    
    cd "$PROJECT_DIR"
    
    # Push branch
    git push -u origin "$branch_name" --force
    
    # Create PR
    local pr_url=$($GH pr create \
        --title "Fix #$issue_num: $title" \
        --body "This PR addresses issue #$issue_num.

## Changes
Automated implementation by Claude Code.

## Checklist
- [ ] CI checks pass
- [ ] Code review complete

Closes #$issue_num" \
        --base "$MAIN_BRANCH" \
        --head "$branch_name" 2>&1)
    
    echo "$pr_url"
}

wait_for_review() {
    local minutes=$1
    log_info "Waiting $minutes minutes for PR review..."
    sleep $((minutes * 60))
}

get_pr_comments() {
    local pr_number=$1
    $GH pr view "$pr_number" --json comments,reviews --jq '.comments[].body, .reviews[].body' 2>/dev/null || echo ""
}

process_pr_comments() {
    local pr_number=$1
    local branch_name=$2
    
    log_info "Checking PR #$pr_number for review comments..."
    
    local comments=$(get_pr_comments "$pr_number")
    
    if [[ -z "$comments" ]]; then
        log_info "No review comments found"
        return 0
    fi
    
    log_info "Found review comments, running Claude to process..."
    
    cd "$PROJECT_DIR"
    git checkout "$branch_name"
    git pull origin "$branch_name" 2>/dev/null || true
    
    local prompt="You are processing PR review comments for PR #$pr_number.

REVIEW COMMENTS:
$comments

INSTRUCTIONS:
1. Read CLAUDE.md first
2. Analyze each comment - determine if it's:
   - Valid feedback that should be addressed
   - A question (answer in code comments if appropriate)
   - Invalid/incorrect feedback (ignore but note why)
3. Make necessary code changes for valid feedback
4. Update CLAUDE.md if you learned something new about the project conventions
5. Commit changes with message 'address PR review comments for #$pr_number'
6. Output REVIEW_COMPLETE when done"
    
    local timeout_seconds=$((CLAUDE_TIMEOUT * 60))
    timeout "$timeout_seconds" claude --dangerously-skip-permissions -p "$prompt" --output-format text 2>&1 | tee -a "$LOG_FILE"
    
    # Push any changes
    git push origin "$branch_name" 2>/dev/null || true
    
    return 0
}

attempt_ci_fix() {
    local pr_number=$1
    local branch_name=$2
    local attempt=$3
    
    log_info "Attempting CI fix (attempt $attempt of $CI_MAX_RETRIES)..."
    
    local failure_logs=$(get_ci_failure_logs "$pr_number")
    
    cd "$PROJECT_DIR"
    git checkout "$branch_name"
    git pull origin "$branch_name" 2>/dev/null || true
    
    local prompt="CI checks have failed for PR #$pr_number. Please fix the issues.

FAILED CHECKS:
$failure_logs

INSTRUCTIONS:
1. Analyze the CI failure logs/URLs above
2. Identify the root cause of each failure
3. Fix the issues in the code
4. Run tests locally if possible to verify the fix
5. Commit with message 'fix CI failures for PR #$pr_number (attempt $attempt)'
6. Output CI_FIX_COMPLETE when done"
    
    local timeout_seconds=$((CLAUDE_TIMEOUT * 60))
    timeout "$timeout_seconds" claude --dangerously-skip-permissions -p "$prompt" --output-format text 2>&1 | tee -a "$LOG_FILE"
    
    git push origin "$branch_name"
    
    return 0
}

merge_pr() {
    local pr_number=$1
    
    if [[ "$REQUIRE_APPROVAL" == "true" ]]; then
        # Check if PR has approval
        local approved=$($GH pr view "$pr_number" --json reviewDecision --jq '.reviewDecision' 2>/dev/null)
        if [[ "$approved" != "APPROVED" ]]; then
            log_warn "PR #$pr_number not approved yet, skipping merge"
            return 1
        fi
    fi
    
    if [[ "$AUTO_MERGE" == "true" ]]; then
        log_info "Merging PR #$pr_number..."
        $GH pr merge "$pr_number" --squash --delete-branch
        return $?
    else
        log_info "Auto-merge disabled. PR #$pr_number ready for manual merge."
        return 0
    fi
}

save_state() {
    local iteration=$1
    local issue_num=$2
    local status=$3
    
    cat > "$STATE_FILE" << EOF
{
  "last_iteration": $iteration,
  "last_issue": $issue_num,
  "last_status": "$status",
  "timestamp": "$(date -Iseconds)"
}
EOF
}

# ============================================================================
# MAIN LOOP
# ============================================================================

main() {
    acquire_lock
    
    log_info "=========================================="
    log_info "Starting Autonomous Claude Code Workflow"
    log_info "Project: $PROJECT_DIR"
    log_info "=========================================="
    
    load_config
    
    log_info "Config loaded:"
    log_info "  Max iterations: $MAX_ITERATIONS"
    log_info "  Review wait: $REVIEW_WAIT minutes"
    log_info "  Auto merge: $AUTO_MERGE"
    log_info "  CI required: $CI_REQUIRED"
    log_info "  CI wait: $CI_WAIT_MINUTES minutes"
    log_info "  Stop on no issues: $STOP_ON_NO_ISSUES"
    log_info "  Discord notifications: $([ -n "$DISCORD_WEBHOOK_URL" ] && echo "enabled" || echo "disabled")"
    
    # Remove any stale stop file
    rm -f "$STOP_FILE"
    
    discord_workflow_start "$MAX_ITERATIONS"
    
    local completed_count=0
    local failed_count=0
    local repo_url=$(get_repo_url)
    
    for ((i=1; i<=MAX_ITERATIONS; i++)); do
        log_info "=========================================="
        log_info "ITERATION $i of $MAX_ITERATIONS"
        log_info "=========================================="
        
        check_stop
        
        # Step 1: Fetch issue
        local issue_num=$(fetch_next_issue)
        
        if [[ -z "$issue_num" ]]; then
            if [[ "$STOP_ON_NO_ISSUES" == "true" ]]; then
                log_success "No more issues to process. Stopping."
                break
            else
                log_info "No issues found. Waiting 5 minutes before retry..."
                sleep 300
                continue
            fi
        fi
        
        log_info "Processing issue #$issue_num"
        local issue_json=$(get_issue_details "$issue_num")
        local issue_title=$(echo "$issue_json" | jq -r '.title')
        local issue_url=$(echo "$issue_json" | jq -r '.url')
        
        discord_issue_start "$issue_num" "$issue_title" "$issue_url"
        
        # Step 2: Create branch
        local branch_name=$(create_branch "$issue_num")
        
        check_stop
        
        # Step 3: Run Claude to complete work
        if ! run_claude_on_issue "$issue_num" "$issue_json"; then
            log_error "Claude failed on issue #$issue_num"
            discord_error "Claude Implementation Failed" "Failed to implement solution for issue" "$issue_num"
            save_state "$i" "$issue_num" "claude_failed"
            ((failed_count++))
            continue
        fi
        
        check_stop
        
        # Step 4: Create PR
        local pr_output=$(create_pr "$issue_num" "$branch_name" "$issue_json")
        local pr_number=$(echo "$pr_output" | grep -oE '[0-9]+$' || echo "")
        
        if [[ -z "$pr_number" ]]; then
            # Try to get PR number from branch
            pr_number=$($GH pr list --head "$branch_name" --json number --jq '.[0].number' 2>/dev/null || echo "")
        fi
        
        if [[ -z "$pr_number" ]]; then
            log_error "Failed to create/find PR for issue #$issue_num"
            discord_error "PR Creation Failed" "Could not create pull request" "$issue_num"
            save_state "$i" "$issue_num" "pr_failed"
            ((failed_count++))
            continue
        fi
        
        local pr_url="${repo_url}/pull/${pr_number}"
        log_success "Created PR #$pr_number"
        discord_pr_created "$pr_number" "$issue_num" "$pr_url"
        
        check_stop
        
        # Step 5: Wait for CI and handle failures
        if [[ "$CI_REQUIRED" == "true" ]]; then
            local ci_attempts=0
            local ci_passed=false
            
            while [[ $ci_attempts -lt $((CI_MAX_RETRIES + 1)) ]]; do
                if wait_for_ci "$pr_number" "$CI_WAIT_MINUTES" "$CI_CHECK_INTERVAL"; then
                    ci_passed=true
                    discord_ci_status "$pr_number" "passed" "$pr_url"
                    break
                else
                    local ci_status=$(get_pr_check_status "$pr_number")
                    discord_ci_status "$pr_number" "$ci_status" "$pr_url"
                    
                    if [[ "$CI_RETRY_ON_FAILURE" == "true" && $ci_attempts -lt $CI_MAX_RETRIES ]]; then
                        ((ci_attempts++))
                        attempt_ci_fix "$pr_number" "$branch_name" "$ci_attempts"
                        log_info "Waiting for CI after fix attempt..."
                    else
                        break
                    fi
                fi
            done
            
            if [[ "$ci_passed" != "true" ]]; then
                log_error "CI failed for PR #$pr_number after $ci_attempts retry attempts"
                discord_error "CI Failed" "CI checks did not pass after $ci_attempts retries" "$issue_num"
                save_state "$i" "$issue_num" "ci_failed"
                ((failed_count++))
                
                # Still continue to review wait in case human wants to fix
                if [[ "$REQUIRE_APPROVAL" == "true" ]]; then
                    log_info "Proceeding to review wait despite CI failure..."
                else
                    continue
                fi
            fi
        fi
        
        check_stop
        
        # Step 6: Wait for review
        wait_for_review "$REVIEW_WAIT"
        
        check_stop
        
        # Step 7: Process PR comments
        process_pr_comments "$pr_number" "$branch_name"
        
        # If comments were processed, wait for CI again
        local new_commits=$(git log "origin/$MAIN_BRANCH"..HEAD --oneline 2>/dev/null | wc -l)
        if [[ "$new_commits" -gt 0 && "$CI_REQUIRED" == "true" ]]; then
            log_info "New commits from review processing, waiting for CI..."
            git push origin "$branch_name"
            wait_for_ci "$pr_number" "$CI_WAIT_MINUTES" "$CI_CHECK_INTERVAL" || true
        fi
        
        check_stop
        
        # Step 8: Merge PR
        if merge_pr "$pr_number"; then
            log_success "Completed issue #$issue_num"
            discord_pr_merged "$pr_number" "$issue_num" "$pr_url"
            save_state "$i" "$issue_num" "completed"
            ((completed_count++))
        else
            log_warn "PR #$pr_number not merged (may need manual review)"
            save_state "$i" "$issue_num" "pending_merge"
        fi
        
        # Return to main branch for next iteration
        cd "$PROJECT_DIR"
        git checkout "$MAIN_BRANCH"
        git pull origin "$MAIN_BRANCH"
        
        log_info "Iteration $i complete. Starting next..."
    done
    
    log_success "=========================================="
    log_success "Autonomous workflow complete"
    log_success "Completed: $completed_count | Failed: $failed_count"
    log_success "=========================================="
    
    discord_workflow_end "$completed_count" "$failed_count"
}

# Run
main "$@"