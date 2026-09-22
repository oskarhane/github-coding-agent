# A Linear-triggered coding agent, on your own harness

Label a card. A few minutes later a pull request exists, reviewed by a
different model than wrote it, with CI already green or a bot already fixing
it. Comment on the PR to iterate. No new dashboard, no vendor's idea of how a
task should be worked.

The interesting part isn't the trigger — several products do that. It's that
the *workflow* is yours: your planning/review/PR skills, your CLI, your model
routing, your policy, versioned in one repo and rolled out by moving a tag.

---

## The flow

```
Linear card                    the spec lives here, in full
  ENG-123                      description, comments, attachments
      |
      |  you open a GitHub issue titled "ENG-123" and apply the `agent` label
      v
GitHub issue                   a pointer, not a copy
      |
      v
Actions runner
      |-- App token            PR author = your bot, and its PRs trigger CI
      |-- everything-cli       reads ENG-123 from Linear, writes back progress
      |-- opencode 2.x         + gbuild plugin, policy from the harness
      |
      |   plan -> implement -> review -> fix -> review -> pr
      |   kimi    deepseek      kimi      deepseek  kimi    kimi
      v
PR "Fixes ENG-123"             on branch agent/eng-123
      |
      |-- Linear PR automation moves the card to In Progress, then Done
      |-- CI fails? -> a second workflow fixes it, capped at 3 attempts
      |-- `/oc <instruction>` in a PR comment -> another turn on the same PR
```

One card, concretely: you write ENG-123 in Linear with a real description. You
open a GitHub issue whose title is just `ENG-123` and label it `agent`. The run
reads the Linear card, writes a plan with its assumptions stated, implements it
on `agent/eng-123`, hands the diff to a *different model* for review, fixes
what review found, reviews again, and opens a PR containing the plan's
assumptions and any unresolved findings. The card moves itself. If CI goes red
on that branch, a separate narrow workflow reads the failing job log and pushes
a fix commit — up to three times, then it stops and waits for you.

---

## Why not just buy it

All of these exist and work:

| Option | Why not here |
|---|---|
| Linear's own coding sessions | Runs Claude Code or Codex in Linear's sandbox. Good, but the workflow and the models are theirs. |
| Cursor / Devin / Copilot / Factory / Charlie | Same trade: assign an issue, get a PR, on their harness. |
| ElasticClaw, Optio, open-swe, Tembo | Self-hosted and close to this design — but built around their own agent runner. |

The reasons to build instead are specific, not ideological:

1. **The workflow is the product.** gbuild's plan → run → review → pr sequence
   with a read-only reviewer is the thing being iterated on. A hosted agent
   gives you a prompt box, not a pipeline you can restructure.
2. **Model routing across a provider of your choice.** Planning and review on a
   strong model, implementation on a cheap fast one, and — more important than
   the cost — review by a *different model family* than the implementer, so the
   reviewer doesn't share its blind spots.
3. **Your own tools reach the agent.** everything-cli gives it Linear access as
   a first-class CLI rather than through whatever integration a vendor shipped.
4. **No harness lock-in.** The whole system is two scripts, two reusable
   workflows and five prompt files. If opencode or Fireworks stops being the
   right answer, the wiring survives the swap.

---

## Architecture

**Two repos.** The harness defines *how* the agent works; target repos hold a
thin caller and nothing else.

```
agent-harness (public, tagged v1)          target repo
  .github/workflows/agent.yml        <---  .github/workflows/agent.yml  (6 lines)
  .github/workflows/agent-ci-fix.yml <---  .github/workflows/agent-ci-fix.yml
  opencode/opencode.jsonc                  label: agent
  opencode/agents/gbuild-reviewer.md       secrets x3, variables x2
  prompts/01-plan.md … 05-pr.md            environment: agent
  agent-onboard.sh                         (run it from a target repo clone)
```

Onboarding a repo is one script run — `agent-onboard.sh` ships in the harness
itself, so the harness clone is the only repo you need to fetch. Changing the
prompt, a model, or the opencode version for *every* repo is one commit plus
`git tag -f v1`.

**GitHub is the control plane; Linear is the spec.** The GitHub issue holds
only an identifier, so nothing about the card is duplicated. The agent reads
Linear directly. The reverse direction — status transitions — is free: the PR
body contains `Fixes ENG-123` and Linear's own PR automation does the rest, so
the agent never needs to know a workflow-state UUID.

**Credentials.** Three secrets per repo: the model provider key, a Linear API
key, and the GitHub App private key. The App matters for two reasons — the PR
is authored by a bot rather than by you, and an App-authored PR *triggers CI*,
which a `GITHUB_TOKEN`-authored one does not. Without that, "wait until the PR
is green" never starts.

**Policy wins over the repo.** Config comes from the harness via
`OPENCODE_CONFIG_DIR`, which loads after a project's own config and overrides
it, so no target repo can loosen the agent's permissions by committing an
`opencode.json`.

---

## Design decisions

| Decision | Why | What it costs |
|---|---|---|
| Trigger from GitHub, not a Linear webhook | Linear's webhook can't attach an auth header, so any Linear-side trigger needs a relay holding a token. GitHub's `issues: labeled` event carries a real human actor for free. | The card starts life in two places (one-way Issues Sync fixes this if you want it). |
| Seven `opencode run` phases, one session | Per-phase models, and a gate behind each phase. A failed plan cannot silently proceed to implementation. | Seven context loads; prompt caching is void at each model boundary. One `opencode serve` with `--attach` recovers most of the overhead. |
| Reviewer defined in config, not by the plugin | opencode plugins can't register agents, so gbuild inlines a brief into a generic subagent. A config-defined agent with `write: false, edit: false` is *structurally* unable to fix what it reviews. | One more thing to keep in sync with gbuild. |
| Review findings are a JSON file, not a claim | A verdict inside the transcript can't be checked from outside. A missing `review-N.json` proves the reviewer never ran — and an unreviewed PR otherwise looks exactly like a reviewed one. | The prompt has to specify a schema, and the model has to honour it. |
| Bounded loop, draft PR on failure | An unbounded implementer/reviewer pair is how you spend a day of tokens on a disagreement neither side concedes. | Work can land as a draft with known blocking findings — deliberately, and listed in the PR body. |
| CI-fix is a separate workflow with its own prompt | A red test must not be able to re-enter planning and rewrite the approach. | Two prompts to maintain. |
| Everything pinned: opencode, the plugin, the CLI ref, the harness tag | The agent's behaviour should change when you change it, not when an upstream publishes. | Manual bumps. |

---

## What it deliberately doesn't do

- **Merge.** Branch protection stays on; a bot can't satisfy CODEOWNERS anyway.
- **Ask questions.** The session is non-interactive. If a card is too vague for
  sound assumptions, the plan phase posts its questions to Linear and the run
  stops before touching code.
- **Edit its own triggers.** The App has no `workflows: write`, and the prompts
  forbid touching `.github/` and `.opencode/`.
- **Stream progress into Linear.** You get a comment with the run URL, the PR
  attached to the card, and the status transition. Native agent-session UI
  would mean running a Linear OAuth app — a later step, if it earns itself.

---

## Failure modes, and where each is caught

The useful property of the phased design is that the silent failures became
loud ones:

| Failure | Caught by |
|---|---|
| opencode 1.x installed → the V2 plugin never loads | version assertion before any phase runs |
| `subagent` denied or `subagent_depth: 1` → review no-ops | missing `review-N.json` fails the run |
| Vague card → confidently wrong PR | `NEEDS-CLARIFICATION` stops the run after planning |
| Implementer did nothing | no commits and no diff fails the gate |
| `GITHUB_TOKEN` used by mistake → CI never runs on the PR | PR author is visibly `github-actions[bot]` |
| Model silently reverted to the config default mid-session | `opencode stats --days 1 --models` at the end of every run |
| Infinite fix/review argument | cycle cap, then a draft PR |
| Flaky CI sends the agent back to planning | the CI-fix workflow's prompt is scoped to the failing checks only |

---

## Costs and blast radius

- Bound model spend at the provider with a capped key. `timeout-minutes`
  bounds wall clock, not tokens.
- The App token is reachable by the agent — it has a shell, and opening a PR
  needs `gh`. The mitigation is scope: one repo, ~1 hour, no workflow write,
  no merge.
- The Linear description becomes the agent's prompt. Fine while you write the
  cards; if others can, that's untrusted text reaching something that holds a
  repo-write token.
- Three gates on triggering: the caller's `if:` on the owner variable, the same
  check repeated inside the reusable workflow so a sloppy caller fails closed,
  and an environment requiring your approval.

---

## Where it goes next

- **Linear-side triggering**, if the GitHub pointer issue gets annoying:
  one-way Issues Sync mirrors pointer issues into a Linear team, several repos
  into one team.
- **Native Linear agent sessions**, for streaming progress and follow-ups in
  the card itself. Costs an OAuth app, a webhook endpoint and a 10-second ack
  requirement — worth it only once the rest is boring.
- **A real sandbox** instead of an Actions runner (E2B, Daytona, Modal, Fly) if
  runs start hitting the job limit or you want the agent running untrusted repo
  code under its own kernel.
- **Scoped Linear credentials** via OAuth instead of a personal API key, once
  more than one person can trigger it.
- **Parallel cards**, which mostly means giving each run its own branch and
  making the concurrency groups per-issue rather than per-repo — already true
  for the issue workflow.
