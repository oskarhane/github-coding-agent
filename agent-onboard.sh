#!/usr/bin/env bash
# agent-onboard.sh — wire one repo up to the agent harness.
#
# Run from inside a clone of the target repo:
#   ./agent-onboard.sh --harness oskarhane/agent-harness --owner oskarhane \
#                      --app-id 123456 --app-key-file ~/keys/agent.pem
#
# Commits two caller workflows (~15 lines total). Everything else — prompts,
# policy, versions — stays in the harness. Idempotent.
set -euo pipefail

HARNESS=""                     # owner/repo of the harness
HARNESS_REF="v1"
OWNER=""
APP_ID=""
APP_KEY_FILE=""
CI_WORKFLOW="CI"               # literal `name:` of the workflow whose failures trigger the fix loop
LABEL="agent"
BRANCH="chore/agent-onboard"
WITH_CI_FIX=1
OPEN_PR=1
ASSUME_YES=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
agent-onboard.sh [options]

  --harness OWNER/REPO    harness repo (required)
  --harness-ref REF       tag/branch callers pin to      (default: v1)
  --owner LOGIN           login permitted to trigger     (required)
  --app-id ID             GitHub App id                  (required)
  --app-key-file PATH     App private key .pem           (required first time)
  --ci-workflow NAME      exact `name:` of your CI workflow (default: CI)
  --no-ci-fix             skip the CI-fix caller workflow
  --label NAME            trigger label                  (default: agent)
  --branch NAME           onboarding branch              (default: chore/agent-onboard)
  --no-pr                 commit + push, skip the PR
  --dry-run               print, change nothing
  -y, --yes               skip confirmation

Secrets, from env if set, else prompted:
  FIREWORKS_API_KEY, LINEAR_API_KEY
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --harness) HARNESS="$2"; shift 2 ;;
    --harness-ref) HARNESS_REF="$2"; shift 2 ;;
    --owner) OWNER="$2"; shift 2 ;;
    --app-id) APP_ID="$2"; shift 2 ;;
    --app-key-file) APP_KEY_FILE="$2"; shift 2 ;;
    --ci-workflow) CI_WORKFLOW="$2"; shift 2 ;;
    --no-ci-fix) WITH_CI_FIX=0; shift ;;
    --label) LABEL="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --no-pr) OPEN_PR=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
run() { if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }
step() { printf '\n== %s\n' "$*"; }

for bin in gh git jq; do command -v "$bin" >/dev/null || die "$bin not on PATH"; done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
git rev-parse --show-toplevel >/dev/null 2>&1 || die "not inside a git repo"
cd "$(git rev-parse --show-toplevel)"

[ -n "$HARNESS" ] || die "--harness is required"
[ -n "$OWNER" ] || die "--owner is required"
[ -n "$APP_ID" ] || die "--app-id is required"
case "$HARNESS" in */*) ;; *) die "--harness must be owner/repo";; esac

NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)

cat <<SUMMARY

repo        $NWO (default: $DEFAULT_BRANCH)
harness     $HARNESS@$HARNESS_REF
trigger     label "$LABEL" applied by $OWNER
PR author   GitHub App $APP_ID
ci-fix      $([ "$WITH_CI_FIX" = 1 ] && echo "on failures of \"$CI_WORKFLOW\"" || echo "skipped")
SUMMARY

if [ "$ASSUME_YES" = 0 ] && [ "$DRY_RUN" = 0 ]; then
  printf '\nproceed? [y/N] '; read -r reply
  case "$reply" in y|Y|yes) ;; *) echo "aborted"; exit 1 ;; esac
fi

# ------------------------------------------------------------------ secrets ---
read_secret() {
  local name="$1" val="${!1:-}"
  if [ -z "$val" ]; then
    printf 'value for %s (hidden): ' "$name" >&2
    read -rs val; printf '\n' >&2
  fi
  [ -n "$val" ] || die "$name must not be empty"
  printf '%s' "$val"
}
set_secret() { # piped via stdin so it never lands in argv/ps
  if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] gh secret set $1"; return; fi
  printf '%s' "$2" | gh secret set "$1"
}

step "secrets"
set_secret FIREWORKS_API_KEY "$(read_secret FIREWORKS_API_KEY)"
set_secret LINEAR_API_KEY "$(read_secret LINEAR_API_KEY)"
if [ -n "$APP_KEY_FILE" ]; then
  [ -f "$APP_KEY_FILE" ] || die "no such file: $APP_KEY_FILE"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] gh secret set AGENT_APP_PRIVATE_KEY < $APP_KEY_FILE"
  else
    gh secret set AGENT_APP_PRIVATE_KEY < "$APP_KEY_FILE"
  fi
else
  gh secret list --json name -q '.[].name' | grep -qx AGENT_APP_PRIVATE_KEY \
    || die "AGENT_APP_PRIVATE_KEY not set and no --app-key-file given"
  echo "  AGENT_APP_PRIVATE_KEY already present"
fi

# ---------------------------------------------------------------- variables ---
step "variables"
run gh variable set AGENT_OWNER --body "$OWNER"
run gh variable set AGENT_APP_ID --body "$APP_ID"

# -------------------------------------------------------------------- label ---
step "label"
if gh label list --json name -q '.[].name' | grep -qx "$LABEL"; then
  echo "  label '$LABEL' exists"
else
  run gh label create "$LABEL" --color 5319E7 --description "hand this issue to the coding agent"
fi

# ------------------------------------------------ environment (second gate) ---
step "environment 'agent'"
OWNER_ID=$(gh api "/users/$OWNER" -q .id)
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] PUT /repos/$NWO/environments/agent (reviewer: $OWNER)"
else
  gh api -X PUT "/repos/$NWO/environments/agent" \
    -F "wait_timer=0" \
    -F "reviewers[][type]=User" -F "reviewers[][id]=$OWNER_ID" >/dev/null 2>&1 \
    || echo "  ! required reviewers unavailable (plan limitation?) — the actor checks still apply"
fi

# --------------------------------------------------------- caller workflows ---
step "caller workflows"
mkdir -p .github/workflows

write() {
  local path="$1" tmp; tmp=$(mktemp); cat >"$tmp"
  if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] write $path"; rm -f "$tmp"; return; fi
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then echo "  unchanged $path"; rm -f "$tmp"; return; fi
  mv "$tmp" "$path"; chmod 0644 "$path"; echo "  wrote $path"
}

write .github/workflows/agent.yml <<YAML
# Thin caller. Prompts, policy and versions live in $HARNESS.
name: agent

on:
  issues:
    types: [labeled]

concurrency:
  group: agent-issue-\${{ github.event.issue.number }}
  cancel-in-progress: false

permissions: {}

jobs:
  agent:
    if: github.event.label.name == '$LABEL' && github.actor == vars.AGENT_OWNER
    uses: $HARNESS/.github/workflows/agent.yml@$HARNESS_REF
    with:
      owner: \${{ vars.AGENT_OWNER }}
      app-id: \${{ vars.AGENT_APP_ID }}
    secrets: inherit
YAML

if [ "$WITH_CI_FIX" = 1 ]; then
  write .github/workflows/agent-ci-fix.yml <<YAML
# Thin caller. Triggers must live here — a reusable workflow cannot own them.
name: agent-ci-fix

on:
  workflow_run:
    workflows: ["$CI_WORKFLOW"]
    types: [completed]

concurrency:
  group: agent-ci-fix-\${{ github.event.workflow_run.head_branch }}
  cancel-in-progress: false

permissions: {}

jobs:
  fix:
    if: >-
      github.event.workflow_run.conclusion == 'failure' &&
      startsWith(github.event.workflow_run.head_branch, 'agent/')
    uses: $HARNESS/.github/workflows/agent-ci-fix.yml@$HARNESS_REF
    with:
      app-id: \${{ vars.AGENT_APP_ID }}
    secrets: inherit
YAML
fi

if [ "$DRY_RUN" = 0 ] && ! grep -qx '\.agent/' .gitignore 2>/dev/null; then
  printf '\n# agent run artifacts\n.agent/\n' >>.gitignore
  echo "  appended .agent/ to .gitignore"
fi

# -------------------------------------------------------------------- commit ---
step "commit"
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] would commit to $BRANCH and open a PR"
elif [ -z "$(git status --porcelain)" ]; then
  echo "  nothing to commit"
else
  git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
  git add .github/workflows/agent.yml .gitignore
  [ "$WITH_CI_FIX" = 1 ] && git add .github/workflows/agent-ci-fix.yml
  git commit -qm "chore: onboard to agent harness" -m "calls $HARNESS@$HARNESS_REF"
  git push -u origin "$BRANCH"
  [ "$OPEN_PR" = 1 ] && gh pr create --fill --base "$DEFAULT_BRANCH" \
    --body "Calls the reusable workflows in $HARNESS@$HARNESS_REF. Prompts and policy live there."
fi

cat <<NEXT

== done. check these once per repo

1. The GitHub App ($APP_ID) is installed on $NWO with:
     Contents: write, Pull requests: write, Issues: write, Actions: read
   (Actions: read is what lets the CI-fix loop read failed job logs.)
   Do NOT grant Workflows: write — the agent must not edit its own triggers.
2. Branch protection on $DEFAULT_BRANCH: the agent opens PRs but must not merge.
3. --ci-workflow "$CI_WORKFLOW" matches your CI workflow's \`name:\` exactly,
   or the fix loop never fires.
4. Smoke test: Linear card -> GitHub issue titled with just its identifier ->
   apply "$LABEL". Then confirm in the run log:
     - opencode is 2.x
     - .agent/plan.md AND .agent/review-1.json both exist
       (missing review = subagent blocked, review silently no-opped)
     - the PR author is the App, and pull_request CI started on it
     - the Linear card moved to In Progress
NEXT
