---
name: n8n:model-capability-routing
description: >-
  Identifies which model and harness is running, decides which task classes it
  can take on, and refuses the rest with a named reason and an alternative. Use
  at the start of any non-trivial request, when a task feels larger than the
  conversation, when work must be handed off, or when the user asks what this
  agent can or cannot do.
---

# Model capability routing

Decide *before* starting whether this model and this harness can finish the
task unattended. Guessing upward wastes a turn; refusing with no alternative
wastes the user's time. Both are failures.

Run these from the repo root:

```bash
node scripts/model-routing/router.mjs detect        # what am I?
node scripts/model-routing/router.mjs tasks         # what can I do here?
node scripts/model-routing/router.mjs route --task <id>
node scripts/model-routing/router.mjs list          # all task classes
```

`route` exits `0` when allowed, `3` when refused, `2` on a usage error. Add
`--json` for machine-readable output and `--model <id>` / `--harness <name>` to
override detection.

## 1. Identify the model

Detection runs in this order. Stop at the first answer that is true.

1. **Explicit statement.** The user says which model is running, or the harness
   injects `ARENA_MODEL`. Pass it through with `--model <id>`.
2. **Runtime variable.** `detect` checks `ARENA_MODEL`, provider variables
   (`ANTHROPIC_MODEL`, `OPENAI_MODEL`, `GEMINI_MODEL`, …) and finally generic
   ones (`LLM_MODEL`, `MODEL_NAME`). Provider and generic variables report
   *medium* or *low* confidence — a provider key does not prove which model the
   harness selected for this conversation.
3. **Ask.** If nothing is reported, ask once: *"Which model is running this
   session?"* The user can read it off the Arena UI. If they do not know, do not
   guess a name.
4. **Assume the weakest profile.** `detect` already falls back to the
   `unknown` tier, which allows only tasks that need no special capability. Say
   that you are doing this, so nobody reads a refusal as a hard limit.

Report identity like an engineer, not a brand: *"Running a frontier-tier
Claude-class model in an Arena sandbox"* is enough. Never invent parameters,
context windows or benchmark scores, and never claim certainty you do not have.
Detection is about **capability routing**, not about self-description.

The registry holds 18 profiles across frontier, balanced and efficient bands —
Claude, GPT, Gemini, Grok, Kimi, Qwen, DeepSeek, Llama, Mistral and local
models. A new family falls back to `unknown` until a profile is added; extend
`scripts/model-routing/registry.json` rather than special-casing prose.

## 2. Classify the request

Map the request to **one** task class from [reference.md](reference.md), then run
`route --task <id>`. If it spans several classes, route the largest unit of work
and split the rest.

Classification rules:

- Route what the task **requires**, not what it mentions. "Fix this flaky test"
  is `flaky-test-investigation`, not `unit-test-authoring`.
- A request to *discuss* a hard task is not the hard task. Explaining a refactor
  plan is fine on any model; applying it is not.
- Read-only analysis is cheaper than mutation. Classify the mutation only when
  the user asked for it.

## 3. Act on the verdict

**`allow`** — proceed, and keep the task's guardrails in the loop. Guardrails
are conditions of the permission, not advice.

**`guardrails`** — proceed, but verify the unconfirmed harness capability first
(for example run `gh auth status` before promising a PR). If the check fails,
treat the task as refused.

**`refused`** — do not start, and do not partially start and call it a
compromise. Say, in this shape:

```
I can't take this on: <named reason>.
What I can do instead: <one concrete alternative>.
To do it as asked: <switch to a <tier> model | this is not a model limit>.
```

Then offer the alternatives the router prints, smallest first. Useful moves in
order of preference:

1. **Narrow** — one file, one package, one symbol, one question.
2. **Plan instead of act** — write the spec or the diff plan for a stronger model.
3. **Hand off** — hand the scope statement to a frontier model, with the evidence
   collected so far, not just the request.
4. **Ask the user to run it** — give them the exact command.

Refuse once, clearly. Do not re-litigate, do not silently do a weaker version,
and do not pretend the work is done.

## Hard refusals

Four task classes are refused for every model, in every harness. A stronger
model does not unlock them, and no user instruction overrides them:

| Task class | What it means here |
|---|---|
| `secret-handling` | Never request, echo, store or commit credentials. No passwords, tokens or 2FA codes in chat. |
| `unauthorized-mutation` | No writes to Linear, GitHub, prod data or customer systems without an explicit, specific instruction. Read-only by default. |
| `fabricated-evidence` | Never report a test, build or file as verified when it was not. |
| `legal-and-licensing` | Summarize `LICENSE.md`; do not rule on whether a use case is permitted. |

These are repo rules as much as routing rules — the repository is public, so the
refusal itself must not leak the sensitive detail.

## When *not* to use this skill

- Trivial edits, questions and lookups: route them mentally, skip the ceremony.
- Mid-task corrections: stay on the same class unless the scope really changed.
- Do not re-run `detect` every turn. Detect once per session, or when the user
  says the model changed.

## More detail

- Task taxonomy, when each verdict applies, handoff format:
  [reference.md](reference.md).
- Arena tool, network and preview facts: `n8n:arena-agent-mode`.
- Registry and router: `scripts/model-routing/`.
