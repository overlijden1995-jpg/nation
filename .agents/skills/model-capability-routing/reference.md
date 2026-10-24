# Model capability routing — reference

Detail for `n8n:model-capability-routing`. The registry in
`scripts/model-routing/registry.json` is the source of truth; this page explains
how to read it.

## Tiers

Routing uses capability bands, not model names. Names change every quarter;
the band a model sits in changes far more slowly.

| Tier | Rank | Means |
|---|---|---|
| `frontier` | 3 | Owns ambiguous, multi-step work unattended: architecture, multi-file refactors, root-cause, security review. |
| `balanced` | 2 | Reliable inside a clear boundary: a package, a known bug, a test file, a node. |
| `efficient` | 1 | Good for bounded, mechanical or text-only work. Needs a narrow ask and a checkable result. |
| `unknown` | 0 | Nothing was reported or recognised. Assume only zero-capability work. |

A task's `minTier` is the weakest band that reliably finishes it **unattended**.
A weaker model is not banned from understanding the problem — it is refused from
*owning* the change.

## Capabilities

Model flags (`requires`): `multiFileEdit`, `longHorizonPlanning`,
`deepReasoning`, `toolUse`, `codeExecution`, `longContext`, `vision`,
`structuredOutput`, `imageGeneration`.

Harness flags (`requiresHarness`): `webSearch`, `imageGeneration`,
`audioInput`, `shell`, `previewServer`, `githubWrite`, `gitPush`,
`browserAutomation`.

Harness flags are tri-state: `true`, `false`, or `"unknown"`. `"unknown"` never
blocks on its own — it downgrades the verdict to `guardrails` and asks the agent
to verify before promising. Only `false` refuses.

Separating the two matters: a Claude-class model in Arena can generate images
because the *harness* has the tool, not the model. When an image task fails, the
fix is a different harness capability, not a bigger model.

## Task taxonomy

| Task class | Min tier | Refused when | Typical suitable ask |
|---|---|---|---|
| `multi-file-refactor` | balanced | no multi-file editing or long-horizon planning | rename a config key across packages |
| `architecture-design` | frontier | shallow reasoning | decide where an execution hook belongs |
| `bug-root-cause` | balanced | cannot reason or execute | trace a stack frame into a shared boundary |
| `unit-test-authoring` | balanced | cannot run tests | regression test for a retry helper |
| `node-integration` | balanced | cannot edit several files | add an operation to an existing node |
| `db-migration` | balanced | no multi-file edit or execution | add a nullable column with a backfill |
| `security-review` | frontier | shallow reasoning, public-repo hygiene | authz pass over a diff before merge |
| `large-context-triage` | balanced | small context | cluster failing tests into causes |
| `visual-ui-review` | balanced | no vision | compare a component with the design system |
| `web-research` | — | harness has no web search | confirm a current provider API shape |
| `image-generation` | — | harness has no image tool | placeholder asset for docs |
| `audio-transcription` | — | harness cannot take audio | summarize a recorded walkthrough |
| `mechanical-bulk-edit` | — | cannot execute | apply one lint autofix everywhere |
| `commit-and-pr-text` | — | never (text only) | PR body from the diff |
| `translation-and-copy` | — | never (text only) | add a UI string across locales |
| `dependency-upgrade` | frontier | cannot hold a multi-step change | bump a major and fix the breakage |
| `flaky-test-investigation` | frontier | cannot hold a long horizon | find a race that fails 1 in 20 |
| `pr-merge` | — | harness cannot write to GitHub | merge #1234 after checks pass |
| `git-push` | — | harness cannot push | push the session branch, open a draft PR |
| `deterministic-computation` | — | never | convert a timestamp, sum a CSV column |
| `secret-handling` | hard refuse | always | explain env-var setup safely |
| `legal-and-licensing` | hard refuse | always | quote `LICENSE.md` and route to legal |
| `unauthorized-mutation` | hard refuse | always | draft the change and show the diff |
| `fabricated-evidence` | hard refuse | always | say the suite was not run, and why |

## Reading a verdict

`allow` means every requirement is met and the task's guardrails apply.

`guardrails` means the work is allowed but one harness capability is unverified.
Check it, then continue or downgrade to a refusal. Example: `pr-merge` in an
unknown harness — run `gh auth status` before agreeing to merge.

`refused` means at least one named requirement is missing. There are four
reason codes, and they lead to different next steps:

| Code | Meaning | Useful response |
|---|---|---|
| `hard-refuse` | Out of scope for every model | Explain the rule; offer the safe alternative. Never escalate. |
| `tier` | Model band too low for unattended ownership | Narrow the scope, plan instead of act, or hand off. |
| `model-capability` | Missing a specific ability (vision, long context) | Change the medium: read the DOM, grep the log, run a script. |
| `harness-capability` | The tool does not exist here | Change the environment or hand the command to the user. |

## Refusal quality bar

A good refusal is four sentences and ends with an action:

```
I can't take this on: it needs frontier-tier long-horizon work and this session
is running a balanced-tier model.
What I can do instead: split it per package, and I'll do the first one end to end.
To do it as asked: rerun this session on a frontier model with the scope above.
```

A bad refusal is one of these:

- **Apologetic and empty.** "I'm not sure I can do that well." — no named reason.
- **Silent degradation.** Doing a smaller version and presenting it as the ask.
- **Over-refusal.** Refusing low-risk work because the model name is unknown.
  If nothing is actually required, the router allows it; so should you.
- **Escape hatch.** Offering to "just try" a task with a missing hard requirement.
- **Identity guessing.** Inventing a model name, version or context window to
  justify the answer.

## Handoff packet

When handing work to a stronger model or a human, send evidence, not the raw
request:

```markdown
## Handoff
- Goal: <one sentence>
- Refused class: <task id> — <named missing requirement>
- Ruled out: <what was checked, with file:line or command output>
- Open questions: <what the next owner must confirm>
- Suggested next step: <one action>
```

## Extending the registry

A new model family, or a model that lands in the wrong band:

1. Add or edit a profile in `scripts/model-routing/registry.json`
   (`match` patterns, `tier`, `capabilities`).
2. Keep `match` specific — the longest literal run wins, so `*gpt-5-mini*`
   overrides `*gpt-5*` without ordering tricks.
3. Run `node scripts/model-routing/router.mjs check`.
4. Run `node --test scripts/model-routing/router.test.mjs`.
5. Update `reviewedAt`.

Do not add a profile for a model you have not used. A wrong tier is worse than
an honest `unknown`, because it makes refusals look authoritative when they are
not.
