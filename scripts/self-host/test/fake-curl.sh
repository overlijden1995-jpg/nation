#!/usr/bin/env bash
#
# Test double for curl. The installer only uses curl to poll the readiness
# endpoint, so this reports whatever the test scenario asks for.
#
#   FAKE_NOT_READY=1  every request fails (exercises the timeout path)
#
set -uo pipefail

if [ "${FAKE_NOT_READY:-0}" = "1" ]; then
	exit 22
fi

exit 0
