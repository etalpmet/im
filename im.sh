#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  ./im.sh help         Show this help
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_github() {
  require_command gh
  gh auth status --hostname github.com >/dev/null 2>&1 \
    || fail "GitHub CLI is not authenticated. Run: gh auth login --hostname github.com"
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
  local row branch url choice
  local branches=()

  while IFS=$'\t' read -r branch url; do
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

  git fetch origin "$branch"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git switch "$branch"
  else
    git switch --create "$branch" --track "origin/$branch"
  fi
}

new_branch() {
  local only_me="${1:-false}"
  local by_milestone="${2:-false}"
  local milestone_number= issue_number linked_rows linked_branch issue_label issue_title branch_name

  require_clean_worktree
  require_github

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
    return
  fi

  issue_label="$(
    gh issue view "$issue_number" \
      --json labels \
      --jq '[.labels[].name | ascii_downcase | select(. == "bug" or . == "feature")] | unique | join(",")'
  )"
  case "$issue_label" in
    bug | feature) ;;
    '') issue_label=feature ;;
    *) fail "issue #$issue_number cannot have both bug and feature labels" ;;
  esac

  issue_title="$(gh issue view "$issue_number" --json title --jq '.title')"
  branch_name="$issue_label/$issue_number-$(slugify "$issue_title")"

  echo "Creating linked branch: $branch_name"
  gh issue develop "$issue_number" \
    --base main \
    --name "$branch_name" \
    --checkout
  echo "Assigning issue #$issue_number to you and adding TAKEN label"
  gh issue edit "$issue_number" --add-assignee @me --add-label TAKEN
}

new_issue() {
  local checkout_branch="$1"
  shift

  local issue_title="${1:-}"
  local issue_type=feature
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
        case "$2" in
          bug | feature)
            if [[ -n "$explicit_issue_type" && "$explicit_issue_type" != "$2" ]]; then
              fail "issue cannot have both bug and feature labels"
            fi
            explicit_issue_type="$2"
            ;;
        esac
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

  if [[ "${#issue_labels[@]}" -eq 0 ]]; then
    issue_labels=(feature)
  elif [[ -n "$explicit_issue_type" ]]; then
    issue_type="$explicit_issue_type"
  fi

  for issue_label in "${issue_labels[@]}"; do
    for existing_label in "${unique_labels[@]}"; do
      [[ "$existing_label" != "$issue_label" ]] || continue 2
    done
    unique_labels+=("$issue_label")
  done
  issue_labels=("${unique_labels[@]}")

  case "$issue_assignee" in
    me | @me) issue_assignee=@me ;;
  esac

  if [[ "$checkout_branch" == true ]]; then
    require_clean_worktree
    current_branch="$(git branch --show-current)"
    [[ -n "$current_branch" ]] || fail "detached HEAD is not supported"
    echo "Current branch is clean: $current_branch"
  fi
  require_github

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
  echo "Creating linked branch from main: $branch_name"
  if gh issue develop "$issue_number" \
    --base main \
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

  echo "Adding TAKEN label to issue #$issue_number"
  gh issue edit "$issue_number" --add-label TAKEN
}

issue_number_from_branch() {
  local branch="$1"

  if [[ "$branch" =~ ^(bug|feature)/([0-9]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  elif [[ "$branch" =~ ^([0-9]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    fail "cannot determine issue number from branch: $branch"
  fi
}

require_linked_issue() {
  local issue_number="$1"
  local current_branch="$2"
  local rows branch url

  rows="$(gh issue develop --list "$issue_number")"
  while IFS=$'\t' read -r branch url; do
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
  local test_runner="$PROJECT_ROOT/scripts/run-integration-tests.sh"
  local test_runner_missing=false

  require_clean_worktree
  require_github

  current_branch="$(git branch --show-current)"
  [[ -n "$current_branch" ]] || fail "detached HEAD is not supported"
  [[ "$current_branch" != main ]] || fail "cannot create a pull request from main"

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
  echo "  Base:   main"

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
    pr_body="$(
      printf 'Closes #%s\n\n## Verification\n\n- Tests were skipped via `./im.sh pr --skip-tests`.\n' \
        "$issue_number"
    )"
  elif [[ ! -f "$test_runner" ]]; then
    test_runner_missing=true
    pr_body="$(
      printf 'Closes #%s\n\n## Verification\n\n- Tests were not run because `scripts/run-integration-tests.sh` was not found.\n' \
        "$issue_number"
    )"
  else
    echo
    echo "Running full integration flow..."
    if "$test_runner"; then
      echo
      echo "Tests passed."
      pr_body="$(
        printf 'Closes #%s\n\n## Verification\n\n- `scripts/run-integration-tests.sh`\n' \
          "$issue_number"
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
  echo "Pushing branch to origin..."
  if git push --set-upstream origin "$current_branch"; then
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
      --base main \
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

cd "$PROJECT_ROOT"
require_command git

case "${1:-}" in
  '')
    [[ $# -eq 0 ]] || { usage >&2; exit 1; }
    main_menu
    ;;
  b | branch)
    [[ $# -le 2 ]] || { usage >&2; exit 1; }
    case "${2:-}" in
      '') new_branch ;;
      -me | --me) new_branch true ;;
      *) usage >&2; exit 1 ;;
    esac
    ;;
  m | milestone)
    [[ $# -eq 1 ]] || { usage >&2; exit 1; }
    new_branch false true
    ;;
  i)
    shift
    new_issue false "$@"
    ;;
  ii)
    shift
    new_issue true "$@"
    ;;
  pr)
    [[ $# -le 2 ]] || { usage >&2; exit 1; }
    case "${2:-}" in
      '') new_pr ;;
      --skip-tests) new_pr true ;;
      *) usage >&2; exit 1 ;;
    esac
    ;;
  -h | --help | help)
    [[ $# -eq 1 ]] || { usage >&2; exit 1; }
    usage
    ;;
  *) usage >&2; exit 1 ;;
esac
