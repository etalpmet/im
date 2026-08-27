# im

`im` is a small Bash CLI for issue-driven team workflows on GitHub.

It connects one straightforward process:

```text
GitHub issue → working branch → local issue context → tests → pull request
```

The issue provides the number, branch category, branch name source, and pull request title. `im` uses regular `git` commands and the [GitHub CLI](https://cli.github.com/) under the hood.

## Features

- Create assigned or unassigned GitHub Issues.
- Select issues assigned to you or available for anyone to take.
- Select issues through milestones.
- Create and check out branches linked to issues.
- Configure branch prefixes such as `bug/`, `feature/`, or `hotfix/`.
- Update every new branch from the latest base branch.
- Save a local Markdown snapshot of the selected issue in `im-issue/`.
- Run integration tests and create pull requests.
- Close issues automatically after merge through `Closes #<number>`.

## Requirements

- Bash 3.2 or newer.
- [Git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git).
- [GitHub CLI](https://cli.github.com/) (`gh`).
- A Git repository with a remote hosted on GitHub.com.

Authenticate after installing `gh`:

```bash
gh auth login --hostname github.com
```

If authentication is missing, `im` offers to start the login flow interactively.

## Installation

The recommended installation does not require `sudo` and can be updated with a regular `git pull`:

```bash
mkdir -p ~/.local/share ~/.local/bin
git clone https://github.com/etalpmet/im.git ~/.local/share/im
ln -s ~/.local/share/im/im.sh ~/.local/bin/im
```

Make sure `~/.local/bin` is in `PATH`. For zsh or Bash, add this line to the relevant shell configuration file:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Verify the installation:

```bash
im help
```

To update:

```bash
git -C ~/.local/share/im pull --ff-only
```

You can also skip installation and invoke the script by its full path or as `./im.sh` from this repository.

## Project setup

Move into any directory inside the target Git repository and run:

```bash
im init
```

`init`:

1. Finds the root of the current Git repository.
2. Creates `.imconfig` with suggested defaults, or reuses an existing config without overwriting it.
3. Offers to add `im-issue/` to the root `.gitignore`.
4. Offers to create missing branch labels and the work label on GitHub.

If `im-issue/` is not added to `.gitignore`, commands that create or select a working branch stop before changing anything on GitHub.

You can commit `.imconfig` as shared team configuration or temporarily ignore it when the settings should remain local.

## `.imconfig`

Example:

```ini
# im project configuration
base_branch=main
remote=origin
branch_allowed=bug,feature
branch_default=feature
work_label=TAKEN
test_script=scripts/run-integration-tests.sh
```

Values use plain `key=value` syntax without arrays, brackets, or shell quotes.

| Setting | Purpose |
| --- | --- |
| `base_branch` | Base branch for new branches and pull requests. |
| `remote` | Git remote used for fetch, pull, and push. |
| `branch_allowed` | Comma-separated GitHub labels that also become branch prefixes. |
| `branch_default` | Default branch prefix. It must be included in `branch_allowed`. |
| `work_label` | Label added after an issue is taken for development. |
| `test_script` | Executable test script relative to the repository root. |

Branch labels may contain lowercase ASCII letters, digits, `.`, `_`, and `-`.

The config is required for every working command. Unknown settings, duplicates, a missing remote, and invalid values are treated as errors.

## Command reference

| Command | Action |
| --- | --- |
| `im` | Open the interactive menu. |
| `im init` | Configure the current repository. |
| `im i "Title"` | Create an issue. |
| `im ii "Title"` | Create an issue and immediately start a working branch. |
| `im b` | Select an issue assigned to you or available to take. |
| `im b -me` | Select only from issues assigned to you. |
| `im m` | Select a milestone and then an issue. |
| `im pr` | Run checks and create a pull request. |
| `im help` | Show the built-in help. |

## Workflow

### Interactive menu

```bash
im
```

The menu provides issue branch selection, milestone selection, and pull request creation.

### Create an issue

```bash
im i "Add response caching"
```

By default, the issue:

- receives the `branch_default` label;
- is assigned to the current GitHub user.

Additional examples:

```bash
# Add multiple labels and a description
im i "Fix cache invalidation" -l bug -l backend -d "The cache is not cleared after an update"

# Assign another user
im i "Update the documentation" -u octocat

# Leave the issue unassigned
im i "Investigate slow requests" -ua
```

Arbitrary labels are allowed, but an issue may have only one label from `branch_allowed`.

### Create an issue and start working

```bash
im ii "Add response caching" -l feature -d "Cache API responses"
```

`ii`:

1. Requires a clean working tree.
2. Creates an issue assigned to the current user.
3. Creates a linked branch from `base_branch`.
4. Runs `git pull --ff-only <remote> <base_branch>` in the new branch.
5. Adds `work_label`.
6. Creates an issue snapshot in `im-issue/`.

### Select an assigned or available issue

```bash
im b
```

This lists open issues assigned to you and issues without an assignee. After selection:

- an existing linked branch is fetched and checked out;
- if no linked branch exists, one is created, updated from the base branch, assigned to you, and marked with `work_label`;
- the issue snapshot is created or updated.

Show only issues assigned to you:

```bash
im b -me
```

The long form is also supported:

```bash
im branch --me
```

### Select an issue from a milestone

```bash
im m
```

Or:

```bash
im milestone
```

Select an open milestone first and then an issue inside it. The remaining behavior is the same as `im b`.

### Create a pull request

Commit your work first, then run:

```bash
im pr
```

The command verifies that:

- the working tree is clean;
- the current branch is not `base_branch`;
- the issue number can be derived from the branch name;
- the branch is linked to that issue;
- the issue is still open;
- the branch does not already have an open pull request.

If `test_script` exists, it runs before push. A failing test script prevents pull request creation. If the script is missing, the pull request is still created and the missing verification is recorded in its `Verification` section.

Skip tests explicitly:

```bash
im pr --skip-tests
```

After verification, the branch is pushed to the configured `remote`. The pull request targets `base_branch`, uses the issue title, and contains `Closes #<number>`.

## Branch names

New branches use this format:

```text
<branch label>/<issue number>-<issue title slug>
```

Examples:

```text
feature/123-add-response-cache
bug/124-fix-cache-invalidation
```

If an existing issue has no label from `branch_allowed`, `branch_default` is used. If it has more than one allowed branch label, `im` stops with an error.

Every new branch pulls `remote/base_branch` using fast-forward-only mode. An existing linked branch is not synchronized with the base branch automatically.

## Local issue context

After creating or checking out a working branch, `im` fetches the current issue data and writes:

```text
im-issue/<issue number>-<issue title>.md
```

The snapshot contains:

- state and URL;
- branch name;
- assignees;
- labels;
- milestone;
- last update time;
- full description.

Issue comments are not included. Keep `im-issue/` in `.gitignore`.

## Complete example

```bash
cd ~/projects/my-service

# Run once per repository
im init

# Create an issue and immediately switch to its working branch
im ii "Add response caching" -l feature -d "Cache API responses"

# Work on the code
git add .
git commit -m "Add response cache"

# Run tests, push, and create a pull request
im pr
```

## Limitations

- Only GitHub.com is currently supported; the authentication hostname is fixed.
- `b`, `m`, `ii`, and `pr` require a clean working tree.
- The base branch and remote must exist before running working commands.
- `test_script` must be a relative path inside the repository.
- Checking out an existing linked branch does not update it from the base branch.
- If a linked branch already exists locally, its remote commits are not pulled automatically.

## License

[MIT](LICENSE)
