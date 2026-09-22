#!/usr/bin/env bash
# harness-init.sh — scaffold the central agent-harness repo.
#
# Everything that defines HOW the agent works lives here: the two reusable
# workflows, the opencode policy, the config-defined reviewer agent, and the
# prompts. Target repos get a 6-line caller workflow and nothing else, so
# bumping a version or editing a prompt is one commit + one tag move.
#
#   ./harness-init.sh --dir ~/src/agent-harness --create-repo
#
# Keep this repo PUBLIC: it holds no secrets, and public sidesteps both the
# private-reusable-workflow access setting and needing a token to check it out
# from inside a run.
set -euo pipefail

DIR=""
REPO_NAME="agent-harness"
CREATE_REPO=0
TAG="v1"
VISIBILITY="public"
# Fireworks model ids are provider-qualified: fireworks-ai/<slug> or
# fireworks-ai/accounts/fireworks/models/<name>. Check your catalogue and set
# this — the value below is only a placeholder that will fail loudly.
MODEL="fireworks-ai/accounts/fireworks/models/kimi-k2-instruct"
SMALL_MODEL=""                 # cheap model for title generation; defaults to MODEL
# Per-phase models. Empty = fall back to MODEL at run time. Workflow_call input
# defaults cannot reference another input, so the fallback happens in shell.
PLAN_MODEL=""
IMPLEMENT_MODEL=""
REVIEW_MODEL=""
PR_MODEL=""
MAX_CYCLES=2
OPENCODE_VERSION="2.0.1"
GBUILD_VERSION="0.4.0"
ECLI_REF="main"

usage() {
  cat <<'USAGE'
harness-init.sh --dir PATH [options]

  --dir PATH              where to scaffold (required)
  --create-repo           gh repo create + push + tag
  --repo-name NAME        repo name when creating          (default: agent-harness)
  --visibility V          public|private                   (default: public)
  --tag TAG               moving tag callers pin to        (default: v1)
  --model STR             default model, provider-qualified
                          (default: fireworks-ai/accounts/fireworks/models/kimi-k2-instruct)
  --small-model STR       cheap model for title generation (default: same as --model)
  --plan-model STR        model for plan + re-plan phases   (default: --model)
  --implement-model STR   model for implement + fix phases  (default: --model)
  --review-model STR      model for review phases           (default: --model)
  --pr-model STR          model for the PR phase            (default: --model)
  --max-cycles N          review cycles before giving up    (default: 2)
  --opencode-version X    must be 2.x                      (default: 2.0.1)
  --gbuild-version X      opencode-gbuild npm version      (default: 0.4.0)
  --ecli-ref REF          everything-cli git ref           (default: main)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --create-repo) CREATE_REPO=1; shift ;;
    --repo-name) REPO_NAME="$2"; shift 2 ;;
    --visibility) VISIBILITY="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --small-model) SMALL_MODEL="$2"; shift 2 ;;
    --plan-model) PLAN_MODEL="$2"; shift 2 ;;
    --implement-model) IMPLEMENT_MODEL="$2"; shift 2 ;;
    --review-model) REVIEW_MODEL="$2"; shift 2 ;;
    --pr-model) PR_MODEL="$2"; shift 2 ;;
    --max-cycles) MAX_CYCLES="$2"; shift 2 ;;
    --opencode-version) OPENCODE_VERSION="$2"; shift 2 ;;
    --gbuild-version) GBUILD_VERSION="$2"; shift 2 ;;
    --ecli-ref) ECLI_REF="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
[ -n "$DIR" ] || die "--dir is required"
case "$OPENCODE_VERSION" in 2.*) ;; *) die "opencode must be 2.x (gbuild is a V2 plugin)";; esac
command -v gh >/dev/null || die "gh not on PATH"

mkdir -p "$DIR"/{.github/workflows,opencode/agents,opencode/commands,prompts}
cd "$DIR"

# =============================================================== opencode ===
# OPENCODE_CONFIG_DIR points here. Per the docs that directory is searched for
# agents/commands/plugins like a .opencode dir, and is loaded AFTER project and
# .opencode config, so it overrides a target repo's own settings.
cat >opencode/opencode.jsonc <<JSONC
{
  "\$schema": "https://opencode.ai/config.json",

  // V2 keys: plugins (plural — v1 used singular "plugin"), and
  // shell/edit/subagent (v1: bash/write+patch/task).
  // npm coordinate, not github:...::path: — bun/npm cannot resolve that
  // selector, so the subdirectory install form fails to load.
  "plugins": ["opencode-gbuild@$GBUILD_VERSION"],

  "permission": {
    "edit": "allow",
    "shell": "allow",
    // MUST be allowed: the gbuild review skills dispatch a subagent. Without
    // it, review silently no-ops while the implementer proceeds unreviewed.
    "subagent": "allow"
  },

  // Default is 1: a primary agent may spawn a subagent, but a subagent may
  // not. If a gbuild skill is itself running as a subagent, the reviewer
  // spawn is blocked at depth 1 — the silent-no-op failure mode.
  "subagent_depth": 2,

  "autoupdate": false,        // a self-update mid-run would void the 2.x pin
  "share": "disabled",        // never expose a CI session publicly
  "snapshot": false,          // skip internal-git indexing of the whole tree
  "compaction": { "prune": true },      // long runs: drop stale tool output

  // Fireworks is native (models.dev id "fireworks-ai", env FIREWORKS_API_KEY),
  // but the documented setup is the interactive /connect flow, so declare it
  // here instead. {env:} keeps the key out of the config file.
  "provider": {
    "fireworks-ai": {
      "options": {
        "baseURL": "https://api.fireworks.ai/inference/v1",
        "apiKey": "{env:FIREWORKS_API_KEY}"
      }
    }
  },
  // Only Fireworks: a stray key in the runner env can't reroute spend.
  "enabled_providers": ["fireworks-ai"],$( [ -n "$SMALL_MODEL" ] && printf '\n  "small_model": "%s",  // titles etc. do not need the coding model' "$SMALL_MODEL" )

  // Config CAN define agents even though plugins cannot, which closes
  // gbuild's reviewer gap. Structurally unable to edit what it reviews.
  "agent": {
    "gbuild-reviewer": {
      "description": "Reviews the implementer's work. Read-only.",
      "tools": { "write": false, "edit": false }
    }
  }
}
JSONC

cat >opencode/agents/gbuild-reviewer.md <<'MD'
---
description: Reviews the implementer's work against the plan. Read-only.
tools:
  write: false
  edit: false
---

You review code you did not write. You never fix anything — you only report.

Assign each finding exactly one severity:

- `blocking` — wrong behaviour, data loss, a security hole, a broken build, or
  a departure from the plan that was not justified in writing.
- `medium` — correct but fragile: a missing test for changed behaviour, an
  unhandled error path, a leaked resource, a misleading name.
- `low` — style and taste.

Judge against the plan in `.agent/plan.md` and the issue's stated intent, not
against how you would have done it. "I would have structured this differently"
is not a finding.

Write findings as a JSON array to the path you are given, one object per
finding: `{"severity","file","summary","resolved":false}`. Empty array if
clean. No prose outside the file.
MD

cat >opencode/commands/agent-task.md <<'MD'
---
description: Work a Linear issue end to end and open a PR
agent: build
---

Task: Linear issue $ARGUMENTS.

Read it before anything else:
  everything-cli linear issue get $ARGUMENTS --format toon
  everything-cli linear issue comments $ARGUMENTS --format toon

This is a non-interactive session. Nobody will answer questions.
If the issue is too underspecified for sound assumptions, do NOT implement.
Post your open questions instead:
  everything-cli linear issue comment create $ARGUMENTS --body "..."
and stop without opening a PR.
MD

# ================================================================ prompts ===
# The prompt is the product here — it changes far more often than the wiring,
# which is the whole reason it lives in one repo behind a moving tag.
cat >prompts/01-plan.md <<'MD'
Task: the spec in .agent/task.md — a frozen snapshot of GitHub issue
#__ISSUE_NUMBER__ taken when this run was triggered. Do NOT re-fetch the issue
via gh or any API: later edits by the issue author are deliberately excluded;
the snapshot is the approved spec.

If the snapshot references a Linear identifier (e.g. ENG-123), read that card
as supplementary context:
  everything-cli linear issue get <ID> --format toon
  everything-cli linear issue comments <ID> --format toon
The frozen snapshot remains the spec of record.

This is a non-interactive session. Nobody will answer questions, and you will
be handed off to a different model for implementation — so the plan has to
stand on its own.

If the spec is too underspecified for sound assumptions, do NOT plan. Post
your open questions — on the Linear card if one is linked, otherwise on the
GitHub issue:
  everything-cli linear issue comment create <ID> --body "..."
  gh issue comment __ISSUE_NUMBER__ --body "..."
then write the single line NEEDS-CLARIFICATION to .agent/plan.md and stop.

Otherwise use the gbuild-plan skill and write .agent/plan.md containing:
- the change, file by file
- every assumption you are making, stated explicitly
- how it will be verified (which tests, which command)

Plan only. Do not edit any file other than .agent/plan.md. Work will happen on
branch __BRANCH__.
MD

cat >prompts/02-implement.md <<'MD'
Implement the plan in .agent/plan.md using the gbuild-run skill.

Create and work on branch __BRANCH__. Never commit to the default branch.
Follow the plan. If you must depart from it, append a "Deviations" section to
.agent/plan.md saying what and why — do not silently improvise.

Commit your work. Do not open a PR yet.
Never touch anything under .github/ or .opencode/.
MD

cat >prompts/03-review.md <<'MD'
Review the work on this branch against .agent/plan.md using the gbuild-review
skill, dispatched to the gbuild-reviewer agent.

Write findings to __REVIEW_FILE__ as a JSON array, one object per finding:
{"severity":"blocking"|"medium"|"low","file":"...","summary":"...","resolved":false}

An empty array means clean. Write nothing else to that file, and fix nothing in
this phase — reviewing and fixing are separate models on purpose.
MD

cat >prompts/04-fix.md <<'MD'
Address the findings in __REVIEW_FILE__.

Plan the fixes first, then apply them. Fix every "blocking" and every "medium"
finding; leave "low" alone. Set "resolved":true on each finding you address.

You may not downgrade a severity the reviewer assigned. If you disagree, say so
in that finding's summary and leave the severity as it is.

Commit the fixes. Never touch anything under .github/ or .opencode/.
MD

cat >prompts/05-pr.md <<'MD'
Open the pull request for this branch using the gbuild-pr skill.

The description must contain:
- the line "__FIXES_LINE__" (drives the Linear status change, or closes the
  GitHub issue on merge)
- the assumptions section from .agent/plan.md
- any finding still unresolved in the .agent/review-*.json files

Open it as a draft if any blocking finding remains unresolved.
Never merge. Never force-push.
MD

cat >prompts/ci-fix.md <<'MD'
CI is failing on this branch. The failing job output is in
.agent/ci-failure.log.

Fix ONLY what is needed to make those checks pass. Do not re-plan, do not
refactor, do not change the approach, do not touch .github/ or .opencode/.
If the failure is not caused by this branch's changes, say so in the commit
message and stop without further edits.

Commit with a message starting "[agent-ci-fix] ". Never force-push.
MD

# ====================================================== reusable: issue run ===
cat >.github/workflows/agent.yml <<YAML
# Reusable. Callers trigger on \`issues: labeled\` and \`issue_comment: created\`,
# and pass owner + allowed-actors + app-id.
name: agent (reusable)

on:
  workflow_call:
    inputs:
      owner:
        description: GitHub login permitted to trigger runs (fallback allowlist)
        required: true
        type: string
      allowed-actors:
        description: JSON array of logins permitted to trigger via the agent label
        required: false
        type: string
        default: ""
      app-id:
        description: GitHub App id used to author the PR
        required: true
        type: string
      model:
        description: fallback model for any phase left unset
        required: false
        type: string
        default: "$MODEL"
      plan-model:
        required: false
        type: string
        default: "$PLAN_MODEL"
      implement-model:
        required: false
        type: string
        default: "$IMPLEMENT_MODEL"
      review-model:
        required: false
        type: string
        default: "$REVIEW_MODEL"
      pr-model:
        required: false
        type: string
        default: "$PR_MODEL"
      max-cycles:
        description: review/fix cycles before the run gives up
        required: false
        type: number
        default: $MAX_CYCLES
      opencode-version:
        required: false
        type: string
        default: "$OPENCODE_VERSION"
      gbuild-version:
        required: false
        type: string
        default: "$GBUILD_VERSION"
      ecli-ref:
        required: false
        type: string
        default: "$ECLI_REF"
    secrets:
      AGENT_APP_PRIVATE_KEY:
        required: true
      FIREWORKS_API_KEY:
        required: true
      LINEAR_API_KEY:
        required: true

jobs:
  agent:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    environment: agent          # resolves in the CALLER repo
    env:
      EVERYTHING_CLI_CONFIG_DIR: \${{ runner.temp }}/ecli-config
      HARNESS_DIR: \${{ runner.temp }}/harness
      RUN_URL: \${{ github.server_url }}/\${{ github.repository }}/actions/runs/\${{ github.run_id }}
    steps:
      # Fail closed even if a caller forgets its own \`if:\` gate. Two trigger
      # paths: the agent label (allowlisted logins) and an \`@bot\` comment from
      # a MEMBER/OWNER/COLLABORATOR on an issue (PR comments never trigger).
      # All event data arrives via env — never inline \${{ }} into run blocks.
      - name: Gate on trigger
        env:
          EVENT: \${{ github.event_name }}
          ACTOR: \${{ github.actor }}
          LABEL: \${{ github.event.label.name }}
          PR_NUM: \${{ github.event.issue.pull_request.number }}
          COMMENT_BODY: \${{ github.event.comment.body }}
          COMMENT_ASSOC: \${{ github.event.comment.author_association }}
          ALLOWED: \${{ inputs.allowed-actors }}
          OWNER: \${{ inputs.owner }}
        run: |
          set -euo pipefail
          ok=""
          if [ "\$EVENT" = "issues" ] && [ "\$LABEL" = "agent" ]; then
            allowed="\$ALLOWED"
            [ -n "\$allowed" ] || allowed=\$(jq -nc --arg o "\$OWNER" '[\$o]')
            printf '%s' "\$allowed" | jq -e --arg a "\$ACTOR" 'index(\$a) != null' >/dev/null && ok=1
          elif [ "\$EVENT" = "issue_comment" ] && [ -z "\$PR_NUM" ]; then
            case "\$COMMENT_ASSOC" in
              MEMBER|OWNER|COLLABORATOR)
                case "\$COMMENT_BODY" in *@bot*) ok=1 ;; esac ;;
            esac
          fi
          if [ -z "\$ok" ]; then
            echo "::error::\$EVENT by \$ACTOR is not a permitted agent trigger"
            exit 1
          fi
          echo "trigger: \$EVENT by \$ACTOR — permitted"

      # App installation token: makes the App the PR author AND lets the
      # resulting PR trigger pull_request workflows, which GITHUB_TOKEN-
      # authored PRs do not.
      - name: Mint App token
        id: app
        uses: actions/create-github-app-token@v2
        with:
          app-id: \${{ inputs.app-id }}
          private-key: \${{ secrets.AGENT_APP_PRIVATE_KEY }}

      - uses: actions/checkout@v5
        with:
          token: \${{ steps.app.outputs.token }}
          fetch-depth: 0

      # Check the harness out at the exact ref this workflow was called at, so
      # config and prompt always match the workflow running them.
      - name: Check out harness
        run: |
          set -euo pipefail
          ref_full="\${{ github.job_workflow_ref }}"   # owner/repo/.github/...@ref
          repo=\$(printf '%s' "\$ref_full" | cut -d/ -f1,2)
          ref=\${ref_full#*@}
          echo "harness \$repo @ \$ref"
          git clone --depth 1 --branch "\${ref##*/}" \\
            "\${{ github.server_url }}/\$repo" "\$HARNESS_DIR"

      # TITLE/BODY come from the trigger event payload — a frozen snapshot.
      # The issue is never re-fetched: post-trigger edits must not reach the
      # agent. No Linear identifier means GitHub-issue-only mode, not failure.
      - name: Resolve task source
        id: linear
        env:
          ISSUE: \${{ github.event.issue.number }}
          TITLE: \${{ github.event.issue.title }}
          BODY: \${{ github.event.issue.body }}
        run: |
          set -euo pipefail
          id=\$(printf '%s\\n%s\\n' "\$TITLE" "\$BODY" \\
               | grep -oE '\\b[A-Z][A-Z0-9]{1,9}-[0-9]+\\b' | head -n1 || true)
          if [ -n "\$id" ]; then
            echo "Linear card: \$id"
            echo "id=\$id" >>"\$GITHUB_OUTPUT"
            echo "branch=agent/\$(printf '%s' "\$id" | tr '[:upper:]' '[:lower:]')" >>"\$GITHUB_OUTPUT"
          else
            echo "::notice::no Linear identifier in the issue — running in GitHub-issue-only mode"
            echo "id=" >>"\$GITHUB_OUTPUT"
            echo "branch=agent/issue-\$ISSUE" >>"\$GITHUB_OUTPUT"
          fi

      # The frozen spec: written once from the event payload, then quoted back
      # to the issue so the executed spec is visible in the timeline.
      - name: Snapshot the spec and acknowledge
        env:
          GH_TOKEN: \${{ steps.app.outputs.token }}
          ISSUE: \${{ github.event.issue.number }}
          TITLE: \${{ github.event.issue.title }}
          BODY: \${{ github.event.issue.body }}
          EVENT: \${{ github.event_name }}
          ACTOR: \${{ github.actor }}
          BRANCH: \${{ steps.linear.outputs.branch }}
        run: |
          set -euo pipefail
          mkdir -p .agent
          {
            printf '# %s\\n\\n' "\$TITLE"
            printf 'GitHub issue #%s, frozen at trigger time (%s by @%s). Later edits to the issue do not affect this run.\\n\\n---\\n\\n' "\$ISSUE" "\$EVENT" "\$ACTOR"
            printf '%s\\n' "\$BODY"
          } > .agent/task.md
          wc -l .agent/task.md
          {
            printf '🤖 Picking this up on branch \`%s\`. Run: %s\\n\\n' "\$BRANCH" "\$RUN_URL"
            printf 'Working from the issue as it was when triggered — edits after this comment do not change what I work on.\\n\\n'
            printf '<details><summary>Frozen spec</summary>\\n\\n%s\\n\\n</details>' "\$BODY"
          } > .agent/ack.md
          gh issue comment "\$ISSUE" --body-file .agent/ack.md

      - uses: actions/setup-go@v6
        if: steps.linear.outputs.id != ''
        with:
          go-version: stable

      - name: Restore everything-cli
        if: steps.linear.outputs.id != ''
        id: ecli-cache
        uses: actions/cache@v4
        with:
          path: ~/.local/bin/everything-cli
          key: ecli-\${{ runner.os }}-\${{ inputs.ecli-ref }}

      - name: Build everything-cli
        if: steps.linear.outputs.id != '' && steps.ecli-cache.outputs.cache-hit != 'true'
        run: |
          set -euo pipefail
          # The published installer still ships the old google-cli-named
          # release, so build from source and cache the binary.
          git clone --depth 1 --branch "\${{ inputs.ecli-ref }}" \\
            https://github.com/oskarhane/everything-cli "\$RUNNER_TEMP/ecli-src"
          make -C "\$RUNNER_TEMP/ecli-src" build
          mkdir -p "\$HOME/.local/bin"
          cp "\$RUNNER_TEMP/ecli-src/bin/everything-cli" "\$HOME/.local/bin/"

      - name: Configure Linear account
        if: steps.linear.outputs.id != ''
        env:
          LINEAR_API_KEY: \${{ secrets.LINEAR_API_KEY }}
        run: |
          set -euo pipefail
          echo "\$HOME/.local/bin" >>"\$GITHUB_PATH"
          export PATH="\$HOME/.local/bin:\$PATH"
          mkdir -p "\$EVERYTHING_CLI_CONFIG_DIR"
          # Own step so the key lands in the 0600 account file rather than the
          # agent step's env. Pipe is the fallback if the env var is not read
          # non-interactively.
          everything-cli linear account add ci \\
            || printf '%s\\n' "\$LINEAR_API_KEY" | everything-cli linear account add ci
          everything-cli linear account whoami

      - name: Install opencode
        env:
          VERSION: \${{ inputs.opencode-version }}
        run: |
          set -euo pipefail
          curl -fsSL https://opencode.ai/install | bash
          echo "\$HOME/.opencode/bin" >>"\$GITHUB_PATH"
          export PATH="\$HOME/.opencode/bin:\$PATH"
          v=\$(opencode --version)
          echo "opencode \$v"
          case "\$v" in
            2.*) ;;
            *) echo "::error::opencode \$v is not 2.x — the gbuild V2 plugin will not load"; exit 1 ;;
          esac

      - name: Restore plugin cache
        uses: actions/cache@v4
        with:
          path: ~/.cache/opencode/npm
          key: opencode-plugins-\${{ inputs.gbuild-version }}

      - name: Install everything-cli skill for opencode
        if: steps.linear.outputs.id != ''
        run: |
          set -euo pipefail
          # Skill install detects agents by their config dir existing, which a
          # fresh runner does not have — create it first or this no-ops.
          mkdir -p "\$HOME/.config/opencode"
          everything-cli skill install --agent opencode

      - name: Render phase prompts
        run: |
          set -euo pipefail
          mkdir -p .agent "\$RUNNER_TEMP/prompts"
          if [ -n "\${{ steps.linear.outputs.id }}" ]; then
            FIXES_LINE="Fixes \${{ steps.linear.outputs.id }}"
          else
            FIXES_LINE="Closes #\${{ github.event.issue.number }}"
          fi
          for f in "\$HARNESS_DIR"/prompts/0*.md; do
            sed -e "s|__LINEAR_ID__|\${{ steps.linear.outputs.id }}|g" \\
                -e "s|__BRANCH__|\${{ steps.linear.outputs.branch }}|g" \\
                -e "s|__ISSUE_NUMBER__|\${{ github.event.issue.number }}|g" \\
                -e "s|__FIXES_LINE__|\$FIXES_LINE|g" \\
                "\$f" >"\$RUNNER_TEMP/prompts/\$(basename "\$f")"
          done
          ls -1 "\$RUNNER_TEMP/prompts"

      - name: Start opencode server
        env:
          FIREWORKS_API_KEY: \${{ secrets.FIREWORKS_API_KEY }}
          OPENCODE_CONFIG_DIR: \${{ runner.temp }}/harness/opencode
          OPENCODE_DISABLE_PROJECT_CONFIG: "1"
          OPENCODE_CONFIG_CONTENT: '{"model":"\${{ inputs.model }}","plugins":["opencode-gbuild@\${{ inputs.gbuild-version }}"]}'
        run: |
          set -uo pipefail
          # One server for all phases: otherwise plugin + MCP cold boot is paid
          # once per phase, and there are up to seven of them.
          nohup opencode serve --port 4096 >"\$RUNNER_TEMP/serve.log" 2>&1 &
          echo \$! >"\$RUNNER_TEMP/serve.pid"
          for _ in \$(seq 1 60); do
            code=\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4096/api/session || echo 000)
            [ "\$code" != "000" ] && { echo "ATTACH=http://127.0.0.1:4096" >>"\$GITHUB_ENV"; exit 0; }
            sleep 1
          done
          echo "::warning::opencode serve did not come up — phases will each cold boot"
          sed -n '1,40p' "\$RUNNER_TEMP/serve.log" || true
          echo "ATTACH=" >>"\$GITHUB_ENV"

      - name: Phase 1 — plan
        env:
          FIREWORKS_API_KEY: \${{ secrets.FIREWORKS_API_KEY }}
          GH_TOKEN: \${{ steps.app.outputs.token }}
          OPENCODE_CONFIG_DIR: \${{ runner.temp }}/harness/opencode
          OPENCODE_DISABLE_PROJECT_CONFIG: "1"
          OPENCODE_CONFIG_CONTENT: '{"model":"\${{ inputs.model }}","plugins":["opencode-gbuild@\${{ inputs.gbuild-version }}"]}'
        run: |
          set -euo pipefail
          git config user.email "agent@users.noreply.github.com"
          git config user.name "agent"

          M_PLAN="\${{ inputs.plan-model }}"; [ -n "\$M_PLAN" ] || M_PLAN="\${{ inputs.model }}"
          echo "M_PLAN=\$M_PLAN" >>"\$GITHUB_ENV"

          # Create the session up front so every later phase threads --session
          # explicitly. --continue means "the last session", which is ambiguous
          # the moment anything else runs in this workspace.
          sid=\$(opencode api v2.session.create \\
                  --data "{\"title\":\"agent \${{ steps.linear.outputs.branch }}\"}" 2>/dev/null \\
                | jq -r '.id // .sessionID // empty' || true)
          if [ -n "\$sid" ]; then
            echo "SID=\$sid" >>"\$GITHUB_ENV"
            echo "session \$sid"
          else
            echo "::warning::could not pre-create a session — falling back to --continue"
            echo "SID=" >>"\$GITHUB_ENV"
          fi

          opencode run \${ATTACH:+--attach "\$ATTACH"} \${sid:+--session "\$sid"} \\
            -m "\$M_PLAN" "\$(cat "\$RUNNER_TEMP/prompts/01-plan.md")"

      - name: Gate — plan exists and is actionable
        run: |
          set -euo pipefail
          test -f .agent/plan.md || { echo "::error::no .agent/plan.md — the plan phase produced nothing"; exit 1; }
          if grep -q '^NEEDS-CLARIFICATION' .agent/plan.md; then
            echo "::notice::spec was underspecified; questions posted, stopping before implementation"
            echo "STOP=1" >>"\$GITHUB_ENV"
          fi
          wc -l .agent/plan.md

      - name: Phase 2 — implement
        if: env.STOP != '1'
        env:
          FIREWORKS_API_KEY: \${{ secrets.FIREWORKS_API_KEY }}
          GH_TOKEN: \${{ steps.app.outputs.token }}
          OPENCODE_CONFIG_DIR: \${{ runner.temp }}/harness/opencode
          OPENCODE_DISABLE_PROJECT_CONFIG: "1"
          OPENCODE_CONFIG_CONTENT: '{"model":"\${{ inputs.model }}","plugins":["opencode-gbuild@\${{ inputs.gbuild-version }}"]}'
        run: |
          set -euo pipefail
          M="\${{ inputs.implement-model }}"; [ -n "\$M" ] || M="\${{ inputs.model }}"
          echo "implementing with \$M"
          resume() { if [ -n "\${SID:-}" ]; then printf '%s %s' --session "\$SID"; else printf '%s' --continue; fi; }
          opencode run \${ATTACH:+--attach "\$ATTACH"} \$(resume) \\
            -m "\$M" "\$(cat "\$RUNNER_TEMP/prompts/02-implement.md")"

      - name: Gate — something was actually implemented
        if: env.STOP != '1'
        run: |
          set -euo pipefail
          base="\${{ github.event.repository.default_branch }}"
          if [ -z "\$(git log --oneline "origin/\$base..HEAD" 2>/dev/null)" ] && [ -z "\$(git status --porcelain)" ]; then
            echo "::error::implement phase produced no commits and no working-tree changes"
            exit 1
          fi
          git --no-pager log --oneline "origin/\$base..HEAD" 2>/dev/null | head -20 || true

      - name: Phases 3-6 — review / fix cycles
        if: env.STOP != '1'
        env:
          FIREWORKS_API_KEY: \${{ secrets.FIREWORKS_API_KEY }}
          GH_TOKEN: \${{ steps.app.outputs.token }}
          OPENCODE_CONFIG_DIR: \${{ runner.temp }}/harness/opencode
          OPENCODE_DISABLE_PROJECT_CONFIG: "1"
          OPENCODE_CONFIG_CONTENT: '{"model":"\${{ inputs.model }}","plugins":["opencode-gbuild@\${{ inputs.gbuild-version }}"]}'
        run: |
          set -euo pipefail
          M_REVIEW="\${{ inputs.review-model }}"; [ -n "\$M_REVIEW" ] || M_REVIEW="\${{ inputs.model }}"
          M_FIX="\${{ inputs.implement-model }}"; [ -n "\$M_FIX" ] || M_FIX="\${{ inputs.model }}"
          resume() { if [ -n "\${SID:-}" ]; then printf '%s %s' --session "\$SID"; else printf '%s' --continue; fi; }

          for cycle in \$(seq 1 \${{ inputs.max-cycles }}); do
            rf=".agent/review-\$cycle.json"
            echo "::group::review cycle \$cycle (\$M_REVIEW)"
            sed "s|__REVIEW_FILE__|\$rf|g" "\$RUNNER_TEMP/prompts/03-review.md" >"\$RUNNER_TEMP/prompts/r.md"
            opencode run \${ATTACH:+--attach "\$ATTACH"} \$(resume) -m "\$M_REVIEW" \\
              "\$(cat "\$RUNNER_TEMP/prompts/r.md")"
            echo "::endgroup::"

            # The single most important gate: no file here means the reviewer
            # subagent never ran, and an unreviewed PR looks identical to a
            # reviewed one.
            if [ ! -f "\$rf" ]; then
              echo "::error::\$rf missing — the review subagent did not run. Check that 'subagent' is permitted and subagent_depth >= 2."
              exit 1
            fi
            jq -e 'type == "array"' "\$rf" >/dev/null || { echo "::error::\$rf is not a JSON array"; exit 1; }

            open=\$(jq '[.[] | select((.severity=="blocking" or .severity=="medium") and (.resolved != true))] | length' "\$rf")
            blocking=\$(jq '[.[] | select(.severity=="blocking" and (.resolved != true))] | length' "\$rf")
            echo "cycle \$cycle: \$open open blocking/medium findings (\$blocking blocking)"
            [ "\$open" -eq 0 ] && { echo "clean — leaving the loop"; break; }

            echo "::group::fix cycle \$cycle (\$M_FIX)"
            sed "s|__REVIEW_FILE__|\$rf|g" "\$RUNNER_TEMP/prompts/04-fix.md" >"\$RUNNER_TEMP/prompts/f.md"
            opencode run \${ATTACH:+--attach "\$ATTACH"} \$(resume) -m "\$M_FIX" \\
              "\$(cat "\$RUNNER_TEMP/prompts/f.md")"
            echo "::endgroup::"
          done

          last=\$(ls -1 .agent/review-*.json | sort -V | tail -n1)
          if [ "\$(jq '[.[] | select(.severity=="blocking" and (.resolved != true))] | length' "\$last")" -gt 0 ]; then
            echo "::warning::blocking findings remain after \${{ inputs.max-cycles }} cycles — the PR will be a draft"
            echo "DRAFT=1" >>"\$GITHUB_ENV"
          fi

      - name: Phase 7 — open the PR
        if: env.STOP != '1'
        env:
          FIREWORKS_API_KEY: \${{ secrets.FIREWORKS_API_KEY }}
          GH_TOKEN: \${{ steps.app.outputs.token }}
          OPENCODE_CONFIG_DIR: \${{ runner.temp }}/harness/opencode
          OPENCODE_DISABLE_PROJECT_CONFIG: "1"
          OPENCODE_CONFIG_CONTENT: '{"model":"\${{ inputs.model }}","plugins":["opencode-gbuild@\${{ inputs.gbuild-version }}"]}'
        run: |
          set -euo pipefail
          M="\${{ inputs.pr-model }}"; [ -n "\$M" ] || M="\${{ inputs.model }}"
          resume() { if [ -n "\${SID:-}" ]; then printf '%s %s' --session "\$SID"; else printf '%s' --continue; fi; }
          opencode run \${ATTACH:+--attach "\$ATTACH"} \$(resume) -m "\$M" \\
            "\$(cat "\$RUNNER_TEMP/prompts/05-pr.md")"

      - name: Gate — the PR exists
        if: env.STOP != '1'
        env:
          GH_TOKEN: \${{ steps.app.outputs.token }}
        run: |
          set -euo pipefail
          url=\$(gh pr list --head "\${{ steps.linear.outputs.branch }}" --json url -q '.[0].url')
          [ -n "\$url" ] || { echo "::error::no PR on \${{ steps.linear.outputs.branch }}"; exit 1; }
          echo "\$url"

      - name: Which models actually answered
        if: always()
        run: |
          # Worth checking rather than trusting: a non-default model can revert
          # to the agent default mid-session, with the transcript still naming
          # the model you asked for, and both get billed.
          opencode stats --days 1 --models || echo "(stats unavailable)"

      - name: Stop opencode server
        if: always()
        run: |
          [ -f "\$RUNNER_TEMP/serve.pid" ] && kill "\$(cat "\$RUNNER_TEMP/serve.pid")" 2>/dev/null || true
          exit 0

      - name: Upload artifacts
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: agent-run-\${{ github.run_id }}
          path: .agent/
          if-no-files-found: warn

      - name: Report back
        if: always()
        env:
          GH_TOKEN: \${{ steps.app.outputs.token }}
          ID: \${{ steps.linear.outputs.id }}
          ISSUE: \${{ github.event.issue.number }}
          BRANCH: \${{ steps.linear.outputs.branch }}
        run: |
          set -uo pipefail
          pr=\$(gh pr list --head "\$BRANCH" --json url -q '.[0].url' 2>/dev/null || true)
          body="Agent run **\${{ job.status }}** — \$RUN_URL"
          [ -n "\$pr" ] && body="\$body"\$'\\n'"PR: \$pr"
          gh issue comment "\$ISSUE" --body "\$body" || true
          if [ -n "\${ID:-}" ]; then
            if [ -n "\$pr" ]; then
              everything-cli linear issue attachment create "\$ID" --url "\$pr" --title "PR" || true
            fi
            everything-cli linear issue comment create "\$ID" --body "\$body" || true
          fi

      - name: Release the label
        if: always()
        env:
          GH_TOKEN: \${{ steps.app.outputs.token }}
        run: |
          # Removing it makes re-applying the label a re-run button.
          gh issue edit "\${{ github.event.issue.number }}" --remove-label agent || true
YAML

# ======================================================= reusable: ci fix ===
cat >.github/workflows/agent-ci-fix.yml <<YAML
# Reusable. Callers trigger on \`workflow_run\` for their own CI workflow name.
name: agent-ci-fix (reusable)

on:
  workflow_call:
    inputs:
      app-id:
        required: true
        type: string
      model:
        required: false
        type: string
        default: "$MODEL"
      opencode-version:
        required: false
        type: string
        default: "$OPENCODE_VERSION"
      gbuild-version:
        required: false
        type: string
        default: "$GBUILD_VERSION"
      max-attempts:
        required: false
        type: number
        default: 3
    secrets:
      AGENT_APP_PRIVATE_KEY:
        required: true
      FIREWORKS_API_KEY:
        required: true

jobs:
  fix:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    env:
      BRANCH: \${{ github.event.workflow_run.head_branch }}
      HARNESS_DIR: \${{ runner.temp }}/harness
    steps:
      - name: Mint App token
        id: app
        uses: actions/create-github-app-token@v2
        with:
          app-id: \${{ inputs.app-id }}
          private-key: \${{ secrets.AGENT_APP_PRIVATE_KEY }}

      - uses: actions/checkout@v5
        with:
          token: \${{ steps.app.outputs.token }}
          ref: \${{ github.event.workflow_run.head_branch }}
          fetch-depth: 0

      - name: Check out harness
        run: |
          set -euo pipefail
          ref_full="\${{ github.job_workflow_ref }}"
          repo=\$(printf '%s' "\$ref_full" | cut -d/ -f1,2)
          ref=\${ref_full#*@}
          git clone --depth 1 --branch "\${ref##*/}" \\
            "\${{ github.server_url }}/\$repo" "\$HARNESS_DIR"

      - name: Cap the retry loop
        run: |
          set -euo pipefail
          base="\${{ github.event.repository.default_branch }}"
          n=\$(git log --oneline "origin/\$base..HEAD" --grep='\\[agent-ci-fix\\]' | wc -l | tr -d ' ')
          echo "prior fix attempts: \$n"
          if [ "\$n" -ge "\${{ inputs.max-attempts }}" ]; then
            echo "::error::\$n fix attempts already — stopping, this needs a human"
            exit 1
          fi

      - name: Capture failing logs
        env:
          GH_TOKEN: \${{ steps.app.outputs.token }}
        run: |
          set -euo pipefail
          mkdir -p .agent
          # Needs the App to have Actions: read.
          gh run view "\${{ github.event.workflow_run.id }}" --log-failed \\
            | tail -c 200000 >.agent/ci-failure.log
          wc -l .agent/ci-failure.log

      - name: Install opencode
        env:
          VERSION: \${{ inputs.opencode-version }}
        run: |
          set -euo pipefail
          curl -fsSL https://opencode.ai/install | bash
          echo "\$HOME/.opencode/bin" >>"\$GITHUB_PATH"

      - name: Restore plugin cache
        uses: actions/cache@v4
        with:
          path: ~/.cache/opencode/npm
          key: opencode-plugins-\${{ inputs.gbuild-version }}

      - name: Fix and push
        env:
          FIREWORKS_API_KEY: \${{ secrets.FIREWORKS_API_KEY }}
          GH_TOKEN: \${{ steps.app.outputs.token }}
          OPENCODE_CONFIG_DIR: \${{ runner.temp }}/harness/opencode
          OPENCODE_DISABLE_PROJECT_CONFIG: "1"
          OPENCODE_CONFIG_CONTENT: '{"model":"\${{ inputs.model }}","plugins":["opencode-gbuild@\${{ inputs.gbuild-version }}"]}'
        run: |
          set -euo pipefail
          git config user.email "agent@users.noreply.github.com"
          git config user.name "agent"
          opencode run "\$(cat "\$HARNESS_DIR/prompts/ci-fix.md")"
          git push origin "HEAD:\$BRANCH"
YAML

# ================================================================== README ===
cat >README.md <<MD
# agent-harness

Central definition of the issue -> opencode -> PR agent (Linear optional).
Target repos hold a caller workflow and nothing else.

| Path | What it is |
|---|---|
| \`.github/workflows/agent.yml\` | reusable: label on a pointer issue -> PR |
| \`.github/workflows/agent-ci-fix.yml\` | reusable: red CI on an \`agent/*\` branch -> fix commit |
| \`opencode/opencode.jsonc\` | policy: plugin pin, permissions, subagent depth |
| \`opencode/agents/gbuild-reviewer.md\` | read-only reviewer (plugins cannot register agents; config can) |
| \`opencode/commands/agent-task.md\` | the flow as an opencode command |
| \`prompts/01-plan.md\` … \`05-pr.md\` | one prompt per phase |
| \`prompts/ci-fix.md\` | the deliberately narrow CI-fix prompt |
| \`agent-onboard.sh\` | run from a target repo clone to wire that repo up to this harness |

## Onboarding a target repo

The onboarding script ships here, so this repo is all you need to enable a new
target:

    gh repo clone <you>/agent-harness    # or curl the raw script at tag v1
    cd /path/to/target-repo
    /path/to/agent-harness/agent-onboard.sh --harness <you>/agent-harness --owner <you> \\
      --app-id <app-id> --app-key-file ~/keys/agent.pem --ci-workflow "CI" --dry-run

Inspect the dry run, then re-run without \`--dry-run\`. It creates the \`agent\`
label, three secrets, two variables, the gated \`agent\` environment, and commits
the two caller workflows on a branch with a PR. The script operates on whatever
repo you run it from — nothing of it stays behind beyond the two callers.

## Triggering a run

Two ways, both wired in the target repo's caller workflow:

- **Apply the \`agent\` label** to an issue. Only logins in the repo's
  \`AGENT_ALLOWED_ACTORS\` variable (JSON array, set by \`agent-onboard.sh\` from
  \`--owner\` + \`--actors\`) may trigger this way.
- **Comment \`@bot …\` on an issue.** The commenter's \`author_association\` must
  be MEMBER, OWNER or COLLABORATOR — expression-checked, no API call needed.
  PR comments never trigger (\`issue.pull_request\` is set on those events).

The spec is the issue itself, **frozen at trigger time**: the workflow writes
\`github.event.issue.title\`/\`body\` from the event payload to \`.agent/task.md\`
and the phase prompts read only that file — an author editing the issue after
the trigger cannot change what the agent works on. The run also quotes the
frozen spec back in its acknowledgement comment, so the executed text is
visible in the issue timeline. If the issue names a Linear card (\`ENG-123\`),
the card is read as supplementary context and gets status comments; without
one the run is GitHub-only and the PR body uses \`Closes #N\` instead of
\`Fixes ENG-123\`.

The \`agent\` environment's required reviewer (set by \`agent-onboard.sh\` from
\`--owner\`) is the human-approval layer on top of both triggers.

## Phases and models

Each phase is its own \`opencode run\` against one session, so each can carry
its own model. Empty inputs fall back to \`model\`.

| Phase | Prompt | Model input | Gate after it |
|---|---|---|---|
| 1 plan | 01-plan.md | \`plan-model\` | \`.agent/plan.md\` exists; NEEDS-CLARIFICATION stops the run |
| 2 implement | 02-implement.md | \`implement-model\` | commits or working-tree changes exist |
| 3,5 review | 03-review.md | \`review-model\` | \`.agent/review-N.json\` exists and parses as an array |
| 4,6 fix | 04-fix.md | \`implement-model\` | next review cycle |
| 7 pr | 05-pr.md | \`pr-model\` | a PR exists on the branch |

All phases attach to one \`opencode serve\` so plugin and MCP cold boot is paid
once rather than seven times. The session id is created up front via
\`opencode api v2.session.create\` and threaded with \`--session\`; if that call
fails the run falls back to \`--continue\`, which is correct here but would be
ambiguous if anything else ran in the same workspace.

Callers pin \`@$TAG\`. To roll a change out everywhere: commit, then move the tag.

    git tag -f $TAG && git push -f origin $TAG

Current defaults: model \`$MODEL\`, opencode \`$OPENCODE_VERSION\`,
opencode-gbuild \`$GBUILD_VERSION\`, everything-cli ref \`$ECLI_REF\`.
A caller can override any of them per repo via the \`with:\` block.

## Fireworks notes

Provider id is \`fireworks-ai\` (not \`fireworks\`), env var
\`FIREWORKS_API_KEY\`, OpenAI-compatible at
\`https://api.fireworks.ai/inference/v1\`. Model ids are provider-qualified:
\`fireworks-ai/<slug>\` or \`fireworks-ai/accounts/fireworks/models/<name>\`.

Two things to watch, both specific to open-weight models behind an
OpenAI-compatible endpoint:

- **Multiple leading system messages.** Some open-model chat templates reject
  more than one, and this flow stacks a system prompt plus AGENTS.md plus skill
  instructions. Other harnesses coalesce consecutive system messages
  specifically for Fireworks-style hosts. If the first call 400s, that is why.
- **Tool-calling quality is the binding constraint.** The gbuild flow is
  tool-call heavy and dispatches subagents; a model that is strong at prose but
  loose with tool schemas will fail in ways that look like prompt bugs. Test
  the plan -> review -> pr chain on one throwaway card before switching models.

FireConnect (\`fireconnect opencode on\`) is the vendor's setup CLI, but it
rewrites \`~/.config/opencode/opencode.json\` and bakes the key in plaintext —
wrong shape for CI. This harness declares the provider itself instead.
MD

echo "scaffolded $DIR"

if [ "$CREATE_REPO" = 1 ]; then
  git init -q -b main
  git add -A
  git commit -qm "feat: agent harness (reusable workflows, opencode policy, prompts)"
  gh repo create "$REPO_NAME" "--$VISIBILITY" --source=. --push
  git tag "$TAG" && git push -f origin "$TAG"
  echo "pushed and tagged $TAG"
  if [ "$VISIBILITY" = "private" ]; then
    cat <<'NOTE'

! private harness: Settings -> Actions -> General -> Access must allow this
  repo's workflows to be used by other repositories, and the App must be
  installed here too so the run can clone it.
NOTE
  fi
else
  echo "next: git init && gh repo create $REPO_NAME --$VISIBILITY --source=. --push && git tag $TAG && git push origin $TAG"
fi
