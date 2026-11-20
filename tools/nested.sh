#!/bin/bash
# Runs tiewm inside Xephyr (a window on the current desktop) with real LXQt apps,
# fully isolated from the live session: own X server (:2), own D-Bus session,
# own copy of the LXQt config. Nothing here talks to display :0.
#   tools/nested.sh start [WxH]   start Xephyr, tiewm, panel and a few apps
#   tools/nested.sh stop          stop everything it started (by PID)
#   tools/nested.sh shot [file]   screenshot of the nested screen
set -u
D=:2
N="${TIEWM_NESTED_DIR:-/tmp/tiewm-nested}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
case "${1:-}" in
start)
  SIZE="${2:-1600x900}"
  mkdir -p "$N/cfg" "$N/cache"; rm -rf "$N/cfg/lxqt"; cp -r "$HOME/.config/lxqt" "$N/cfg/lxqt"
  # -no-host-grab: do not steal the real keyboard/pointer from the live session
  Xephyr "$D" -screen "$SIZE" -title "tiewm nested test" -no-host-grab >"$N/xephyr.log" 2>&1 &
  echo $! >"$N/xephyr.pid"; sleep 1.5
  DISPLAY=$D TIEWM_DEBUG=1 "$ROOT/tiewm" >"$N/wm.log" 2>&1 &
  echo $! >"$N/tiewm.pid"; sleep 1
  ( unset WAYLAND_DISPLAY; export DISPLAY=$D XDG_SESSION_TYPE=x11 XDG_CONFIG_HOME="$N/cfg" XDG_CACHE_HOME="$N/cache"
    exec setsid dbus-run-session -- bash -c 'lxqt-panel & sleep 2; pcmanfm-qt & qterminal & wait' ) >"$N/apps.log" 2>&1 &
  echo $! >"$N/apps.pid"
  echo "nested session on $D ($SIZE); logs in $N"
  ;;
stop)
  for f in apps tiewm xephyr; do
    if [ -f "$N/$f.pid" ]; then
      P=$(cat "$N/$f.pid"); kill -- -"$P" 2>/dev/null || kill "$P" 2>/dev/null; rm -f "$N/$f.pid"
    fi
  done
  sleep 1; echo stopped
  ;;
shot)
  DISPLAY=$D import -window root "${2:-$N/shot.png}" && echo "${2:-$N/shot.png}"
  ;;
*) echo "usage: $0 start [WxH] | stop | shot [file]"; exit 2;;
esac
