# Self-hosting n8n locally

`setup-n8n.sh` bootstraps a local n8n instance with Postgres: generated secrets,
a compose file, a running stack, and optionally imported model credentials.

It is a self-hosting helper. It has nothing to do with the pnpm monorepo in this
repository — you do not need to clone, install or build anything to use it, and
the script only ever writes inside the install directory you give it.

## Quick start

```bash
scripts/self-host/setup-n8n.sh --dry-run          # see what it would write
scripts/self-host/setup-n8n.sh                    # set up in ~/n8n and start
scripts/self-host/setup-n8n.sh --dir ./n8n --port 8080
```

Then open <http://127.0.0.1:5678> and create the owner account — n8n has no
default login, the first account you create is the admin.

Requirements: Docker (or Docker Desktop) with the compose plugin, `openssl`,
`curl`, and bash. `doctor` checks all of it:

```bash
scripts/self-host/setup-n8n.sh doctor
```

## Commands

| Command | What it does |
|---|---|
| `setup` | Create `.env` + `docker-compose.yml`, pull, start, wait until `/healthz/readiness` answers. Default command. |
| `credentials` | Import `GEMINI_API_KEY` / `ANTHROPIC_API_KEY` as n8n credentials. |
| `status` | Containers, readiness, version, editor URL. |
| `backup` | `pg_dump` into `backups/`. Add `--include-key` to also copy the encryption key. |
| `restore FILE` | Restore a dump, then restart n8n. |
| `upgrade [TAG]` | Back up, pin a new image tag, pull, restart. |
| `down` | Stop the stack, keep data. `--volumes` deletes data (asks first). |
| `logs` | Follow the n8n container. |
| `doctor` | Read-only prerequisite and disk check. |

Options: `--dir`, `--port`, `--tag`, `--timezone`, `--dry-run`, `--no-start`,
`--with-credentials`, `--include-key`, `--force`, `-y`. Full text: `--help`.

## The encryption key is the whole backup

`N8N_ENCRYPTION_KEY` in `.env` encrypts every credential in the database. A
Postgres dump without that key restores your workflows but leaves every
credential undecryptable. The script refuses to invent a new key on re-run, and
`backup` says so every time.

Store the key in your password manager before you build anything you care about:

```bash
grep N8N_ENCRYPTION_KEY ~/n8n/.env
```

`backup --include-key` writes a copy next to the dump (`chmod 600`) so the two
cannot be separated by accident — move it into the password manager and delete
it from disk afterwards.

## What gets created

```
~/n8n/
├── .env                 # secrets, mode 600 — never commit this
├── docker-compose.yml   # no secrets; safe to copy
├── credentials.json     # only while staging keys before an owner exists
└── backups/
    ├── RESTORE.md
    └── n8n-<timestamp>.sql.gz
```

Re-running `setup` is safe: an existing `.env` is reused, so secrets never
rotate. An existing `docker-compose.yml` is left untouched unless you pass
`--force`.

## Credentials

API keys are separate products from chat subscriptions. A Claude Pro or Google
AI Plus/Pro plan does not include API access; those are metered and billed
separately.

- Gemini key: <https://aistudio.google.com> (free tier covers Flash-class models)
- Anthropic key: <https://console.anthropic.com> (prepaid credits)

Import them after the owner account exists:

```bash
GEMINI_API_KEY=... ANTHROPIC_API_KEY=... scripts/self-host/setup-n8n.sh credentials
```

Or use `--with-credentials` during setup and paste them at the hidden prompt.
Importing before an owner exists is not possible — n8n has no place to attach
them — so the script stages them in `credentials.json` and tells you to re-run.

## Deliberate defaults

- **Pinned image tag.** `--tag 2.33.0` by default; `upgrade` moves you on purpose.
- **Loopback-only port.** `127.0.0.1:5678`. Put a reverse proxy in front if it
  must be reachable from elsewhere; never publish 5678 directly.
- **Postgres, not SQLite.** Concurrent writes and pruning behave under load.
- **Pruning on.** `EXECUTIONS_DATA_MAX_AGE=336` hours; execution history is the
  usual cause of a bloated instance.
- **Diagnostics off.** `N8N_DIAGNOSTICS_ENABLED=false`.
- **`WEBHOOK_URL` commented out.** Set it once the instance is reachable, or
  webhooks silently point at `localhost`.

## Tests

The installer is tested against a fake `docker`, so no daemon is needed:

```bash
bash scripts/self-host/test/run-tests.sh
pnpm test:selfhost          # same thing
```

`test/fake-docker.sh` and `test/fake-curl.sh` are test doubles; they are not
used by the installer itself.
