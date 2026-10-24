#!/usr/bin/env bash
#
# setup-n8n.sh — bootstrap a local, self-hosted n8n with Postgres in one command.
#
# Creates an install directory containing .env (generated secrets), a
# docker-compose.yml, and a backups/ folder; starts the stack; waits until n8n
# reports ready; then optionally seeds API credentials so the first workflow has
# a model to talk to.
#
# This is a self-hosting helper. It is unrelated to the pnpm monorepo build in
# this repository — you do not need to clone or build anything to run it, and it
# never touches files outside the install directory.
#
# Usage: ./setup-n8n.sh [command] [options]
#   ./setup-n8n.sh --help
#
set -euo pipefail

PROG="$(basename "${BASH_SOURCE[0]}")"

# Pinned on purpose: a floating tag means an upgrade lands while you are asleep.
DEFAULT_TAG="2.33.0"
DEFAULT_PORT="5678"
READY_TIMEOUT_SECONDS="${N8N_READY_TIMEOUT:-180}"

CMD=""
TARGET_DIR="${N8N_SELFHOST_DIR:-$HOME/n8n}"
PORT=""
TAG=""
TIMEZONE=""
DRY_RUN="false"
ASSUME_YES="false"
FORCE="false"
NO_START="false"
INCLUDE_KEY="false"
WITH_CREDENTIALS="false"

# ── output helpers ────────────────────────────────────────────────────────────

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
	BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
	YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
	BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '\n%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok()    { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()   { printf '\n%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
note()  { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }

confirm() {
	local prompt="$1"
	if [ "$ASSUME_YES" = "true" ]; then return 0; fi
	[ -t 0 ] || return 1
	local reply=""
	printf '%s [y/N] ' "$prompt"
	read -r reply
	case "$reply" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<EOF
${BOLD}$PROG${RESET} — local self-hosted n8n (Docker + Postgres)

${BOLD}COMMANDS${RESET}
  setup          Create .env + docker-compose.yml, start, wait until ready. Default.
  credentials    Import GEMINI_API_KEY / ANTHROPIC_API_KEY into n8n as credentials.
  status         Show container state, readiness and version.
  backup         Dump the database to ./backups/ (read the restore warning).
  restore FILE   Restore a dump created by 'backup'.
  upgrade [TAG]  Back up, pin a new image tag, pull and restart.
  down           Stop the stack (data is kept). --volumes deletes it.
  logs           Follow the n8n container logs.
  doctor         Check prerequisites without changing anything.

${BOLD}OPTIONS${RESET}
  --dir PATH        Install directory (default: $TARGET_DIR)
  --port PORT       Host port (default: $DEFAULT_PORT)
  --tag VERSION     n8n image version (default: $DEFAULT_TAG)
  --timezone TZ     GENERIC_TIMEZONE (default: autodetected)
  --dry-run         Print the files that would be written; change nothing
  --no-start        Write the files but do not start the stack
  --with-credentials  Also seed credentials during setup (prompts, hidden input)
  --force           Overwrite an existing docker-compose.yml
  --include-key     In 'backup', also write the encryption key (chmod 600)
  -y, --yes         Do not ask for confirmation
  -h, --help        This text

${BOLD}EXAMPLES${RESET}
  $PROG                                   # set up in ~/n8n and start
  $PROG --dir ./n8n --port 8080           # somewhere else, different port
  $PROG --dry-run                         # see what it would write
  GEMINI_API_KEY=... $PROG --with-credentials
  $PROG backup --include-key              # after this: store the key somewhere safe
  $PROG upgrade 2.34.0                    # back up, then move to a new tag
EOF
}

# ── environment / docker plumbing ─────────────────────────────────────────────

# Compose v2 is a docker subcommand; older machines only have the v1 binary.
compose() {
	if docker compose version >/dev/null 2>&1; then
		docker compose "$@"
	else
		docker-compose "$@"
	fi
}

require_docker() {
	have docker || die "docker is not installed. Get Docker Desktop (macOS/Windows) or Docker Engine (Linux), then re-run."

	if ! docker info >/dev/null 2>&1; then
		die "the docker daemon is not reachable. Start Docker Desktop or 'sudo systemctl start docker', then re-run."
	fi

	if ! docker compose version >/dev/null 2>&1 && ! have docker-compose; then
		die "docker compose is not available. Install the compose plugin (docker-compose-plugin) and re-run."
	fi
}

require_openssl() {
	have openssl || die "openssl is required to generate secrets. Install it and re-run."
}

require_curl() {
	have curl || die "curl is required to check readiness. Install it and re-run."
}

env_file() { printf '%s/.env' "$TARGET_DIR"; }
compose_file() { printf '%s/docker-compose.yml' "$TARGET_DIR"; }
backup_dir() { printf '%s/backups' "$TARGET_DIR"; }

# Read KEY from .env without sourcing it, so a stray line cannot execute.
env_value() {
	local key="$1" file
	file="$(env_file)"
	[ -f "$file" ] || return 0
	grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2-
}

# Everything below reads its values from .env at runtime, so the same file works
# for setup, backup and restore.
load_settings() {
	local file
	file="$(env_file)"
	[ -f "$file" ] || die "no .env in ${TARGET_DIR}. Run '$PROG setup' first."

	DB_USER="$(env_value DB_USER)"
	DB_NAME="$(env_value DB_NAME)"
	LOCAL_PORT="$(env_value N8N_PORT)"
	LOCAL_TAG="$(env_value N8N_VERSION)"
	ENCRYPTION_KEY="$(env_value N8N_ENCRYPTION_KEY)"

	: "${DB_USER:=n8n}" "${DB_NAME:=n8n}" "${LOCAL_PORT:=$DEFAULT_PORT}"
	: "${LOCAL_TAG:=$DEFAULT_TAG}"
}

detect_timezone() {
	local tz=""
	if [ -n "${TZ:-}" ]; then tz="$TZ"
	elif [ -f /etc/timezone ]; then tz="$(tr -d '\n' < /etc/timezone)"
	elif have timedatectl; then tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
	elif [ -L /etc/localtime ]; then tz="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
	fi
	[ -n "$tz" ] || tz="UTC"
	printf '%s' "$tz"
}

port_in_use() {
	local port="$1"
	if have nc; then
		nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && return 0
		return 1
	fi
	(exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && return 0
	return 1
}

random_secret() { openssl rand -hex "${1:-32}"; }

# ── file templates ────────────────────────────────────────────────────────────

render_env() {
	local version="$1" port="$2" tz="$3" db_password="$4" enc_key="$5"
	cat <<EOF
# Generated by $PROG on $(date -u '+%Y-%m-%dT%H:%M:%SZ').
# This file holds secrets. Keep it out of version control (chmod 600).
N8N_VERSION=$version
N8N_PORT=$port
N8N_HOST=localhost
N8N_PROTOCOL=http
GENERIC_TIMEZONE=$tz
DB_USER=n8n
DB_NAME=n8n
DB_PASSWORD=$db_password
POSTGRES_PASSWORD=$db_password
N8N_ENCRYPTION_KEY=$enc_key
EOF
}

# Values come from .env via compose interpolation, so this file never holds a
# secret and is safe to copy between machines.
render_compose() {
	cat <<'YAML'
# Generated by setup-n8n.sh. Secrets live in .env, not here.
#
# The port is published on 127.0.0.1 only: keep it that way and put a reverse
# proxy in front if this ever needs to be reachable from another machine.
name: n8n

services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U ${DB_USER} -d ${DB_NAME}']
      interval: 10s
      timeout: 5s
      retries: 10
    # Not published. Only n8n reaches it, over the compose network.

  n8n:
    image: docker.n8n.io/n8nio/n8n:${N8N_VERSION}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - '127.0.0.1:${N8N_PORT}:5678'
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${DB_NAME}
      DB_POSTGRESDB_USER: ${DB_USER}
      DB_POSTGRESDB_PASSWORD: ${DB_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: 5678
      N8N_PROTOCOL: ${N8N_PROTOCOL}
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      TZ: ${GENERIC_TIMEZONE}
      N8N_DIAGNOSTICS_ENABLED: 'false'
      N8N_VERSION_NOTIFICATIONS_ENABLED: 'false'
      EXECUTIONS_DATA_PRUNE: 'true'
      EXECUTIONS_DATA_MAX_AGE: '336'
      N8N_RUNNERS_ENABLED: 'true'
      # Uncomment once n8n is reachable from outside this machine, or webhooks
      # will silently point at localhost:
      # WEBHOOK_URL: https://n8n.example.com/
    volumes:
      - n8n_data:/home/node/.n8n
    healthcheck:
      test:
        - 'CMD-SHELL'
        - 'wget --no-verbose --tries=1 --spider http://127.0.0.1:5678/healthz || exit 1'
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 60s

volumes:
  pgdata:
  n8n_data:
YAML
}

render_restore_readme() {
	cat <<'EOF'
# Restoring this backup

1. You need BOTH files, or this backup is worthless:
   - the .sql.gz dump in this directory
   - the value of N8N_ENCRYPTION_KEY from the .env of the instance that made it

   Without the original key, n8n cannot decrypt the credentials stored in the
   dump. They come back as unreadable blobs and must be re-entered by hand.

2. Restore into the same install directory:

     ./setup-n8n.sh restore backups/<file>.sql.gz

3. If the key changed, put the original back into .env first:

     N8N_ENCRYPTION_KEY=<original value>

   Then restart: ./setup-n8n.sh down && ./setup-n8n.sh setup
EOF
}

# ── commands ──────────────────────────────────────────────────────────────────

cmd_setup() {
	require_openssl
	if [ "$DRY_RUN" != "true" ]; then require_docker; fi

	local version="${TAG:-$DEFAULT_TAG}"
	local port="${PORT:-$DEFAULT_PORT}"
	local tz="${TIMEZONE:-$(detect_timezone)}"
	local env_path compose_path
	env_path="$(env_file)"
	compose_path="$(compose_file)"

	step "Preparing $TARGET_DIR"

	if [ "$DRY_RUN" = "true" ]; then
		local db_password enc_key
		db_password="$(random_secret 24)"
		enc_key="$(random_secret 32)"
		info ""
		info "${BOLD}--- .env (secrets would be generated) ---${RESET}"
		render_env "$version" "$port" "$tz" "$db_password" "$enc_key"
		info ""
		info "${BOLD}--- docker-compose.yml ---${RESET}"
		render_compose
		info ""
		step "Dry run: nothing was written, nothing was started."
		note "Re-run without --dry-run to create $TARGET_DIR."
		return 0
	fi

	mkdir -p "$TARGET_DIR" "$(backup_dir)"

	if [ -f "$env_path" ]; then
		ok ".env exists — reusing the existing secrets"
		load_settings
	else
		[ -n "${PORT:-}" ] || port="$DEFAULT_PORT"
		if port_in_use "$port"; then
			die "port $port is already in use. Pick another with --port."
		fi
		(umask 077 && render_env "$version" "$port" "$tz" "$(random_secret 24)" "$(random_secret 32)" >"$env_path")
		chmod 600 "$env_path"
		ok "generated .env (secrets, mode 600)"
		note "N8N_ENCRYPTION_KEY is in $env_path — back it up, it is unrecoverable"
		load_settings
	fi

	if [ -f "$compose_path" ]; then
		if [ "$FORCE" != "true" ]; then
			ok "docker-compose.yml exists — leaving it alone (use --force to replace)"
		else
			render_compose >"$compose_path"
			ok "replaced docker-compose.yml (--force)"
		fi
	else
		render_compose >"$compose_path"
		ok "wrote docker-compose.yml"
	fi

	[ -f "$(backup_dir)/RESTORE.md" ] || render_restore_readme >"$(backup_dir)/RESTORE.md"

	step "Validating compose file"
	compose --project-directory "$TARGET_DIR" -f "$compose_path" config >/dev/null \
		|| die "docker compose rejected the generated file. Check $compose_path."
	ok "compose file is valid"

	if [ "$NO_START" = "true" ]; then
		step "Files written; --no-start given, not starting."
		print_next_steps
		return 0
	fi

	step "Starting n8n"
	compose --project-directory "$TARGET_DIR" -f "$compose_path" up -d
	wait_ready

	if [ "$WITH_CREDENTIALS" = "true" ]; then
		cmd_credentials
	fi

	print_next_steps
}

wait_ready() {
	require_curl
	local port deadline elapsed
	port="$(env_value N8N_PORT)"
	port="${port:-$DEFAULT_PORT}"
	deadline=$((SECONDS + READY_TIMEOUT_SECONDS))

	printf '  waiting for n8n on http://127.0.0.1:%s ' "$port"
	while [ "$SECONDS" -lt "$deadline" ]; do
		if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${port}/healthz/readiness" 2>/dev/null; then
			printf '\n'
			ok "n8n is ready"
			return 0
		fi
		printf '.'
		sleep 3
	done
	printf '\n'
	elapsed=$((SECONDS))
	warn "not ready after ${elapsed}s; last 40 log lines:"
	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" logs --tail=40 n8n >&2 || true
	die "n8n did not become ready. Fix the cause above, then run '$PROG status'."
}

owner_count() {
	# The first account created in the UI is the owner. Imports need one.
	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" \
		exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" -tAc 'SELECT count(*) FROM "user";' 2>/dev/null |
		tr -d '[:space:]'
}

json_escape() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '%s' "$value"
}

prompt_secret() {
	local label="$1" value=""
	if [ ! -t 0 ]; then return 0; fi
	printf '  %s (hidden, Enter to skip): ' "$label"
	read -r -s value
	printf '\n'
	printf '%s' "$value"
}

cmd_credentials() {
	load_settings
	require_docker

	local gemini="${GEMINI_API_KEY:-}"
	local anthropic="${ANTHROPIC_API_KEY:-}"

	if [ -z "$gemini" ] && [ -z "$anthropic" ]; then
		step "Seeding provider credentials"
		note "No GEMINI_API_KEY or ANTHROPIC_API_KEY in the environment."
		gemini="$(prompt_secret 'Google Gemini API key')"
		anthropic="$(prompt_secret 'Anthropic API key')"
	fi

	if [ -z "$gemini" ] && [ -z "$anthropic" ]; then
		warn "no keys given; nothing to import"
		note "Add them later in the n8n UI (Credentials → New), or re-run with"
		note "GEMINI_API_KEY=... ANTHROPIC_API_KEY=... $PROG credentials"
		return 0
	fi

	local payload="["
	local sep=""
	if [ -n "$gemini" ]; then
		payload+="${sep}{\"name\":\"Google Gemini\",\"type\":\"googlePalmApi\",\"data\":{\"host\":\"https://generativelanguage.googleapis.com\",\"apiKey\":\"$(json_escape "$gemini")\"}}"
		sep=","
	fi
	if [ -n "$anthropic" ]; then
		payload+="${sep}{\"name\":\"Anthropic\",\"type\":\"anthropicApi\",\"data\":{\"apiKey\":\"$(json_escape "$anthropic")\"}}"
		sep=","
	fi
	payload+="]"

	local creds_path="$TARGET_DIR/credentials.json"
	(umask 077 && printf '%s\n' "$payload" >"$creds_path")
	chmod 600 "$creds_path"

	local owners
	owners="$(owner_count)"
	if [ "${owners:-0}" = "0" ]; then
		step "Credentials staged (owner account needed first)"
		note "Written to $creds_path (mode 600)."
		note "Create the owner account in the UI, then run: $PROG credentials"
		return 0
	fi

	step "Importing credentials into n8n"
	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" \
		cp "$creds_path" n8n:/tmp/credentials.json >/dev/null
	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" \
		exec -T n8n n8n import:credentials --input=/tmp/credentials.json
	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" \
		exec -T n8n rm -f /tmp/credentials.json >/dev/null 2>&1 || true
	rm -f "$creds_path"
	ok "credentials imported — they now appear under Credentials in the UI"
}

cmd_status() {
	load_settings
	require_docker

	step "Stack in $TARGET_DIR"
	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" ps

	local port ready="no"
	port="${LOCAL_PORT:-$DEFAULT_PORT}"
	if have curl && curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${port}/healthz/readiness" 2>/dev/null; then
		ready="yes"
	fi

	step "Runtime"
	printf '  %-14s %s\n' "version" "${LOCAL_TAG:-unknown}"
	printf '  %-14s %s\n' "editor" "http://127.0.0.1:${port}"
	printf '  %-14s %s\n' "ready" "$ready"
	printf '  %-14s %s\n' "backups" "$(backup_dir)"
	printf '  %-14s %s\n' "install dir" "$TARGET_DIR"
	if [ "$ready" = "no" ]; then
		note "Not ready yet, or the port differs. Try: $PROG logs"
	fi
}

cmd_backup() {
	load_settings
	require_docker
	mkdir -p "$(backup_dir)"

	local stamp out suffix counter
	stamp="$(date -u '+%Y%m%d-%H%M%S')"
	out="$(backup_dir)/n8n-${stamp}.sql.gz"
	# Timestamps are second-granular, so two backups in one second would
	# otherwise overwrite each other.
	counter=1
	while [ -e "$out" ]; do
		suffix="-${counter}"
		out="$(backup_dir)/n8n-${stamp}${suffix}.sql.gz"
		counter=$((counter + 1))
	done

	step "Backing up the database"
	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" \
		exec -T postgres pg_dump -U "$DB_USER" -d "$DB_NAME" | gzip >"$out"
	ok "wrote $(basename "$out") ($(du -h "$out" | cut -f1))"

	if [ "$INCLUDE_KEY" = "true" ]; then
		local keyfile
		keyfile="$(backup_dir)/encryption-key-${stamp}.txt"
		(umask 077 && printf '%s\n' "$ENCRYPTION_KEY" >"$keyfile")
		chmod 600 "$keyfile"
		warn "wrote $(basename "$keyfile") — a copy of the key now sits next to the dump"
		note "Move it somewhere safe (password manager), then delete it from here."
	fi

	step "Reminder"
	note "This dump is useless without N8N_ENCRYPTION_KEY from $TARGET_DIR/.env."
	note "Restore with: $PROG restore $(basename "$out")"
}

cmd_restore() {
	local dump="${1:-}"
	[ -n "$dump" ] || die "usage: $PROG restore <file.sql.gz>"
	[ -f "$dump" ] || dump="$TARGET_DIR/$dump"
	[ -f "$dump" ] || die "no such backup: $dump"

	load_settings
	require_docker

	step "Restoring $(basename "$dump")"
	warn "this overwrites the current database in $TARGET_DIR"
	confirm "Continue?" || die "cancelled"

	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" stop n8n
	gunzip -c "$dump" | compose --project-directory "$TARGET_DIR" -f "$(compose_file)" \
		exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" >/dev/null
	ok "database restored"

	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" up -d
	wait_ready
	ok "n8n restarted"
	note "If credentials look broken, N8N_ENCRYPTION_KEY does not match the dump's instance."
}

cmd_upgrade() {
	local new_tag="${1:-${TAG:-}}"
	[ -n "$new_tag" ] || die "usage: $PROG upgrade <version>   (e.g. $PROG upgrade 2.34.0)"

	load_settings
	require_docker

	step "Upgrading $LOCAL_TAG → $new_tag"

	cmd_backup

	local env_path
	env_path="$(env_file)"
	local tmp
	tmp="$(mktemp)"
	sed "s|^N8N_VERSION=.*|N8N_VERSION=${new_tag}|" "$env_path" >"$tmp"
	mv "$tmp" "$env_path"
	chmod 600 "$env_path"
	ok "pinned N8N_VERSION=${new_tag} in .env"

	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" pull
	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" up -d
	wait_ready
	ok "now running $new_tag (migrations ran on boot)"
	note "Roll back with: $PROG upgrade ${LOCAL_TAG}"
}

cmd_down() {
	load_settings
	require_docker

	if [ "${DELETE_VOLUMES:-false}" = "true" ]; then
		warn "this deletes the Postgres data AND the n8n volume (credentials, history)"
		confirm "Delete all data in $TARGET_DIR?" || die "cancelled"
		compose --project-directory "$TARGET_DIR" -f "$(compose_file)" down --volumes
		ok "stack and volumes removed; .env kept"
	else
		compose --project-directory "$TARGET_DIR" -f "$(compose_file)" down
		ok "stopped; data kept. Start again with: $PROG setup"
	fi
}

cmd_logs() {
	load_settings
	require_docker
	compose --project-directory "$TARGET_DIR" -f "$(compose_file)" logs -f n8n
}

cmd_doctor() {
	step "Checking prerequisites"

	if have docker; then ok "docker found: $(docker --version 2>/dev/null | head -1)"
	else warn "docker missing — needed to run anything"; fi

	if have docker && docker info >/dev/null 2>&1; then ok "docker daemon is running"
	else warn "docker daemon not reachable — start Docker Desktop / docker service"; fi

	if docker compose version >/dev/null 2>&1; then
		ok "compose: $(docker compose version --short 2>/dev/null)"
	elif have docker-compose; then ok "compose v1 (docker-compose) — consider upgrading"
	else warn "docker compose missing"; fi

	if have openssl; then ok "openssl found"; else warn "openssl missing — secrets cannot be generated"; fi
	if have curl; then ok "curl found"; else warn "curl missing — readiness check impossible"; fi

	local port="${PORT:-$DEFAULT_PORT}"
	if port_in_use "$port"; then
		warn "port $port is in use${PORT:+ (chosen via --port)}"
		note "another instance may be running, or choose --port"
	else
		ok "port $port is free"
	fi

	if [ -d "$TARGET_DIR" ]; then
		ok "install directory exists: $TARGET_DIR"
		if [ -f "$(env_file)" ]; then ok ".env present"; else note "no .env yet — setup will create one"; fi
		if [ -f "$(compose_file)" ]; then ok "docker-compose.yml present"; else note "no compose file yet"; fi
	else
		note "install directory does not exist yet: $TARGET_DIR"
	fi

	local free_kb
	free_kb="$(df -Pk "$(dirname "$TARGET_DIR")" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
	if [ -n "${free_kb:-}" ]; then
		if [ "$free_kb" -lt 2097152 ]; then
			warn "less than 2 GB free where $TARGET_DIR would live"
		else
			ok "$((free_kb / 1024 / 1024)) GB free for images and data"
		fi
	fi

	step "Doctor finished — warnings above are the things to fix."
}

print_next_steps() {
	local port
	port="$(env_value N8N_PORT)"
	port="${port:-$DEFAULT_PORT}"

	step "Next steps"
	cat <<EOF
  1. Open ${BOLD}http://127.0.0.1:${port}${RESET} and create the owner account.
     There is no default login: the first account you create is the admin.

  2. Back up the encryption key now — it is the only copy, and without it
     database backups cannot decrypt your credentials:

       ${DIM}grep N8N_ENCRYPTION_KEY $(env_file)${RESET}
       ${DIM}$PROG backup --include-key   # writes a copy next to the dump${RESET}

  3. Add model credentials (Credentials → New):
       Gemini  → "Google Gemini(PaLM) Api"   key from aistudio.google.com
       Claude  → "Anthropic"                 key from console.anthropic.com

     Or seed them in one shot, after step 1:

       ${DIM}GEMINI_API_KEY=... ANTHROPIC_API_KEY=... $PROG credentials${RESET}

     A Claude Pro / Google AI Plus subscription does not include API access;
     these keys are separate, metered products.

  4. Make it survive you: set an Error Workflow in Settings, and read
     $(backup_dir)/RESTORE.md before you need it.

  ${DIM}Status:  $PROG status${RESET}
  ${DIM}Logs:    $PROG logs${RESET}
  ${DIM}Stop:    $PROG down${RESET}
EOF
	step "Install directory: $TARGET_DIR"
}

# ── argument parsing ──────────────────────────────────────────────────────────

main() {
	local positional=()

	while [ $# -gt 0 ]; do
		case "$1" in
			-h | --help) usage; exit 0 ;;
			--version) printf '%s\n' "$DEFAULT_TAG"; exit 0 ;;
			--dir) TARGET_DIR="${2:?--dir needs a value}"; shift 2 ;;
			--dir=*) TARGET_DIR="${1#*=}"; shift ;;
			--port) PORT="${2:?--port needs a value}"; shift 2 ;;
			--port=*) PORT="${1#*=}"; shift ;;
			--tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
			--tag=*) TAG="${1#*=}"; shift ;;
			--timezone) TIMEZONE="${2:?--timezone needs a value}"; shift 2 ;;
			--timezone=*) TIMEZONE="${1#*=}"; shift ;;
			--dry-run) DRY_RUN="true"; shift ;;
			--no-start) NO_START="true"; shift ;;
			--with-credentials) WITH_CREDENTIALS="true"; shift ;;
			--include-key) INCLUDE_KEY="true"; shift ;;
			--force) FORCE="true"; shift ;;
			--volumes) DELETE_VOLUMES="true"; shift ;;
			-y | --yes) ASSUME_YES="true"; shift ;;
			--) shift; while [ $# -gt 0 ]; do positional+=("$1"); shift; done ;;
			-*) die "unknown option: $1 (see --help)" ;;
			*) positional+=("$1"); shift ;;
		esac
	done

	[ "${#positional[@]}" -gt 0 ] && CMD="${positional[0]}"
	TARGET_DIR="${TARGET_DIR/#\~/$HOME}"

	# Allow "upgrade 2.34.0" and "restore file.sql.gz" to pass their argument.
	local rest=()
	if [ "${#positional[@]}" -gt 1 ]; then
		rest=("${positional[@]:1}")
	fi

	case "${CMD:-setup}" in
		setup) cmd_setup ;;
		credentials | creds) cmd_credentials ;;
		status | ps) cmd_status ;;
		backup | dump) cmd_backup ;;
		restore) cmd_restore "${rest[0]:-}" ;;
		upgrade) cmd_upgrade "${rest[0]:-}" ;;
		down | stop) cmd_down ;;
		logs) cmd_logs ;;
		doctor | check) cmd_doctor ;;
		help) usage ;;
		*) die "unknown command: $CMD (see --help)" ;;
	esac
}

main "$@"
