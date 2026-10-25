#!/bin/bash
# Copyright © 2026 Kyle J. Cardoza.
# SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
# SPDX-License-Identifier: GPL-3.0-or-later

# An ordinary launch RUNS, and only `--seconds` bounds it.
#
#   run-default-run.sh WORKSPACE-APP SERVER
#
# **THE REPORT THIS EXISTS FOR WAS "Workspace exits after an implicit three-second deadline unless launched with
# special handling".** An ordinary launch of the bundle used to install a three-second test deadline, so a session
# whose launcher treats Workspace as the foreground process lost the whole desktop about three seconds in. The
# fix is that the deadline is the `--seconds` DOOR's and not the default's, and that is what is measured here:
#
#   1. with no arguments, the process is still alive after five seconds;
#   2. `--seconds 0.2` still leaves on its own, so the door was not simply closed;
#   3. `--seconds 0` is a bounded run too (a caller that names zero asked to leave immediately).
#
# It needs a compositor to connect to, so it starts the window server headless — the same one the desktop suite uses,
# and no screenshot: this is a question about a process, not about pixels. Exit 77 means SKIP when the window server
# has not been built beside this repo, which is the rest of this suite's convention.
set -u

WORKSPACE="${1:?usage: run-default-run.sh WORKSPACE-APP SERVER}"
SERVER="${2:?}"

if [ ! -x "${SERVER}" ]; then
	echo "SKIP: the window server's binary is not built" >&2
	exit 77
fi
if [ ! -x "${WORKSPACE}" ]; then
	echo "FAIL: the Workspace bundle has no executable at ${WORKSPACE}" >&2
	exit 1
fi

RUNTIME="${XDG_RUNTIME_DIR:-/tmp}"
SOCK="aws-workspace-default-$$"
DESKTOP_DIR="/tmp/agora-workspace-default-desktop-$$"
STATUS=0

cleanup() {
	for pid in "${SPID:-}" "${WPID:-}"; do
		[ -n "${pid}" ] && kill "${pid}" 2>/dev/null
	done
	rm -f "${RUNTIME}/${SOCK}" "${RUNTIME}/${SOCK}.lock"
	rm -rf "${DESKTOP_DIR}"
}
trap cleanup EXIT

rm -f "${RUNTIME}/${SOCK}" "${RUNTIME}/${SOCK}.lock"
rm -rf "${DESKTOP_DIR}"
mkdir -p "${DESKTOP_DIR}"

"${SERVER}" --socket "${SOCK}" --frames 1000000 >/dev/null 2>/tmp/agora-workspace-default-server.log &
SPID=$!
for _ in $(seq 1 50); do
	[ -S "${RUNTIME}/${SOCK}" ] && break
	sleep 0.1
done
if [ ! -S "${RUNTIME}/${SOCK}" ]; then
	echo "FAIL: the server never created its socket" >&2
	cat /tmp/agora-workspace-default-server.log >&2
	exit 1
fi

# 1. **NO ARGUMENTS, FIVE SECONDS, STILL RUNNING.** The wait is a bound on the measurement and not a deadline for the
# process: the whole point is that nothing in Workspace ends it.
AGORA_DESKTOP="${DESKTOP_DIR}" WAYLAND_DISPLAY="${SOCK}" "${WORKSPACE}" \
	>/dev/null 2>/tmp/agora-workspace-default-app.log &
WPID=$!
sleep 5
if kill -0 "${WPID}" 2>/dev/null; then
	echo "  ok     an ordinary launch is still running after five seconds"
else
	wait "${WPID}"
	CODE=$?
	echo "  FAIL   an ordinary launch exited on its own (status ${CODE})" >&2
	cat /tmp/agora-workspace-default-app.log >&2
	STATUS=1
fi
kill -TERM "${WPID}" 2>/dev/null
wait "${WPID}" 2>/dev/null
WPID=

# 2. **AND `--seconds 0.2` IS STILL A BOUNDED RUN**, or the fix would have been "the door stopped working".
AGORA_DESKTOP="${DESKTOP_DIR}" WAYLAND_DISPLAY="${SOCK}" "${WORKSPACE}" --seconds 0.2 \
	>/dev/null 2>/tmp/agora-workspace-default-bounded.log &
WPID=$!
sleep 3
if kill -0 "${WPID}" 2>/dev/null; then
	echo "  FAIL   --seconds 0.2 did not end the run" >&2
	kill -TERM "${WPID}" 2>/dev/null
	wait "${WPID}" 2>/dev/null
	STATUS=1
else
	wait "${WPID}"
	CODE=$?
	if [ "${CODE}" -eq 0 ]; then
		echo "  ok     --seconds 0.2 leaves on its own, with status 0"
	else
		echo "  FAIL   --seconds 0.2 exited with status ${CODE}" >&2
		cat /tmp/agora-workspace-default-bounded.log >&2
		STATUS=1
	fi
fi
WPID=

# 3. **AND ZERO IS A DEADLINE, NOT "NO DEADLINE".** The flag decides and not the value: a caller that names zero asked
# for a loop that leaves immediately.
AGORA_DESKTOP="${DESKTOP_DIR}" WAYLAND_DISPLAY="${SOCK}" "${WORKSPACE}" --seconds 0 \
	>/dev/null 2>/tmp/agora-workspace-default-zero.log &
WPID=$!
sleep 2
if kill -0 "${WPID}" 2>/dev/null; then
	echo "  FAIL   --seconds 0 did not end the run" >&2
	kill -TERM "${WPID}" 2>/dev/null
	wait "${WPID}" 2>/dev/null
	STATUS=1
else
	wait "${WPID}"
	CODE=$?
	if [ "${CODE}" -eq 0 ]; then
		echo "  ok     --seconds 0 is a bounded run too"
	else
		echo "  FAIL   --seconds 0 exited with status ${CODE}" >&2
		cat /tmp/agora-workspace-default-zero.log >&2
		STATUS=1
	fi
fi
WPID=

kill -TERM "${SPID}" 2>/dev/null
wait "${SPID}" 2>/dev/null
SPID=

if [ "${STATUS}" -eq 0 ]; then
	echo "all checks passed"
fi
exit "${STATUS}"
