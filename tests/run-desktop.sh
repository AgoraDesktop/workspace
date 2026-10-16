#!/bin/bash
# The W0 suite: Workspace's desktop window under Agora's own window server, with a normal window over it.
#
# WHAT IS ASSERTED IS WHERE THE PIXELS LANDED, not what the app printed: the server writes its own screenshot,
# and check.py reads the wallpaper's coverage, the ramp, and that the NORMAL window is on top of the desktop.
#
# Exit 77 means SKIP, and it is the honest answer when the window server has not been built beside this repo.
set -u

WORKSPACE="${1:?usage: run-desktop.sh WORKSPACE-APP SERVER CLIENT PYTHON CHECKER}"
SERVER="${2:?}"
CLIENT="${3:?}"
PYTHON="${4:?}"
CHECKER="${5:?}"

if [ ! -x "${SERVER}" ] || [ ! -x "${CLIENT}" ]; then
	echo "SKIP: the window server's binary or test client is not built" >&2
	exit 77
fi
if [ ! -x "${WORKSPACE}" ]; then
	echo "FAIL: the Workspace bundle has no executable at ${WORKSPACE}" >&2
	exit 1
fi

RUNTIME="${XDG_RUNTIME_DIR:-/tmp}"
SOCK="aws-workspace-$$"
SHOT="/tmp/agora-workspace-$$.ppm"
NORMAL_COLOUR=FF8800
NORMAL_X=200
NORMAL_Y=200

cleanup() {
	[ -n "${SPID:-}" ] && kill "${SPID}" 2>/dev/null
	[ -n "${WPID:-}" ] && kill "${WPID}" 2>/dev/null
	[ -n "${CPID:-}" ] && kill "${CPID}" 2>/dev/null
	rm -f "${RUNTIME}/${SOCK}" "${RUNTIME}/${SOCK}.lock" "${SHOT}"
}
trap cleanup EXIT

rm -f "${RUNTIME}/${SOCK}" "${RUNTIME}/${SOCK}.lock" "${SHOT}"

"${SERVER}" --socket "${SOCK}" --frames 1000000 --screenshot "${SHOT}" >/dev/null 2>/tmp/agora-workspace-server.log &
SPID=$!
for _ in $(seq 1 50); do
	[ -S "${RUNTIME}/${SOCK}" ] && break
	sleep 0.1
done
if [ ! -S "${RUNTIME}/${SOCK}" ]; then
	echo "FAIL: the server never created its socket" >&2
	cat /tmp/agora-workspace-server.log >&2
	exit 1
fi

# THE DESKTOP: Workspace, owning a full-screen window at the desktop level.
WAYLAND_DISPLAY="${SOCK}" "${WORKSPACE}" --seconds 1000000 >/dev/null 2>/tmp/agora-workspace-app.log &
WPID=$!
sleep 1

# A NORMAL WINDOW OVER IT, at the ordinary level — created AFTER the desktop, and above it only if the server
# ordered by level rather than by creation.
WAYLAND_DISPLAY="${SOCK}" "${CLIENT}" --width 320 --height 200 --colour "${NORMAL_COLOUR}" \
	--x "${NORMAL_X}" --y "${NORMAL_Y}" --level 0 --frames 1000000 >/dev/null 2>&1 &
CPID=$!
sleep 2

kill -TERM "${SPID}" 2>/dev/null
wait "${SPID}" 2>/dev/null
kill "${WPID}" "${CPID}" 2>/dev/null

if [ ! -f "${SHOT}" ]; then
	echo "FAIL: the server wrote no screenshot" >&2
	cat /tmp/agora-workspace-server.log >&2
	exit 1
fi

"${PYTHON}" "${CHECKER}" "${SHOT}" "${NORMAL_COLOUR}"
