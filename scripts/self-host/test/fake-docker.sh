#!/usr/bin/env bash
#
# Test double for the docker CLI. Used by run-tests.sh so the installer can be
# exercised without a Docker daemon.
#
# Behaviour is driven by environment variables:
#   FAKE_DOCKER_STATE   directory for call logs and captured payloads (required)
#   FAKE_OWNER_COUNT    what the "SELECT count(*) FROM user" probe returns (default 1)
#
set -uo pipefail

state="${FAKE_DOCKER_STATE:?FAKE_DOCKER_STATE must be set}"
mkdir -p "$state"

log() { printf '%s\n' "$*" >>"$state/calls.log"; }

cmd="${1:-}"
shift || true

case "$cmd" in
	info)
		exit 0
		;;
	--version)
		printf 'Docker version 27.0.0, build test\n'
		exit 0
		;;
	compose)
		# Drop the global flags the installer passes before the subcommand.
		while [ $# -gt 0 ]; do
			case "$1" in
				-f | --file | --project-directory | -p | --project-name) shift 2 || shift ;;
				*) break ;;
			esac
		done

		sub="${1:-}"
		shift || true
		log "compose $sub $*"

		case "$sub" in
			version) printf 'Docker Compose version v2.29.0\n' ;;
			config | up | pull | stop | start | restart) ;;
			down) ;;
			ps)
				printf 'NAME     IMAGE     STATUS\n'
				printf 'n8n-1    n8n       running\n'
				;;
			logs) printf 'fake n8n log line\n' ;;
			cp)
				cp "$1" "$state/container_credentials.json"
				;;
			exec)
				while [ "${1:-}" = "-T" ]; do shift; done
				service="${1:-}"
				shift || true
				log "exec $service $*"

				case "$service" in
					postgres)
						case "$*" in
							*pg_dump*)
								printf -- '-- fake n8n dump\n'
								printf 'CREATE TABLE "user" (id varchar);\n'
								;;
							*'count(*)'*)
								printf '%s\n' "${FAKE_OWNER_COUNT:-1}"
								;;
							*psql*)
								cat >"$state/restore.sql"
								printf 'restored\n'
								;;
						esac
						;;
					n8n)
						case "$*" in
							*import:credentials*)
								cat "$state/container_credentials.json" >>"$state/imported.log" 2>/dev/null
								printf 'Imported credentials\n'
								;;
						esac
						;;
				esac
				;;
		esac
		exit 0
		;;
esac

exit 0
