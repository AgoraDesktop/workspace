#!/bin/bash
# The Workspace suite — THE DESKTOP IS TWO LEVELS NOW.
#
#   kCGDesktopWindowLevel      a WALLPAPER window (a flat stub here; the Dock's, eventually)
#   kCGDesktopIconWindowLevel  Workspace's TRANSPARENT window, drawing only the icons
#   NSNormalWindowLevel        an ordinary window, over both
#
# WHAT IS ASSERTED IS WHERE THE PIXELS LANDED, and the two that matter are: the wallpaper SHOWS THROUGH the icon
# window wherever there is no icon (so the window is really transparent), and an icon appears where its sidecar
# says it goes.
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

# THE WALLPAPER STUB: a full-screen window at the WALLPAPER level, in ARGENTUM's amber. It stands in for the
# window the Dock will draw — what it proves here is the LEVEL and that the icon window is transparent over it.
WALL_COLOUR=48240E
WALL_LEVEL=$(( -2147483648 + 20 ))

NORMAL_COLOUR=FF8800
NORMAL_X=200
NORMAL_Y=200

# THE DESKTOP'S ITEM, clear of the normal window and of the sample points.
ICON_NAME=hello.txt
ICON_X=900
ICON_Y=300
ICON_SIZE=64

cleanup() {
	for pid in "${SPID:-}" "${WALLPID:-}" "${WPID:-}" "${CPID:-}"; do
		[ -n "${pid}" ] && kill "${pid}" 2>/dev/null
	done
	rm -f "${RUNTIME}/${SOCK}" "${RUNTIME}/${SOCK}.lock" "${SHOT}"
	rm -rf "${DESKTOP_DIR}"
}
trap cleanup EXIT

rm -f "${RUNTIME}/${SOCK}" "${RUNTIME}/${SOCK}.lock" "${SHOT}"
rm -rf "${DESKTOP_DIR}"

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

# 1. THE WALLPAPER, at the wallpaper level.
WAYLAND_DISPLAY="${SOCK}" "${CLIENT}" --width 1280 --height 720 --colour "${WALL_COLOUR}" \
	--x 0 --y 0 --level "${WALL_LEVEL}" --frames 1000000 >/dev/null 2>&1 &
WALLPID=$!
sleep 0.6

# 2. THE ICONS: Workspace owns a TRANSPARENT window at the icon level, showing the desktop directory.
AGORA_DESKTOP="${DESKTOP_DIR}" WAYLAND_DISPLAY="${SOCK}" "${WORKSPACE}" --seconds 1000000 \
	>/dev/null 2>/tmp/agora-workspace-app.log &
WPID=$!
sleep 1

# 3. AN ORDINARY WINDOW over both, created last.
WAYLAND_DISPLAY="${SOCK}" "${CLIENT}" --width 320 --height 200 --colour "${NORMAL_COLOUR}" \
	--x "${NORMAL_X}" --y "${NORMAL_Y}" --level 0 --frames 1000000 >/dev/null 2>&1 &
CPID=$!
sleep 2

kill -TERM "${SPID}" 2>/dev/null
wait "${SPID}" 2>/dev/null
kill "${WALLPID}" "${WPID}" "${CPID}" 2>/dev/null

if [ ! -f "${SHOT}" ]; then
	echo "FAIL: the server wrote no screenshot" >&2
	cat /tmp/agora-workspace-server.log >&2
	exit 1
fi

"${PYTHON}" "${CHECKER}" "${SHOT}" "${NORMAL_COLOUR}" "${WALL_COLOUR}" "${ICON_X}" "${ICON_Y}" "${ICON_SIZE}"
