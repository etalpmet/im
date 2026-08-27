#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=
CONFIG_FILE=
BASE_BRANCH=
REMOTE=
BRANCH_ALLOWED=
BRANCH_DEFAULT=
WORK_LABEL=
TEST_SCRIPT=
BRANCH_LABELS=()
ISSUE_CONTEXT_DIR=im-issue

usage() {
  cat <<'EOF'
Usage:
  ./im.sh              Choose an action
  ./im.sh b|branch [-me]
                       Create or checkout a branch for your or unassigned issue
  ./im.sh m|milestone  Choose an open milestone, then create or checkout an issue branch
  ./im.sh i "<name>" [-l <label>]... [-u <user> | -ua] [-d <description>]
                       Create an issue
  ./im.sh ii "<name>" [-l <label>]... [-d <description>]
                       Create an assigned issue and checkout its linked branch
  ./im.sh pr           Test the current branch and create a pull request
  ./im.sh pr --skip-tests
                       Create a pull request without running tests
  ./im.sh init         Create .imconfig and optionally set up GitHub labels
  ./im.sh help         Show this help
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  local install_name="$2"

  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$install_name is not installed. Install it and retry."
}

require_git() {
  require_command git Git
}

require_github() {
  local answer

  require_command gh "GitHub CLI (gh)"
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    return
  fi

  if [[ ! -t 0 ]]; then
    fail "GitHub CLI is not authenticated. Run: gh auth login --hostname github.com"
  fi

  printf 'GitHub CLI is not authenticated. Log in now? [Y/n] ' >&2
  if ! IFS= read -r answer; then
    fail "GitHub CLI authentication is required"
  fi
  case "$answer" in
    '' | y | Y | yes | YES | Yes)
      gh auth login --hostname github.com \
        || fail "GitHub CLI authentication failed"
      ;;
    *) fail "GitHub CLI authentication is required. Run: gh auth login --hostname github.com" ;;
  esac

  gh auth status --hostname github.com >/dev/null 2>&1 \
    || fail "GitHub CLI authentication could not be verified"
}

trim_value() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

find_repository() {
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || fail "current directory is not inside a Git repository"
  CONFIG_FILE="$REPO_ROOT/.imconfig"
}

configured_branch_label() {
  local candidate
  local normalized
  local allowed

  candidate="$1"
  normalized="$(printf '%s' "$candidate" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  for allowed in "${BRANCH_LABELS[@]}"; do
    if [[ "$normalized" == "$allowed" ]]; then
      printf '%s\n' "$allowed"
      return
    fi
  done
  return 1
}

validate_config() {
  local raw_label label existing_label
  local default_found=false
  local configured_labels=()

  [[ -n "$BASE_BRANCH" ]] || fail "invalid $CONFIG_FILE: base_branch is required"
  [[ -n "$REMOTE" ]] || fail "invalid $CONFIG_FILE: remote is required"
  [[ -n "$BRANCH_ALLOWED" ]] || fail "invalid $CONFIG_FILE: branch_allowed is required"
  [[ -n "$BRANCH_DEFAULT" ]] || fail "invalid $CONFIG_FILE: branch_default is required"
  [[ -n "$WORK_LABEL" ]] || fail "invalid $CONFIG_FILE: work_label is required"
  [[ -n "$TEST_SCRIPT" ]] || fail "invalid $CONFIG_FILE: test_script is required"

  git check-ref-format --branch "$BASE_BRANCH" >/dev/null 2>&1 \
    || fail "invalid $CONFIG_FILE: invalid base_branch: $BASE_BRANCH"
  git remote get-url "$REMOTE" >/dev/null 2>&1 \
    || fail "invalid $CONFIG_FILE: Git remote not found: $REMOTE"

  IFS=',' read -r -a configured_labels <<<"$BRANCH_ALLOWED"
  BRANCH_LABELS=()
  for raw_label in "${configured_labels[@]}"; do
    label="$(trim_value "$raw_label")"
    [[ -n "$label" ]] \
      || fail "invalid $CONFIG_FILE: branch_allowed contains an empty label"
    [[ "$label" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
      || fail "invalid $CONFIG_FILE: branch label must match [a-z0-9][a-z0-9._-]*: $label"
    if [[ "${#BRANCH_LABELS[@]}" -gt 0 ]]; then
      for existing_label in "${BRANCH_LABELS[@]}"; do
        [[ "$existing_label" != "$label" ]] \
          || fail "invalid $CONFIG_FILE: duplicate branch label: $label"
      done
    fi
    BRANCH_LABELS+=("$label")
  done

  for label in "${BRANCH_LABELS[@]}"; do
    if [[ "$label" == "$BRANCH_DEFAULT" ]]; then
      default_found=true
      break
    fi
  done
  [[ "$default_found" == true ]] \
    || fail "invalid $CONFIG_FILE: branch_default must be listed in branch_allowed"

  [[ "$TEST_SCRIPT" != /* ]] \
    || fail "invalid $CONFIG_FILE: test_script must be relative to the repository root"
  case "/$TEST_SCRIPT/" in
    */../*) fail "invalid $CONFIG_FILE: test_script cannot leave the repository root" ;;
  esac
}

load_config() {
  local line line_number=0 key value
  local seen_keys=' '

  [[ -f "$CONFIG_FILE" ]] \
    || fail ".imconfig was not found in the repository root. Run: im.sh init"

  BASE_BRANCH=
  REMOTE=
  BRANCH_ALLOWED=
  BRANCH_DEFAULT=
  WORK_LABEL=
  TEST_SCRIPT=

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] \
      || fail "invalid $CONFIG_FILE:$line_number: expected key=value"

    key="$(trim_value "${line%%=*}")"
    value="$(trim_value "${line#*=}")"
    case "$key" in
      base_branch | remote | branch_allowed | branch_default | work_label | test_script) ;;
      *) fail "invalid $CONFIG_FILE:$line_number: unknown key: $key" ;;
    esac
    [[ "$seen_keys" != *" $key "* ]] \
      || fail "invalid $CONFIG_FILE:$line_number: duplicate key: $key"
    seen_keys+="$key "

    case "$key" in
      base_branch) BASE_BRANCH="$value" ;;
      remote) REMOTE="$value" ;;
      branch_allowed) BRANCH_ALLOWED="$value" ;;
      branch_default) BRANCH_DEFAULT="$value" ;;
      work_label) WORK_LABEL="$value" ;;
      test_script) TEST_SCRIPT="$value" ;;
    esac
  done <"$CONFIG_FILE"

  validate_config
}

prepare_project() {
  require_git
  find_repository
  load_config
  require_github
}

require_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    fail "working tree is not clean; commit or stash changes first"
  fi
}

slugify() {
  local slug
  slug="$(
    printf '%s' "$1" \
      | LC_ALL=C tr '[:upper:]' '[:lower:]' \
      | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
      | cut -c1-50 \
      | sed -E 's/-+$//'
  )"
  [[ -n "$slug" ]] || slug=issue
  printf '%s\n' "$slug"
}

choose_branch_issue() {
  local only_me="$1"
  local milestone_number="${2:-}"
  local rows assigned_rows unassigned_rows number title labels milestone assignment selection index
  local red=$'\033[31m'
  local green=$'\033[32m'
  local yellow=$'\033[33m'
  local blue=$'\033[34m'
  local reset=$'\033[0m'
  local numbers=()
  local titles=()
  local labels_list=()
  local milestones=()
  local assignments=()

  if [[ ! -t 2 || -n "${NO_COLOR:-}" ]]; then
    red=
    green=
    yellow=
    blue=
    reset=
  fi

  if [[ -n "$milestone_number" ]]; then
    rows="$(
      gh api --paginate \
        "repos/{owner}/{repo}/issues?state=open&milestone=$milestone_number&per_page=100" \
        --jq '.[] | select(.pull_request == null) | [.number, .title, ([.labels[].name] | join(",")), (.milestone.title // ""), ([.assignees[].login] | map("@" + .) | join(","))] | join("\u001f")'
    )"
  else
    assigned_rows="$(
      gh issue list \
        --state open \
        --assignee @me \
        --limit 100 \
        --json number,title,labels,milestone,assignees \
        --jq '.[] | [.number, .title, ([.labels[].name] | join(",")), (.milestone.title // ""), ([.assignees[].login] | map("@" + .) | join(","))] | join("\u001f")'
    )"

    rows="$assigned_rows"
    if [[ "$only_me" == false ]]; then
      unassigned_rows="$(
        gh issue list \
          --state open \
          --search 'no:assignee' \
          --limit 100 \
          --json number,title,labels,milestone \
          --jq '.[] | [.number, .title, ([.labels[].name] | join(",")), (.milestone.title // ""), ""] | join("\u001f")'
      )"
      if [[ -n "$rows" && -n "$unassigned_rows" ]]; then
        rows+=$'\n'
      fi
      rows+="$unassigned_rows"
    fi
  fi

  if [[ -n "$milestone_number" ]]; then
    [[ -n "$rows" ]] || fail "no open issues in milestone #$milestone_number"
  elif [[ "$only_me" == true ]]; then
    [[ -n "$rows" ]] || fail "no open issues assigned to you"
  else
    [[ -n "$rows" ]] || fail "no open issues assigned to you or unassigned"
  fi

  while IFS=$'\x1f' read -r number title labels milestone assignment; do
    [[ -n "$number" ]] || continue
    numbers+=("$number")
    titles+=("$title")
    labels_list+=("$labels")
    milestones+=("$milestone")
    assignments+=("$assignment")
  done <<<"$rows"

  while true; do
    if [[ -n "$milestone_number" ]]; then
      echo "Open issues in milestone #$milestone_number:" >&2
    elif [[ "$only_me" == true ]]; then
      echo "Open issues assigned to you:" >&2
    else
      echo "Open issues assigned to you or unassigned:" >&2
    fi
    for ((index = 0; index < ${#numbers[@]}; index++)); do
      printf '%s#%s%s' "$red" "${numbers[$index]}" "$reset" >&2
      if [[ -n "${labels_list[$index]}" ]]; then
        printf '  %s%s%s' "$green" "${labels_list[$index]}" "$reset" >&2
      fi
      printf '  %s' "${titles[$index]}" >&2
      if [[ -n "${assignments[$index]}" ]]; then
        printf '  %s[%s]%s' "$yellow" "${assignments[$index]}" "$reset" >&2
      fi
      if [[ -n "${milestones[$index]}" ]]; then
        printf '  %s[%s]%s' "$blue" "${milestones[$index]}" "$reset" >&2
      fi
      printf '\n' >&2
    done
    printf 'Select issue by GitHub number: ' >&2

    if ! IFS= read -r selection; then
      return 1
    fi
    selection="${selection#\#}"
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
      for number in "${numbers[@]}"; do
        if [[ "$selection" == "$number" ]]; then
          printf '%s\n' "$number"
          return
        fi
      done
    fi
    echo "Invalid selection." >&2
    echo >&2
  done
}

choose_milestone() {
  local rows number title selection index
  local numbers=()
  local titles=()

  rows="$(
    gh api --paginate 'repos/{owner}/{repo}/milestones?state=open&per_page=100' \
      --jq '.[] | [.number, .title] | join("\u001f")'
  )"
  [[ -n "$rows" ]] || fail "no open milestones"

  while IFS=$'\x1f' read -r number title; do
    [[ -n "$number" ]] || continue
    numbers+=("$number")
    titles+=("$title")
  done <<<"$rows"

  while true; do
    echo "Open milestones:" >&2
    for ((index = 0; index < ${#numbers[@]}; index++)); do
      printf '#%s  %s\n' "${numbers[$index]}" "${titles[$index]}" >&2
    done
    printf 'Select milestone by GitHub number: ' >&2

    if ! IFS= read -r selection; then
      return 1
    fi
    selection="${selection#\#}"
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
      for number in "${numbers[@]}"; do
        if [[ "$selection" == "$number" ]]; then
          printf '%s\n' "$number"
          return
        fi
      done
    fi
    echo "Invalid selection." >&2
    echo >&2
  done
}

choose_linked_branch() {
  local rows="$1"
  local branch _url choice
  local branches=()

  while IFS=$'\t' read -r branch _url; do
    [[ -n "$branch" ]] || continue
    branches+=("$branch")
  done <<<"$rows"

  if [[ "${#branches[@]}" -eq 1 ]]; then
    printf '%s\n' "${branches[0]}"
    return
  fi

  echo "Issue has multiple linked branches:" >&2
  PS3="Select branch: "
  select choice in "${branches[@]}"; do
    if [[ "$REPLY" =~ ^[0-9]+$ ]]; then
      if [[ "$REPLY" -ge 1 && "$REPLY" -le "${#branches[@]}" ]]; then
        printf '%s\n' "$choice"
        return
      fi
    fi
    echo "Invalid selection." >&2
  done
  return 1
}

checkout_linked_branch() {
  local branch="$1"

  git fetch "$REMOTE" "$branch"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git switch "$branch"
  else
    git switch --create "$branch" --track "$REMOTE/$branch"
  fi
}

pull_base_branch() {
  local branch_name="$1"
  local current_branch pull_exit

  current_branch="$(git branch --show-current)"
  [[ "$current_branch" == "$branch_name" ]] \
    || fail "expected checked out branch $branch_name, got ${current_branch:-detached HEAD}"

  echo "Pulling latest $REMOTE/$BASE_BRANCH into $branch_name..."
  if git pull --ff-only "$REMOTE" "$BASE_BRANCH"; then
    echo "Branch is up to date with $REMOTE/$BASE_BRANCH."
  else
    pull_exit=$?
    echo "Could not fast-forward $branch_name from $REMOTE/$BASE_BRANCH." >&2
    echo "Resolve the branch state, then retry: git pull --ff-only $REMOTE $BASE_BRANCH" >&2
    return "$pull_exit"
  fi
}

branch_label_for_issue() {
  local issue_number="$1"
  local issue_labels label configured_label
  local matches=()

  issue_labels="$(gh issue view "$issue_number" --json labels --jq '.labels[].name')"
  while IFS= read -r label; do
    [[ -n "$label" ]] || continue
    if configured_label="$(configured_branch_label "$label")"; then
      matches+=("$configured_label")
    fi
  done <<<"$issue_labels"

  case "${#matches[@]}" in
    0) printf '%s\n' "$BRANCH_DEFAULT" ;;
    1) printf '%s\n' "${matches[0]}" ;;
    *) fail "issue #$issue_number has multiple branch labels: ${matches[*]}" ;;
  esac
}

issue_context_filename() {
  local issue_number="$1"
  local issue_title="$2"
  local safe_title

  safe_title="$(
    printf '%s' "$issue_title" \
      | tr '\r\n\t' '   ' \
      | sed -E 's#[/\\:*?"<>|]+#-#g; s/[[:space:]]+/ /g; s/^ +//; s/[ .]+$//' \
      | cut -c1-120 \
      | sed -E 's/[ .]+$//'
  )"
  [[ -n "$safe_title" ]] || safe_title=issue
  printf '%s-%s.md\n' "$issue_number" "$safe_title"
}

write_issue_context() {
  local requested_issue_number="$1"
  local branch_name="$2"
  local issue_details issue_number issue_title issue_state issue_url issue_updated
  local issue_assignees issue_labels issue_milestone issue_body context_file

  require_issue_context_ignored
  issue_details="$(
    gh issue view "$requested_issue_number" \
      --json number,title,state,url,updatedAt,assignees,labels,milestone,body \
      --jq '[(.number | tostring), .title, .state, .url, .updatedAt, ([.assignees[].login | "@" + .] | join(", ")), ([.labels[].name] | join(", ")), (.milestone.title // ""), (.body // "")] | join("\u001f")'
  )"

  issue_number="${issue_details%%$'\x1f'*}"
  issue_details="${issue_details#*$'\x1f'}"
  issue_title="${issue_details%%$'\x1f'*}"
  issue_details="${issue_details#*$'\x1f'}"
  issue_state="${issue_details%%$'\x1f'*}"
  issue_details="${issue_details#*$'\x1f'}"
  issue_url="${issue_details%%$'\x1f'*}"
  issue_details="${issue_details#*$'\x1f'}"
  issue_updated="${issue_details%%$'\x1f'*}"
  issue_details="${issue_details#*$'\x1f'}"
  issue_assignees="${issue_details%%$'\x1f'*}"
  issue_details="${issue_details#*$'\x1f'}"
  issue_labels="${issue_details%%$'\x1f'*}"
  issue_details="${issue_details#*$'\x1f'}"
  issue_milestone="${issue_details%%$'\x1f'*}"
  issue_body="${issue_details#*$'\x1f'}"

  [[ "$issue_number" == "$requested_issue_number" ]] \
    || fail "GitHub returned issue #$issue_number while #$requested_issue_number was requested"
  context_file="$REPO_ROOT/$ISSUE_CONTEXT_DIR/$(
    issue_context_filename "$issue_number" "$issue_title"
  )"
  mkdir -p "$REPO_ROOT/$ISSUE_CONTEXT_DIR" \
    || fail "could not create issue context directory: $REPO_ROOT/$ISSUE_CONTEXT_DIR"

  if ! {
    printf '# #%s %s\n\n' "$issue_number" "$issue_title"
    printf -- '- State: %s\n' "$issue_state"
    printf -- '- URL: %s\n' "$issue_url"
    printf -- '- Branch: %s\n' "$branch_name"
    printf -- '- Assignees: %s\n' "${issue_assignees:-unassigned}"
    printf -- '- Labels: %s\n' "${issue_labels:-none}"
    printf -- '- Milestone: %s\n' "${issue_milestone:-none}"
    printf -- '- Updated: %s\n' "$issue_updated"
    printf '\n## Description\n\n'
    if [[ -n "$issue_body" ]]; then
      printf '%s\n' "$issue_body"
    else
      printf '_No description provided._\n'
    fi
  } >"$context_file"; then
    fail "could not write issue context: $context_file"
  fi

  echo "Issue context:"
  echo "  Issue:     #$issue_number $issue_title"
  echo "  State:     $issue_state"
  echo "  Assignees: ${issue_assignees:-unassigned}"
  echo "  Labels:    ${issue_labels:-none}"
  echo "  Milestone: ${issue_milestone:-none}"
  echo "  Context:   $context_file"
}

new_branch() {
  local only_me="${1:-false}"
  local by_milestone="${2:-false}"
  local milestone_number='' issue_number linked_rows linked_branch issue_label issue_title branch_name

  require_clean_worktree
  require_issue_context_ignored
  if [[ "$by_milestone" == true ]]; then
    if ! milestone_number="$(choose_milestone)"; then
      return
    fi
  fi

  if ! issue_number="$(choose_branch_issue "$only_me" "$milestone_number")"; then
    return
  fi
  linked_rows="$(gh issue develop --list "$issue_number")"

  if [[ -n "$linked_rows" ]]; then
    if ! linked_branch="$(choose_linked_branch "$linked_rows")"; then
      return
    fi
    echo "Checking out linked branch: $linked_branch"
    checkout_linked_branch "$linked_branch"
    write_issue_context "$issue_number" "$linked_branch"
    return
  fi

  issue_label="$(branch_label_for_issue "$issue_number")"

  issue_title="$(gh issue view "$issue_number" --json title --jq '.title')"
  branch_name="$issue_label/$issue_number-$(slugify "$issue_title")"

  echo "Creating linked branch: $branch_name"
  gh issue develop "$issue_number" \
    --base "$BASE_BRANCH" \
    --name "$branch_name" \
    --checkout
  pull_base_branch "$branch_name"
  echo "Assigning issue #$issue_number to you and adding $WORK_LABEL label"
  gh issue edit "$issue_number" --add-assignee @me --add-label "$WORK_LABEL"
  write_issue_context "$issue_number" "$branch_name"
}

new_issue() {
  local checkout_branch="$1"
  shift

  local issue_title="${1:-}"
  local issue_type="$BRANCH_DEFAULT"
  local issue_assignee=@me
  local issue_description=
  local assignee_set=false
  local explicit_issue_type=
  local issue_url issue_number branch_name create_exit branch_exit current_branch
  local issue_label existing_label labels_display
  local issue_labels=()
  local unique_labels=()
  local issue_args=()

  [[ -n "$issue_title" ]] || fail "issue name is required"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l | --label)
        [[ $# -ge 2 ]] || fail "missing value for $1"
        [[ -n "$2" ]] || fail "issue label cannot be empty"
        if issue_label="$(configured_branch_label "$2")"; then
          if [[ -n "$explicit_issue_type" && "$explicit_issue_type" != "$issue_label" ]]; then
            fail "issue cannot have multiple branch labels: $explicit_issue_type, $issue_label"
          fi
          explicit_issue_type="$issue_label"
        fi
        issue_labels+=("$2")
        shift 2
        ;;
      -u | --user)
        [[ "$checkout_branch" == false ]] \
          || fail "-u is not supported by ii; the issue is always assigned to you"
        [[ $# -ge 2 ]] || fail "missing value for $1"
        [[ "$assignee_set" == false ]] || fail "-u and -ua cannot be used together"
        issue_assignee="$2"
        assignee_set=true
        shift 2
        ;;
      -ua | --unassigned)
        [[ "$checkout_branch" == false ]] \
          || fail "-ua is not supported by ii; the issue is always assigned to you"
        [[ "$assignee_set" == false ]] || fail "-u and -ua cannot be used together"
        issue_assignee=
        assignee_set=true
        shift
        ;;
      -d | --description)
        [[ $# -ge 2 ]] || fail "missing value for $1"
        issue_description="$2"
        shift 2
        ;;
      *) fail "unknown issue option: $1" ;;
    esac
  done

  if [[ -n "$explicit_issue_type" ]]; then
    issue_type="$explicit_issue_type"
  else
    issue_labels+=("$BRANCH_DEFAULT")
  fi

  for issue_label in "${issue_labels[@]}"; do
    if [[ "${#unique_labels[@]}" -gt 0 ]]; then
      for existing_label in "${unique_labels[@]}"; do
        [[ "$existing_label" != "$issue_label" ]] || continue 2
      done
    fi
    unique_labels+=("$issue_label")
  done
  issue_labels=("${unique_labels[@]}")

  case "$issue_assignee" in
    me | @me) issue_assignee=@me ;;
  esac

  if [[ "$checkout_branch" == true ]]; then
    require_clean_worktree
    require_issue_context_ignored
    current_branch="$(git branch --show-current)"
    [[ -n "$current_branch" ]] || fail "detached HEAD is not supported"
    echo "Current branch is clean: $current_branch"
  fi
  echo "Creating GitHub issue:"
  echo "  Title:    $issue_title"
  labels_display="$(IFS=', '; echo "${issue_labels[*]}")"
  echo "  Labels:   $labels_display"
  echo "  Assignee: ${issue_assignee:-unassigned}"
  if [[ -n "$issue_description" ]]; then
    echo "  Description: $issue_description"
  fi

  issue_args=(--title "$issue_title" --body "$issue_description")
  for issue_label in "${issue_labels[@]}"; do
    issue_args+=(--label "$issue_label")
  done
  if [[ -n "$issue_assignee" ]]; then
    issue_args+=(--assignee "$issue_assignee")
  fi

  if issue_url="$(gh issue create "${issue_args[@]}")"; then
    echo "Issue created: $issue_url"
  else
    create_exit=$?
    echo "Issue creation failed with exit code $create_exit." >&2
    return "$create_exit"
  fi

  if [[ "$checkout_branch" == false ]]; then
    return
  fi

  issue_number="${issue_url##*/}"
  [[ "$issue_number" =~ ^[0-9]+$ ]] \
    || fail "cannot determine issue number from URL: $issue_url"
  branch_name="$issue_type/$issue_number-$(slugify "$issue_title")"

  echo
  echo "Creating linked branch from $BASE_BRANCH: $branch_name"
  if gh issue develop "$issue_number" \
    --base "$BASE_BRANCH" \
    --name "$branch_name" \
    --checkout; then
    echo "Linked branch checked out: $branch_name"
  else
    branch_exit=$?
    echo "Linked branch creation failed with exit code $branch_exit." >&2
    echo "Issue #$issue_number remains open: $issue_url" >&2
    echo "Fix the GitHub or Git error, then retry via: ./im.sh b" >&2
    return "$branch_exit"
  fi

  pull_base_branch "$branch_name"
  echo "Adding $WORK_LABEL label to issue #$issue_number"
  gh issue edit "$issue_number" --add-label "$WORK_LABEL"
  write_issue_context "$issue_number" "$branch_name"
}

issue_number_from_branch() {
  local branch="$1"
  local branch_label prefix remainder issue_number

  for branch_label in "${BRANCH_LABELS[@]}"; do
    prefix="$branch_label/"
    if [[ "$branch" == "$prefix"* ]]; then
      remainder="${branch#"$prefix"}"
      issue_number="${remainder%%-*}"
      if [[ "$remainder" == "$issue_number-"* && "$issue_number" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$issue_number"
        return
      fi
    fi
  done

  if [[ "$branch" =~ ^([0-9]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    fail "cannot determine issue number from branch: $branch"
  fi
}

require_linked_issue() {
  local issue_number="$1"
  local current_branch="$2"
  local rows branch _url

  rows="$(gh issue develop --list "$issue_number")"
  while IFS=$'\t' read -r branch _url; do
    if [[ "$branch" == "$current_branch" ]]; then
      return
    fi
  done <<<"$rows"

  fail "branch $current_branch is not linked to issue #$issue_number"
}

new_pr() {
  local skip_tests="${1:-false}"
  local current_branch issue_number issue_details issue_state issue_title existing_pr
  local test_exit push_exit pr_exit pr_url pr_body
  local test_runner="$REPO_ROOT/$TEST_SCRIPT"
  local test_runner_missing=false

  require_clean_worktree
  current_branch="$(git branch --show-current)"
  [[ -n "$current_branch" ]] || fail "detached HEAD is not supported"
  [[ "$current_branch" != "$BASE_BRANCH" ]] \
    || fail "cannot create a pull request from $BASE_BRANCH"

  issue_number="$(issue_number_from_branch "$current_branch")"
  require_linked_issue "$issue_number" "$current_branch"

  issue_details="$(
    gh issue view "$issue_number" \
      --json state,title \
      --jq '[.state, .title] | @tsv'
  )"
  IFS=$'\t' read -r issue_state issue_title <<<"$issue_details"
  [[ "$issue_state" == OPEN ]] || fail "issue #$issue_number is not open"

  echo "Preparing pull request:"
  echo "  Branch: $current_branch"
  echo "  Issue:  #$issue_number $issue_title"
  echo "  Base:   $BASE_BRANCH"

  existing_pr="$(
    gh pr list \
      --state open \
      --head "$current_branch" \
      --json url \
      --jq '.[0].url // ""'
  )"
  if [[ -n "$existing_pr" ]]; then
    echo "Pull request already exists: $existing_pr"
    return
  fi

  if [[ "$skip_tests" == true ]]; then
    echo
    echo "WARNING: Tests were skipped by request."
    # Backticks in these formats are Markdown delimiters, not shell substitutions.
    # shellcheck disable=SC2016
    pr_body="$(
      printf 'Closes #%s\n\n## Verification\n\n- Tests were skipped via `./im.sh pr --skip-tests`.\n' \
        "$issue_number"
    )"
  elif [[ ! -f "$test_runner" ]]; then
    test_runner_missing=true
    # shellcheck disable=SC2016
    pr_body="$(
      printf 'Closes #%s\n\n## Verification\n\n- Tests were not run because `%s` was not found.\n' \
        "$issue_number" "$TEST_SCRIPT"
    )"
  else
    echo
    echo "Running full integration flow..."
    if "$test_runner"; then
      echo
      echo "Tests passed."
      # shellcheck disable=SC2016
      pr_body="$(
        printf 'Closes #%s\n\n## Verification\n\n- `%s`\n' \
          "$issue_number" "$TEST_SCRIPT"
      )"
    else
      test_exit=$?
      echo >&2
      echo "Pull request was not created because tests failed with exit code $test_exit." >&2
      echo "Fix the failures, commit the changes, then retry: ./im.sh pr" >&2
      return "$test_exit"
    fi
  fi

  echo
  echo "Pushing branch to $REMOTE..."
  if git push --set-upstream "$REMOTE" "$current_branch"; then
    echo "Branch pushed."
  else
    push_exit=$?
    echo "Pull request was not created because git push failed with exit code $push_exit." >&2
    echo "Fix the push error, then retry: ./im.sh pr" >&2
    return "$push_exit"
  fi

  echo
  echo "Creating pull request..."
  if pr_url="$(
    gh pr create \
      --base "$BASE_BRANCH" \
      --head "$current_branch" \
      --title "$issue_title" \
      --body "$pr_body"
  )"; then
    echo "Pull request created: $pr_url"
    echo "Issue #$issue_number will close after the pull request is merged."
    if [[ "$test_runner_missing" == true ]]; then
      echo
      echo "NOTICE: Integration tests were not run."
      echo "Test runner was not found: $test_runner"
    fi
  else
    pr_exit=$?
    echo "Pull request creation failed with exit code $pr_exit." >&2
    echo "The branch is already pushed; fix the GitHub error, then retry: ./im.sh pr" >&2
    return "$pr_exit"
  fi
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local answer

  printf '%s [%s]: ' "$prompt" "$default_value" >&2
  if ! IFS= read -r answer; then
    return 1
  fi
  printf '%s\n' "${answer:-$default_value}"
}

confirm_default_yes() {
  local prompt="$1"
  local answer

  printf '%s [Y/n] ' "$prompt" >&2
  if ! IFS= read -r answer; then
    return 1
  fi
  case "$answer" in
    '' | y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
  esac
}

gitignore_has_issue_context() {
  local gitignore_file="$REPO_ROOT/.gitignore"
  local line

  [[ -f "$gitignore_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim_value "${line%$'\r'}")"
    case "$line" in
      "$ISSUE_CONTEXT_DIR/" | "/$ISSUE_CONTEXT_DIR/") return ;;
    esac
  done <"$gitignore_file"
  return 1
}

setup_issue_context_gitignore() {
  local gitignore_file="$REPO_ROOT/.gitignore"

  if gitignore_has_issue_context; then
    echo "$ISSUE_CONTEXT_DIR/ is already listed in $gitignore_file"
    return
  fi

  if ! confirm_default_yes "Add $ISSUE_CONTEXT_DIR/ to $gitignore_file?"; then
    echo "$ISSUE_CONTEXT_DIR/ was not added to .gitignore."
    return
  fi

  [[ ! -e "$gitignore_file" || -f "$gitignore_file" ]] \
    || fail "cannot update .gitignore because it is not a regular file: $gitignore_file"
  if [[ -s "$gitignore_file" && -n "$(tail -c 1 "$gitignore_file")" ]]; then
    printf '\n' >>"$gitignore_file"
  fi
  printf '%s/\n' "$ISSUE_CONTEXT_DIR" >>"$gitignore_file"
  echo "Added $ISSUE_CONTEXT_DIR/ to $gitignore_file"
}

require_issue_context_ignored() {
  gitignore_has_issue_context \
    || fail "$ISSUE_CONTEXT_DIR/ is not listed in $REPO_ROOT/.gitignore. Run: im.sh init"
}

github_label_exists() {
  local requested_label="$1"
  local existing_labels="$2"
  local requested_normalized existing_label existing_normalized

  requested_normalized="$(
    printf '%s' "$requested_label" | LC_ALL=C tr '[:upper:]' '[:lower:]'
  )"
  while IFS= read -r existing_label; do
    existing_normalized="$(
      printf '%s' "$existing_label" | LC_ALL=C tr '[:upper:]' '[:lower:]'
    )"
    if [[ "$existing_normalized" == "$requested_normalized" ]]; then
      return
    fi
  done <<<"$existing_labels"
  return 1
}

setup_github_labels() {
  local existing_labels label existing_setup_label
  local setup_labels=()

  if ! existing_labels="$(gh label list --limit 1000 --json name --jq '.[].name')"; then
    fail "could not read GitHub labels"
  fi

  for label in "${BRANCH_LABELS[@]}" "$WORK_LABEL"; do
    if [[ "${#setup_labels[@]}" -gt 0 ]]; then
      for existing_setup_label in "${setup_labels[@]}"; do
        if [[ "$existing_setup_label" == "$label" ]]; then
          continue 2
        fi
      done
    fi
    setup_labels+=("$label")
  done

  for label in "${setup_labels[@]}"; do
    if github_label_exists "$label" "$existing_labels"; then
      echo "GitHub label already exists: $label"
      continue
    fi
    if gh label create "$label" >/dev/null; then
      echo "GitHub label created: $label"
      existing_labels+=$'\n'"$label"
    else
      fail "GitHub label creation failed: $label"
    fi
  done
}

init_project() {
  local labels_display=
  local label
  local config_created=false

  require_git
  find_repository
  echo "Initializing im for: $REPO_ROOT"
  if [[ -e "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] \
      || fail ".imconfig is not a regular file: $CONFIG_FILE"
    load_config
    echo "Using existing .imconfig: $CONFIG_FILE"
  else
    config_created=true
  fi

  require_github

  if [[ "$config_created" == true ]]; then
    BASE_BRANCH="$(prompt_with_default "Base branch" main)" \
      || fail "initialization cancelled"
    REMOTE="$(prompt_with_default "Git remote" origin)" \
      || fail "initialization cancelled"
    BRANCH_ALLOWED="$(prompt_with_default "Allowed branch labels" bug,feature)" \
      || fail "initialization cancelled"
    BRANCH_DEFAULT="$(prompt_with_default "Default branch label" feature)" \
      || fail "initialization cancelled"
    WORK_LABEL="$(prompt_with_default "Work-in-progress label" TAKEN)" \
      || fail "initialization cancelled"
    TEST_SCRIPT="$(prompt_with_default "Integration test script" scripts/run-integration-tests.sh)" \
      || fail "initialization cancelled"

    validate_config

    {
      printf '# im project configuration\n'
      printf 'base_branch=%s\n' "$BASE_BRANCH"
      printf 'remote=%s\n' "$REMOTE"
      printf 'branch_allowed=%s\n' "$BRANCH_ALLOWED"
      printf 'branch_default=%s\n' "$BRANCH_DEFAULT"
      printf 'work_label=%s\n' "$WORK_LABEL"
      printf 'test_script=%s\n' "$TEST_SCRIPT"
    } >"$CONFIG_FILE"

    echo ".imconfig created: $CONFIG_FILE"
  fi

  if [[ ! -f "$REPO_ROOT/$TEST_SCRIPT" ]]; then
    echo "NOTICE: Test script was not found: $REPO_ROOT/$TEST_SCRIPT"
  fi

  setup_issue_context_gitignore

  for label in "${BRANCH_LABELS[@]}" "$WORK_LABEL"; do
    if [[ -n "$labels_display" ]]; then
      labels_display+=", "
    fi
    labels_display+="$label"
  done
  if confirm_default_yes "Create missing GitHub labels: $labels_display?"; then
    setup_github_labels
  else
    echo "GitHub label setup skipped."
  fi
  if [[ "$config_created" == true ]]; then
    echo "Commit .imconfig before using branch or pull request commands."
  fi
}

main_menu() {
  local choice

  PS3="Select action: "
  select choice in "Create or checkout issue branch" "Choose milestone issue branch" "Create pull request"; do
    case "$REPLY" in
      1) new_branch; return ;;
      2) new_branch false true; return ;;
      3) new_pr; return ;;
      *) echo "Invalid selection." >&2 ;;
    esac
  done
}

case "${1:-}" in
  '')
    [[ $# -eq 0 ]] || { usage >&2; exit 1; }
    prepare_project
    main_menu
    ;;
  b | branch)
    [[ $# -le 2 ]] || { usage >&2; exit 1; }
    prepare_project
    case "${2:-}" in
      '') new_branch ;;
      -me | --me) new_branch true ;;
      *) usage >&2; exit 1 ;;
    esac
    ;;
  m | milestone)
    [[ $# -eq 1 ]] || { usage >&2; exit 1; }
    prepare_project
    new_branch false true
    ;;
  i)
    shift
    prepare_project
    new_issue false "$@"
    ;;
  ii)
    shift
    prepare_project
    new_issue true "$@"
    ;;
  pr)
    [[ $# -le 2 ]] || { usage >&2; exit 1; }
    prepare_project
    case "${2:-}" in
      '') new_pr ;;
      --skip-tests) new_pr true ;;
      *) usage >&2; exit 1 ;;
    esac
    ;;
  init)
    [[ $# -eq 1 ]] || { usage >&2; exit 1; }
    init_project
    ;;
  -h | --help | help)
    [[ $# -eq 1 ]] || { usage >&2; exit 1; }
    usage
    ;;
  *) usage >&2; exit 1 ;;
esac
