---
name: n8n:arena-agent-mode
description: >-
  Operating rules for running this repository inside an Arena agent sandbox:
  session startup, network allowlist, long-running servers and live previews,
  artifact capture, and branch/PR handling. Use when the task involves running
  or previewing the app, installing dependencies, starting servers, or creating
  branches, commits, pushes and pull requests from an agent session.
---

# Arena agent mode

**Availability check.** Apply this skill only when the environment looks like an
Arena sandbox — `E2B_SANDBOX_ID`, `ARENA_SESSION_ID` or
`node scripts/model-routing/router.mjs detect --json` reporting
`"harness": "arena"`. If none of that is true, skip this skill and use the
harness's own rules; nothing here is required for a normal local checkout.

This repo is checked out into a disposable sandbox. The user sees your file
changes and any server you expose, but they are not browsing from the sandbox —
their browser runs on Arena's side of the proxy.

## Session start

Do these once, in order, before planning work:

1. **Identify the model.** Follow `n8n:model-capability-routing`. Run
   `node scripts/model-routing/router.mjs detect`. If nothing is reported, ask
   which model is running instead of guessing. Record the answer for the session.
2. **Identify the harness.** Arena sets `E2B_SANDBOX_ID`; the router reports
   `arena` automatically. That means `shell`, `gitPush`, `githubWrite`,
   `webSearch` and `imageGeneration` are available; `browserAutomation` is not
   guaranteed.
3. **Read the branch.** You are on an Arena session branch. Do not create,
   rename or switch branches. Earlier branches mentioned in the conversation are
   history, not the current state.
4. **Check the repo baseline.** `node -v` (needs `>=22.22`), then reuse the
   existing `node_modules` if present. `pnpm install` is slow here; only run it
   when dependencies actually changed.

## Network

Outbound access is limited to `github.com`, `codeload.github.com`,
`api.github.com`, `registry.npmjs.org`, `pypi.org` and
`files.pythonhosted.org`.

Consequences for routing:

- `git`, `gh`, `npm`/`pnpm` registry fetches and PyPI installs work.
- Anything else — arbitrary APIs, provider documentation, Hugging Face, Docker
  Hub, CDNs — may fail. Try it; if it fails, say which host was unreachable and
  offer an offline path instead of retrying.
- A task that requires fetching from a blocked host is a `harness-capability`
  refusal: give the user the command or ask them to paste the content.

## Processes and live previews

`bash` has a short timeout and is not for anything that must keep running. Use
the process tools for dev servers, watchers and test runs that outlive one call.

Rules that keep a preview from breaking:

- Bind to `0.0.0.0`, never `127.0.0.1` — the proxy cannot reach a loopback bind.
- Allow the preview host/origin. Vite needs `host: '0.0.0.0'` and, if it checks
  origins, `server.allowedHosts` covering `*.e2b.app`.
- Browser-side code must never call `localhost` or `127.0.0.1` — that resolves
  on the user's machine, not here. Use relative URLs and let the dev server
  proxy to the backend, or configure the dev server's `proxy` block.
- Fix a reported preview warning in the same turn and restart. A preview that
  half-loads is worse than no preview.

For n8n locally: `pnpm dev:be` for the API and `pnpm dev:fe:editor` for the
editor, or `pnpm dev` for both. The editor expects the backend on port 5678.

## Artifacts

- Files under the workspace root persist and are captured; anything written
  outside it is lost.
- `node_modules`, `dist`, `build`, `coverage`, `.turbo`, `.next`, `.cache` and
  similar directories are excluded from snapshots. Never put a deliverable there.
- Keep generated data, screenshots and large logs out of Git unless the repo
  already tracks that kind of file. Stream long output to a gitignored file
  (`.agent-setup/`, `*.log`) and read the tail.
- Surface the finished deliverable in whatever viewer the harness has, and name
  the files in the reply; do not leave the user to hunt for it in a tree.

## Git and GitHub

- Commit to the current session branch only; push with
  `git push origin <session-branch>`.
- Open PRs from that branch, as drafts unless told otherwise, following
  `.github/pull_request_template.md` and the title conventions.
- `gh` and `git` are authenticated. If either returns an authentication error,
  stop and tell the user the GitHub connection needs attention — do not ask for
  a password, token or 2FA code, and never write one into the repo.
- Merge or close with an explicit PR number:
  `gh pr merge 1234 --squash` / `gh pr close 1234`. The merge command must be the
  last command in the chain so its exit code survives; never use `--auto`.
- Public-repo hygiene still applies: no customer names, no vulnerability vectors
  in branch names, commit messages, PR titles, tests or comments.

## What Arena cannot do for you

- No interactive terminal, GUI browser or credential prompt. A task that needs
  one is refused (`harness-capability`) and handed back as instructions.
- No persistent daemon between turns: treat every background process as gone
  unless the process tool still reports it.
- No access to production n8n, Linear write access or customer environments
  beyond what the connected app tools expose. Default to read-only.

## Related

- Model and task routing: `n8n:model-capability-routing`.
- Build, test and lint conventions: `AGENTS.md` and `n8n:conventions`.
