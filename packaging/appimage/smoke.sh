#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 SEN Labs e.U.
#
# Starts the server in the AppImage on a headless display and tests it. It has no window to look for: what counts is that it
# answers. It installs its ontology, says that it runs, passes its check and works with relations (the tests of the
# relations, built with `make -f Makefile.cosmoe test-programs`, against the server in the AppImage).
#
#   sh packaging/appimage/smoke.sh <AppImage> <x11|wayland> <OUT_DIR> [relation-test]
#
# Run it from a folder on a real disk: the home folder of the test is made here, and a tmpfs is no volume for a query.
# It stops any sen_server it can see, and Hokku finds a program by a socket, so next to a server that is in use it belongs in
# namespaces of its own: unshare -r -n -p -f --mount-proc sh -c 'ip link set lo up; sh packaging/appimage/smoke.sh ...'
set -u
APP=$(readlink -f "$1")
BACKEND=$2
OUT=$(mkdir -p "$3" && cd "$3" && pwd)
RELATION_TEST=${4:+$(readlink -f "$4")}

fail() { echo "smoke ($BACKEND): FAIL: $*"; [ -f "$OUT/app.log" ] && tail -30 "$OUT/app.log"; stop; exit 1; }
SERVER=""; WM=""; XSERVER=""; COMPOSITOR=""
stop_server() {
	[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null
	sleep 1
	pkill -TERM -x sen_server 2>/dev/null
	for i in $(seq 40); do pgrep -x sen_server >/dev/null || break; sleep 0.25; done
	pkill -KILL -x sen_server 2>/dev/null
}
stop() {
	stop_server
	[ -z "$WM" ] || kill "$WM" 2>/dev/null
	[ -z "$XSERVER" ] || kill "$XSERVER" 2>/dev/null
	[ -z "$COMPOSITOR" ] || kill "$COMPOSITOR" 2>/dev/null
}

case "$BACKEND" in
	x11)
		DPY=:${SMOKE_DISPLAY:-77}
		Xvfb "$DPY" -screen 0 1280x800x24 -nolisten tcp > "$OUT/xvfb.log" 2>&1 &
		XSERVER=$!
		sleep 1
		DISPLAY=$DPY openbox > "$OUT/wm.log" 2>&1 &
		WM=$!
		for i in $(seq 40); do DISPLAY=$DPY xdotool get_desktop >/dev/null 2>&1 && break; sleep 0.25; done
		export DISPLAY=$DPY
		unset WAYLAND_DISPLAY
		;;
	wayland)
		export XDG_RUNTIME_DIR=$(mktemp -d)
		chmod 700 "$XDG_RUNTIME_DIR"
		CONF=$(mktemp)
		printf 'output HEADLESS-1 resolution 1280x800\ndefault_border none\n' > "$CONF"
		env -u DISPLAY -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
			sway -c "$CONF" > "$OUT/compositor.log" 2>&1 &
		COMPOSITOR=$!
		SOCK=""
		for i in $(seq 40); do
			SOCK=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -1)
			[ -n "$SOCK" ] && break
			sleep 0.25
		done
		[ -n "$SOCK" ] || { echo "smoke: the compositor did not start"; cat "$OUT/compositor.log"; exit 1; }
		export WAYLAND_DISPLAY=$SOCK
		unset DISPLAY
		;;
	*) echo "usage: smoke.sh <AppImage> <x11|wayland> <OUT_DIR> [relation-test]"; exit 2 ;;
esac

export COSMOE_BACKEND=$BACKEND APPIMAGE_EXTRACT_AND_RUN=1 SEN_NO_DESKBAR=1
SMOKE_HOME=$(mktemp -d -p "$PWD" smoke-home.XXXXXX)
export HOME=$SMOKE_HOME
unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME

# 1. a first run, in an empty home folder
SEN_LOG_LEVEL=info "$APP" > "$OUT/app.log" 2>&1 &
SERVER=$!
RUNNING=""
for i in $(seq 120); do
	"$APP" --info > "$OUT/info.txt" 2>&1
	grep -q 'Server *running' "$OUT/info.txt" && { RUNNING=1; break; }
	kill -0 "$SERVER" 2>/dev/null || fail "the server exited"
	sleep 0.5
done
[ -n "$RUNNING" ] || fail "the server does not answer"
echo "smoke ($BACKEND): the server runs ($(uname -m))"

# 2. the server installs the core ontology by itself, from what the AppImage brings. It runs sen_oni --update after a moment,
#    which also removes what is not provided: types that are there before it has run say nothing.
UPDATE_LOG=$HOME/.config/cosmoe/sen/ontologies-update.log
UPDATED=""
for i in $(seq 240); do
	grep -qE '^(Done|Removed):|^Nothing to do|up to date' "$UPDATE_LOG" 2>/dev/null && { UPDATED=1; break; }
	kill -0 "$SERVER" 2>/dev/null || fail "the server exited while its ontology was installed"
	sleep 0.5
done
[ -n "$UPDATED" ] || { tail -20 "$UPDATE_LOG" 2>/dev/null; fail "the ontology update did not finish"; }
sleep 3
types_are_there() {
	"$APP" --info > "$OUT/info.txt" 2>&1
	cat "$OUT/info.txt"
	grep -qE 'Types +[1-9]' "$OUT/info.txt" || { tail -20 "$UPDATE_LOG" 2>/dev/null; fail "no types: $1"; }
	if grep -q 'Removed: core' "$UPDATE_LOG"; then
		tail -20 "$UPDATE_LOG"
		fail "the core ontology was uninstalled: $1"
	fi
	if grep -qE 'failed to relate|is not complete' "$UPDATE_LOG"; then
		tail -20 "$UPDATE_LOG"
		fail "the core ontology was not related to its types: $1"
	fi
}
types_are_there "after the update"

# ...and it stays, when the server starts again from another mount point of the AppImage.
kill "$SERVER" 2>/dev/null
for i in $(seq 40); do pgrep -x sen_server >/dev/null || break; sleep 0.25; done
pkill -KILL -x sen_server 2>/dev/null
mv "$UPDATE_LOG" "$OUT/ontologies-update-first.log"
SEN_LOG_LEVEL=info "$APP" >> "$OUT/app.log" 2>&1 &
SERVER=$!
RUNNING=""
for i in $(seq 120); do
	"$APP" --info 2>&1 | grep -q 'Server *running' && { RUNNING=1; break; }
	kill -0 "$SERVER" 2>/dev/null || fail "the server exited when it was started again"
	sleep 0.5
done
[ -n "$RUNNING" ] || fail "the server does not answer when started again"
for i in $(seq 40); do [ -s "$UPDATE_LOG" ] && break; sleep 0.5; done
sleep 8
types_are_there "after starting again"

# 3. the check finds nothing wrong
echo "smoke ($BACKEND): home folder on $(stat -f -c %T "$HOME")"
"$APP" --check > "$OUT/check.txt" 2>&1
tail -2 "$OUT/check.txt"
grep -q 'No problems found' "$OUT/check.txt" || { cat "$OUT/check.txt"; fail "the check found problems"; }

# 4. relations, through the server in the AppImage. Two tests are known to fail: a program that isn't a BApplication (this
#    test) is credited as Hokku's reply helper, so the provenance tests do.
if [ -n "$RELATION_TEST" ]; then
	mkdir -p "$HOME/test"
	TEST_DIR=$HOME/test timeout 180 "$RELATION_TEST" > "$OUT/relation-test.txt" 2>&1
	tail -1 "$OUT/relation-test.txt"
	UNEXPECTED=$(grep -E '^FAIL ' "$OUT/relation-test.txt" | grep -vE 'FAIL (ARelationKnowsWhoMadeIt|ARelationFromBeforeProvenanceLearnsItsCreatorWhenItIsMadeAgain)$')
	[ -z "$UNEXPECTED" ] || { echo "$UNEXPECTED"; fail "relation tests failed"; }
	grep -qE '^26 test|^[0-9]+ test' "$OUT/relation-test.txt" || fail "the relation tests did not finish"
	kill -0 "$SERVER" 2>/dev/null || fail "the server died in the relation tests"
fi

# 5. a clean log, and a clean stop
if grep -E '\[critical\]|Segmentation|Aborted' "$OUT/app.log"; then
	fail "problems in the log"
fi
UNKNOWN=$(grep -c 'unknown message' "$OUT/app.log")
[ "$UNKNOWN" -lt 10 ] || fail "$UNKNOWN unknown messages: a message loop?"

stop_server
wait "$SERVER" 2>/dev/null
SERVER=""

# 6. the desktop's tray: a tray of its own on a D-Bus session of its own
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if ! timeout 240 dbus-run-session -- python3 -I "$SCRIPT_DIR/tray-check.py" "$APP" "$OUT"; then
	tail -20 "$OUT/tray-app.log"
	pkill -x TrayExport 2>/dev/null
	stop
	echo "smoke ($BACKEND): FAIL: the tray"
	exit 1
fi
pkill -x TrayExport 2>/dev/null
stop
echo "smoke ($BACKEND): PASS"
