# Linear -> opencode -> PR agent: setup plan

Two repos. The **harness** defines how the agent works; **target repos** hold a
thin caller and nothing else. Prompt, policy and versions change in one place
and roll out by moving a tag.

```
GitHub issue (the spec, frozen at trigger time)
  title + body ..................... full description; may name a Linear card
       |
       |  you apply the `agent` label, or a member comments "@bot pick this up"
       v
target repo                     harness repo @v1
  .github/workflows/agent.yml ---> .github/workflows/agent.yml (workflow_call)
  (two triggers + `secrets: inherit`) opencode/opencode.jsonc   policy
                                      opencode/agents/          reviewer
                                      prompts/01..05 + ci-fix   the prompts
                                      agent-onboard.sh          per-repo onboarding
       |
       v
runner: App token -> .agent/task.md (frozen issue snapshot) -> opencode 2.x + gbuild
        -> branch agent/eng-123 (or agent/issue-42) -> PR "Fixes ENG-123" / "Closes #42"
       |
       v
Linear PR automation moves the card (if linked); the issue gets status comments
```

## Phase 1 — one-time, manual (~20 min)

Not scriptable: GitHub App creation has no API, and Linear keys and automations
are UI-only.

1. **GitHub App.** Settings -> Developer settings -> GitHub Apps -> New.
   Repository permissions:

   | Permission | Level | Why |
   |---|---|---|
   | Contents | write | push the branch |
   | Pull requests | write | open the PR |
   | Issues | write | comment, remove the trigger label |
   | Actions | read | the CI-fix loop reads failed job logs |
   | Workflows | **none** | the agent must not edit its own triggers |

   Generate a private key (.pem), note the App id, install on target repos.
   The App is what makes PRs bot-authored *and* still able to trigger
   `pull_request` workflows — `GITHUB_TOKEN`-authored PRs cannot, which would
   break the CI-green step silently.
2. **Linear API key.** Settings -> API -> Personal API keys. These are broadly
   privileged across the workspace; for a shared repo use everything-cli's
   OAuth account type for a narrower grant instead.
3. **Linear automations.** Team settings -> Workflows & automations: PR opened
   -> In Progress, PR merged -> Done. This is why the agent never needs
   `linear issue update` with state UUIDs, which the CLI cannot look up (it has
   no state-list command).
4. **Plugin version.** Pick the `opencode-gbuild` npm version. The
   `github:...#main::path:plugins/gbuild` form does not work — bun/npm cannot
   resolve that selector — so npm is the only coordinate.
5. **Fireworks key and model.** Create the key in the Fireworks console
   (`fw_...`), and pick a model. The provider id is `fireworks-ai`, the env var
   `FIREWORKS_API_KEY`, and model ids are provider-qualified:
   `fireworks-ai/<slug>` or
   `fireworks-ai/accounts/fireworks/models/<name>`. Pass it to
   `harness-init.sh --model`, plus `--small-model` for something cheap so title
   generation does not burn the coding model. opencode's documented setup is
   the interactive `/connect` flow and FireConnect bakes the key into
   `~/.config/opencode/opencode.json` in plaintext — neither suits CI, so the
   harness declares `provider.fireworks-ai` with `{env:FIREWORKS_API_KEY}`
   itself.

## Phase 2 — the harness, once

```sh
./harness-init.sh --dir ~/src/agent-harness --create-repo \
  --model            'fireworks-ai/accounts/fireworks/models/kimi-k3' \
  --implement-model  'fireworks-ai/accounts/fireworks/models/deepseek-4p1-flash' \
  --small-model      'fireworks-ai/<something-cheap>'
```

`--model` is the fallback for every phase, so plan, review and PR all land on
kimi-k3 and only implement/fix is overridden. `--plan-model`, `--review-model`
and `--pr-model` exist if you want to split them further later.

Keep it **public**: it holds no secrets, and public sidesteps both the
private-reusable-workflow access setting and needing a token to clone it from
inside a run. Then edit and tag:

```sh
cd ~/src/agent-harness
$EDITOR prompts/issue-task.md          # the part you will actually iterate on
git commit -am "..." && git tag -f v1 && git push -f origin v1
```

Note: `harness-init.sh` does not emit `agent-onboard.sh` — that script lives
in the harness repo directly (see Phase 3). If you ever re-scaffold into a
fresh directory, copy it back in before tagging.

## Phase 3 — per target repo, ~30 seconds each

The onboarding script ships in the harness repo, so the harness clone is the
only repo you need:

```sh
export FIREWORKS_API_KEY=... LINEAR_API_KEY=...
cd ~/src/some-repo
~/src/agent-harness/agent-onboard.sh --harness <you>/agent-harness --owner <you> \
  --app-id 123456 --app-key-file ~/keys/agent.pem \
  --ci-workflow "CI" --dry-run    # inspect, then rerun for real
```

Creates the `agent` label, three secrets, two variables, an `agent`
environment gated on your review, and commits two caller workflows. Re-runnable.
Add `--actors "alice,bob"` to let more logins trigger via the label; any
MEMBER/OWNER/COLLABORATOR can always trigger by commenting `@bot …` on an
issue, and PR comments never trigger.

| Lives in the target repo | Lives in the harness |
|---|---|
| `agent` label | prompts |
| `FIREWORKS_API_KEY`, `LINEAR_API_KEY`, `AGENT_APP_PRIVATE_KEY` | opencode policy + permissions |
| `AGENT_OWNER`, `AGENT_APP_ID` | reviewer agent definition |
| `agent` environment | opencode / gbuild / everything-cli versions |
| two caller workflows (~15 lines) | both job definitions |

## Phase 4 — smoke test before trusting it

Run a card you don't care about and check, in order:

| Check | A failure means |
|---|---|
| `opencode --version` is 2.x in the log | the gbuild V2 plugin never loaded |
| `.agent/plan.md` exists | gbuild-plan was skipped |
| `.agent/review-1.json` exists | **`subagent` blocked or `subagent_depth` too low** — the gate fails the run rather than letting an unreviewed PR through |
| `opencode stats --models` shows both models | a non-default model can revert to the agent default mid-session while the transcript still names the one you asked for, and both get billed |
| PR author is your App, not `github-actions[bot]` | token minting fell back |
| `pull_request` CI started on the PR | you're on a `GITHUB_TOKEN`; the CI-green loop will never fire |
| Card moved to In Progress | the `Fixes ENG-123` line or the team automation is missing |
| The first model call didn't 400 | some open-weight chat templates reject more than one leading system message, and this flow stacks a system prompt + AGENTS.md + skills |
| The review agent was actually dispatched | tool-calling quality is the binding constraint on Fireworks-hosted open models; a loose tool-schema follower fails in ways that look like prompt bugs |

The run uploads `.agent/` as an artifact either way, so a failed run is
inspectable without re-running it.

## Phases

Seven `opencode run` invocations against one session, each with its own model
and a gate behind it:

```
1 plan       plan-model       -> .agent/plan.md         gate: exists, not NEEDS-CLARIFICATION
2 implement  implement-model  -> commits on agent/<id>  gate: something changed
3 review     review-model     -> .agent/review-1.json   gate: file exists and is an array
4 fix        implement-model  -> commits                (loop back to review)
5 review     review-model     -> .agent/review-2.json   gate: same
6 fix        implement-model  -> commits                (max-cycles caps the loop)
7 pr         pr-model         -> PR "Fixes ENG-123"     gate: a PR exists
```

The loop exits early when a review cycle reports no open blocking or medium
findings. Blocking findings surviving `max-cycles` mark the PR draft rather
than failing the run — the work is still worth looking at.

Cross-family review is the point, not just the cost: kimi reviewing deepseek's
code doesn't share the implementer's blind spots. Note that switching models
mid-session voids prompt caching at each boundary, so token cost is not simply
"flash rates for the big phase".

## How config precedence is used

- `OPENCODE_CONFIG_DIR` -> `harness/opencode`. Loaded after project and
  `.opencode` config and able to override them, so a target repo's committed
  opencode config cannot loosen the agent's policy.
- `OPENCODE_DISABLE_PROJECT_CONFIG=1` -> belt and braces; present in the config
  loader but undocumented, harmless if ignored.
- `OPENCODE_CONFIG_CONTENT` -> per-run values only (model, plugin pin). Highest
  non-managed precedence. Note this originally did *not* beat
  `.opencode/opencode.json` despite the docs; it was fixed by moving the merge
  to the end of the load order — worth asserting on your pinned version.
- The **managed** config tier (`/etc/opencode`, MDM) is enterprise-only and not
  needed: you own the runner, and `CONFIG_DIR` already outranks the repo.

## Known-unverified

Confirm on the first run; all three fail loudly, not silently:

- the opencode installer honours `VERSION=`
- `everything-cli linear account add` takes the key non-interactively from
  `LINEAR_API_KEY` (the workflow pipes it as a fallback)
- `github.job_workflow_ref` parses into a clonable harness repo + ref on your
  setup (it is how the run pins config to the same tag as the workflow)
- `opencode api v2.session.create` returns an id under `.id` or `.sessionID`
  (the run falls back to `--continue` if not, which is correct here but
  ambiguous if anything else shares the workspace)
- `opencode serve` answers on `/api/session` within 60s, so the phases attach
  to one server instead of cold-booting plugins seven times

## Blast radius

- Bound model spend at the provider with a capped key. `timeout-minutes` bounds
  wall clock, not tokens.
- The App token is reachable by the agent — it has a shell and `gbuild-pr`
  needs `gh`. The mitigation is scope: one repo, ~1 hour, no workflow write,
  and branch protection so it cannot merge.
- The Linear description becomes the prompt. Fine while you write the cards; if
  others can, that is untrusted input reaching something with a repo-write
  token.
- Three gates on triggering: the caller's `if:` on `vars.AGENT_OWNER`, the same
  check repeated inside the reusable workflow so a sloppy caller fails closed,
  and the environment's required reviewer (needs a paid plan on private repos;
  the actor checks stand alone without it).
