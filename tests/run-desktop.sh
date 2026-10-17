#!/bin/bash
# The Workspace suite: the desktop window under Agora's own window server, with a normal window over it AND a
# file on the desktop whose icon must appear where its sidecar says it goes.
#
# WHAT IS ASSERTED IS WHERE THE PIXELS LANDED, not what the app printed: the server writes its own screenshot
# and check.py reads the wallpaper's coverage, the ramp, the normal window's order — and the icon.
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
DESKTOP_DIR="/tmp/agora-workspace-desktop-$$"

NORMAL_COLOUR=FF8800
NORMAL_X=200
NORMAL_Y=200

# THE DESKTOP'S ITEM, and the place its sidecar says its icon goes — clear of the normal window, so nothing
# covers it.
ICON_NAME=hello.txt
ICON_X=900
ICON_Y=300
ICON_SIZE=64

cleanup() {
	[ -n "${SPID:-}" ] && kill "${SPID}" 2>/dev/null
	[ -n "${WPID:-}" ] && kill "${WPID}" 2>/dev/null
	[ -n "${CPID:-}" ] && kill "${CPID}" 2>/dev/null
	rm -f "${RUNTIME}/${SOCK}" "${RUNTIME}/${SOCK}.lock" "${SHOT}"
	rm -rf "${DESKTOP_DIR}"
}
trap cleanup EXIT

rm -f "${RUNTIME}/${SOCK}" "${RUNTIME}/${SOCK}.lock" "${SHOT}"
rm -rf "${DESKTOP_DIR}"

# **THE DESKTOP THIS RUN SHOWS, AND THE SIDECAR THAT PLACES ITS ICON.** The sidecar is written as XML here
# because the app reads property lists in either encoding and a shell can write XML; the FORMAT is the app's
# (a versioned per-folder plist, WORKSPACE-PLAN.md §5.1) and this is one of its readers.
mkdir -p "${DESKTOP_DIR}"
: > "${DESKTOP_DIR}/${ICON_NAME}"
cat > "${DESKTOP_DIR}/.agora" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>version</key><integer>1</integer>
  <key>iconSize</key><integer>${ICON_SIZE}</integer>
  <key>icons</key><dict>
    <key>${ICON_NAME}</key><array><integer>${ICON_X}</integer><integer>${ICON_Y}</integer></array>
  </dict>
</dict></plist>
PLIST

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

# THE DESKTOP: Workspace, owning a full-screen window at the desktop level, showing the desktop directory.
AGORA_DESKTOP="${DESKTOP_DIR}" WAYLAND_DISPLAY="${SOCK}" "${WORKSPACE}" --seconds 1000000 \
	>/dev/null 2>/tmp/agora-workspace-app.log &
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

"${PYTHON}" "${CHECKER}" "${SHOT}" "${NORMAL_COLOUR}" "${ICON_X}" "${ICON_Y}" "${ICON_SIZE}"
