#!/usr/bin/env bash
#
# Exercises setup-n8n.sh end to end against a fake docker CLI, so the installer
# can be tested without a daemon, images or network.
#
# Run: bash scripts/self-host/test/run-tests.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../setup-n8n.sh"
WORK="$(mktemp -d)"
SHIM_BIN="$WORK/bin"
STATE="$WORK/state"
OUT="$WORK/out.txt"
ERR="$WORK/err.txt"
STATUS=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$SHIM_BIN" "$STATE"
cp "$HERE/fake-docker.sh" "$SHIM_BIN/docker"
cp "$HERE/fake-curl.sh" "$SHIM_BIN/curl"
chmod +x "$SHIM_BIN/docker" "$SHIM_BIN/curl"

export PATH="$SHIM_BIN:$PATH"
export FAKE_DOCKER_STATE="$STATE"
export N8N_READY_TIMEOUT=10
export NO_COLOR=1

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL  %s\n' "$1"
	[ -n "${2:-}" ] && printf '        %s\n' "$2"
	return 0
}

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label" "expected [$expected], got [$actual]"; fi
}

assert_contains() {
	local label="$1" needle="$2" file="${3:-$OUT}"
	if grep -qF -- "$needle" "$file" 2>/dev/null; then pass "$label"; else fail "$label" "missing [$needle] in $(basename "$file")"; fi
}

assert_not_contains() {
	local label="$1" needle="$2" file="${3:-$OUT}"
	if grep -qF -- "$needle" "$file" 2>/dev/null; then fail "$label" "unexpected [$needle] in $(basename "$file")"; else pass "$label"; fi
}

assert_file() {
	if [ -f "$1" ]; then pass "$2"; else fail "$2" "no such file: $1"; fi
}

assert_absent() {
	if [ -e "$1" ]; then fail "$2" "unexpectedly exists: $1"; else pass "$2"; fi
}

assert_mode() {
	local actual
	actual="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)"
	if [ "$actual" = "$2" ]; then pass "$3"; else fail "$3" "mode $actual, expected $2"; fi
}

run_script() {
	: >"$OUT"
	: >"$ERR"
	bash "$SCRIPT" "$@" >"$OUT" 2>"$ERR"
	STATUS=$?
}

# ── tests ─────────────────────────────────────────────────────────────────────

test_help() {
	echo "help and argument handling"
	run_script --help
	assert_eq "help exits 0" "0" "$STATUS"
	assert_contains "help lists commands" "credentials" "$OUT"

	run_script bogus-command
	if [ "$STATUS" -ne 0 ]; then pass "unknown command fails"; else fail "unknown command fails"; fi
	assert_contains "unknown command explains itself" "unknown command" "$ERR"

	run_script --nonsense
	if [ "$STATUS" -ne 0 ]; then pass "unknown flag fails"; else fail "unknown flag fails"; fi
}

test_dry_run() {
	echo "dry run"
	local dir="$WORK/dry"
	run_script setup --dir "$dir" --dry-run --timezone UTC
	assert_eq "dry run exits 0" "0" "$STATUS"
	assert_contains "dry run prints env" "N8N_ENCRYPTION_KEY=" "$OUT"
	assert_contains "dry run prints compose" "docker.n8n.io/n8nio/n8n" "$OUT"
	assert_contains "dry run says nothing happened" "Dry run" "$OUT"
	assert_absent "$dir" "dry run creates no directory"
}

test_setup() {
	echo "setup"
	DIR="$WORK/install"
	run_script setup --dir "$DIR" --port 5899 --timezone America/Toronto
	assert_eq "setup exits 0" "0" "$STATUS"
	assert_contains "reports ready" "n8n is ready" "$OUT"
	assert_file "$DIR/.env" ".env written"
	assert_file "$DIR/docker-compose.yml" "compose written"
	assert_file "$DIR/backups/RESTORE.md" "restore notes written"
	assert_mode "$DIR/.env" "600" ".env is mode 600"
	# shellcheck disable=SC2016 # asserting the literal placeholder text
	assert_contains "compose interpolates secrets" '${N8N_ENCRYPTION_KEY}' "$DIR/docker-compose.yml"
	assert_not_contains "compose holds no secret" "$(env_key)" "$DIR/docker-compose.yml"
	assert_contains "port is loopback-only" "127.0.0.1:" "$DIR/docker-compose.yml"
	assert_contains "timezone respected" "GENERIC_TIMEZONE=America/Toronto" "$DIR/.env"

	local key
	key="$(env_key)"
	assert_eq "encryption key is 64 hex chars" "64" "${#key}"

	# The one thing that must never happen twice: a new encryption key.
	run_script setup --dir "$DIR"
	assert_eq "re-run exits 0" "0" "$STATUS"
	assert_eq "re-run keeps the encryption key" "$key" "$(env_key)"
	assert_contains "re-run says it reused secrets" "reusing the existing secrets" "$OUT"

	# An existing compose file is the user's, not ours.
	printf '\n# hand-edited\n' >>"$DIR/docker-compose.yml"
	run_script setup --dir "$DIR"
	assert_contains "existing compose left alone" "leaving it alone" "$OUT"
	run_script setup --dir "$DIR" --force
	assert_contains "force replaces compose" "replaced docker-compose.yml" "$OUT"
}

env_key() { grep -E '^N8N_ENCRYPTION_KEY=' "$DIR/.env" | cut -d= -f2-; }

test_no_start() {
	echo "--no-start"
	local dir="$WORK/nostart"
	run_script setup --dir "$dir" --no-start --port 5898
	assert_eq "exits 0" "0" "$STATUS"
	assert_contains "writes files" "Files written" "$OUT"
	assert_file "$dir/.env" ".env written"
}

test_port_in_use() {
	echo "port already in use"
	local dir="$WORK/busy"
	local server_pid=""
	if command -v python3 >/dev/null 2>&1; then
		python3 -m http.server 5897 --bind 127.0.0.1 >/dev/null 2>&1 &
		server_pid=$!
		sleep 1
	fi

	run_script setup --dir "$dir" --port 5897
	if [ -n "$server_pid" ]; then
		kill "$server_pid" 2>/dev/null
		wait "$server_pid" 2>/dev/null
		if [ "$STATUS" -ne 0 ]; then pass "refuses a busy port"; else fail "refuses a busy port"; fi
		assert_contains "explains the busy port" "already in use" "$ERR"
		assert_absent "$dir/.env" "no .env left behind on failure"
	else
		echo "  skip  python3 unavailable"
	fi
}

test_credentials_staged() {
	echo "credentials staged before an owner exists"
	local dir="$WORK/staged"
	rm -f "$STATE/imported.log"
	FAKE_OWNER_COUNT=0 run_script credentials --dir "$dir"
	if [ "$STATUS" -ne 0 ]; then pass "no install yet is a clear failure"; else fail "no install yet is a clear failure"; fi
	assert_contains "says to run setup first" "Run 'setup-n8n.sh setup' first" "$ERR"

	DIR="$WORK/install"
	rm -f "$STATE/imported.log"
	FAKE_OWNER_COUNT=0 GEMINI_API_KEY=gemini-test-key run_script credentials --dir "$DIR"
	assert_eq "staging exits 0" "0" "$STATUS"
	assert_contains "explains the owner prerequisite" "owner account needed first" "$OUT"
	assert_file "$DIR/credentials.json" "credentials staged on disk"
	assert_mode "$DIR/credentials.json" "600" "staged credentials are mode 600"
	assert_absent "$STATE/imported.log" "nothing imported yet"
}

test_credentials_import() {
	echo "credentials imported once an owner exists"
	DIR="$WORK/install"
	rm -f "$STATE/imported.log"
	FAKE_OWNER_COUNT=1 GEMINI_API_KEY=gemini-test-key ANTHROPIC_API_KEY=anthropic-test-key \
		run_script credentials --dir "$DIR"
	assert_eq "import exits 0" "0" "$STATUS"
	assert_contains "reports the import" "credentials imported" "$OUT"
	assert_file "$STATE/imported.log" "import reached n8n"
	assert_contains "gemini key in payload" "gemini-test-key" "$STATE/imported.log"
	assert_contains "anthropic key in payload" "anthropic-test-key" "$STATE/imported.log"
	assert_contains "credential type is correct" "googlePalmApi" "$STATE/imported.log"
	assert_contains "credential type is correct" "anthropicApi" "$STATE/imported.log"
	assert_absent "$DIR/credentials.json" "staged file removed after import"
}

test_backup_and_restore() {
	echo "backup and restore"
	DIR="$WORK/install"
	run_script backup --dir "$DIR"
	assert_eq "backup exits 0" "0" "$STATUS"
	assert_contains "warns about the key" "N8N_ENCRYPTION_KEY" "$OUT"

	local dump
	dump="$(find "$DIR/backups" -name 'n8n-*.sql.gz' | head -1)"
	if [ -n "$dump" ]; then pass "dump created"; else fail "dump created"; return; fi

	run_script backup --dir "$DIR" --include-key
	assert_eq "backup --include-key exits 0" "0" "$STATUS"
	local keyfile
	keyfile="$(find "$DIR/backups" -name 'encryption-key-*.txt' | head -1)"
	if [ -n "$keyfile" ]; then pass "key copy written"; else fail "key copy written"; return; fi
	assert_mode "$keyfile" "600" "key copy is mode 600"
	assert_eq "key copy matches .env" "$(env_key)" "$(cat "$keyfile")"

	# Second-granular timestamps must not collide: two backups in a row are two
	# files, which is exactly what 'upgrade' relies on.
	local before_count after_count
	before_count="$(find "$DIR/backups" -name 'n8n-*.sql.gz' | wc -l | tr -d ' ')"
	run_script backup --dir "$DIR"
	after_count="$(find "$DIR/backups" -name 'n8n-*.sql.gz' | wc -l | tr -d ' ')"
	if [ "$after_count" -gt "$before_count" ]; then
		pass "back-to-back backups do not overwrite"
	else
		fail "back-to-back backups do not overwrite" "$before_count -> $after_count"
	fi

	rm -f "$STATE/restore.sql"
	run_script restore "$dump" --dir "$DIR" --yes
	assert_eq "restore exits 0" "0" "$STATUS"
	assert_file "$STATE/restore.sql" "restore streamed SQL into postgres"
	if grep -q 'CREATE TABLE' "$STATE/restore.sql" 2>/dev/null; then
		pass "restored the dump contents"
	else
		fail "restored the dump contents"
	fi

	run_script restore "$WORK/nope.sql.gz" --dir "$DIR" --yes
	if [ "$STATUS" -ne 0 ]; then pass "missing dump is rejected"; else fail "missing dump is rejected"; fi
}

test_upgrade() {
	echo "upgrade"
	DIR="$WORK/install"
	local before after
	before="$(find "$DIR/backups" -name 'n8n-*.sql.gz' | wc -l | tr -d ' ')"
	run_script upgrade 2.34.0 --dir "$DIR"
	assert_eq "upgrade exits 0" "0" "$STATUS"
	assert_contains "pins the new tag" "N8N_VERSION=2.34.0" "$DIR/.env"
	after="$(find "$DIR/backups" -name 'n8n-*.sql.gz' | wc -l | tr -d ' ')"
	if [ "$after" -gt "$before" ]; then pass "upgrade takes a backup first"; else fail "upgrade takes a backup first" "$before -> $after"; fi
	assert_contains "reports the new version" "now running 2.34.0" "$OUT"

	run_script upgrade --dir "$DIR"
	if [ "$STATUS" -ne 0 ]; then pass "upgrade without a version is rejected"; else fail "upgrade without a version is rejected"; fi
}

test_status_and_down() {
	echo "status and down"
	DIR="$WORK/install"
	run_script status --dir "$DIR"
	assert_eq "status exits 0" "0" "$STATUS"
	assert_contains "status shows readiness" "ready" "$OUT"
	assert_contains "status shows the editor URL" "http://127.0.0.1:5899" "$OUT"

	run_script down --dir "$DIR" --yes
	assert_eq "down exits 0" "0" "$STATUS"
	assert_contains "down keeps data" "data kept" "$OUT"
	assert_file "$DIR/.env" ".env survives down"
}

test_doctor() {
	echo "doctor"
	run_script doctor --dir "$WORK/install"
	assert_eq "doctor exits 0" "0" "$STATUS"
	assert_contains "doctor finds docker" "docker found" "$OUT"
	assert_contains "doctor finds compose" "compose:" "$OUT"
}

test_not_ready_timeout() {
	echo "readiness timeout"
	local dir="$WORK/slow"
	FAKE_NOT_READY=1 N8N_READY_TIMEOUT=2 run_script setup --dir "$dir" --port 5896
	if [ "$STATUS" -ne 0 ]; then pass "fails when n8n never becomes ready"; else fail "fails when n8n never becomes ready"; fi
	assert_contains "points at the logs" "did not become ready" "$ERR"
	assert_contains "prints log tail" "fake n8n log line" "$ERR"
}

# ── run ───────────────────────────────────────────────────────────────────────

echo "setup-n8n.sh tests"
echo

test_help
test_dry_run
test_setup
test_no_start
test_port_in_use
test_credentials_staged
test_credentials_import
test_backup_and_restore
test_upgrade
test_status_and_down
test_doctor
test_not_ready_timeout

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
