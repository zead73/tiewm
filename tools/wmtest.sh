#!/bin/bash
# Scenario tests for tiewm. Runs ONLY on the scratch display :99 (Xvfb),
# never on the real session. Build the tools first (see README).
#   tools/wmtest.sh            run all scenarios
set -u
export DISPLAY=:99
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
TMP="${WMTEST_TMP:-/tmp/tiewm-test}/wmtest"
mkdir -p "$TMP"
TW="$HERE/testwin"; XDO="$HERE/xdo"; XG="$HERE/xgeom"; WM="$ROOT/tiewm"
PASS=0; FAIL=0

check() {  # name, condition-exit-status, [detail]
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); echo "PASS  $1"; else FAIL=$((FAIL+1)); echo "FAIL  $1  ${3:-}"; fi
}
sec() { sleep "${1:-0.4}"; }

# NEVER pkill by name: the live session runs its own "tiewm". Only touch one whose DISPLAY is :99.
kill_scratch_wm() {
  for p in $(pgrep -x tiewm); do
    if tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qx 'DISPLAY=:99'; then kill -TERM "$p" 2>/dev/null; fi
  done
}
start_xvfb() {
  if ! pgrep -x Xvfb >/dev/null; then
    Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
    sleep 1
  fi
}
start_wm() { TIEWM_DEBUG=1 "$WM" 2>"$TMP/wm.log" & WMPID=$!; sleep 0.8; }
stop_wm() { kill -TERM "$WMPID" 2>/dev/null; wait "$WMPID" 2>/dev/null; }
stop_clients() { pkill -x testwin 2>/dev/null; sleep 0.3; }
cleanup() { stop_clients; kill "$WMPID" 2>/dev/null; wait "$WMPID" 2>/dev/null; }
trap cleanup EXIT

# new window: name, args...  -> sets LAST_ID
newwin() {
  local name="$1"; shift
  "$TW" "$@" >"$TMP/$name.log" 2>&1 &
  eval "PID_$name=$!"
  sleep 0.7
  LAST_ID=$(sed -n 's/^mapped id=\(0x[0-9a-fA-F]*\).*/\1/p' "$TMP/$name.log" | head -1)
}
absgeom() { "$XG" abs "$(printf '%d' "$1")"; }   # prints: abs x= y= w= h=
field() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
active() { xprop -root _NET_ACTIVE_WINDOW | sed 's/.*# //;s/,.*//'; }
hexnorm() { printf '0x%x' "$(printf '%d' "$1")"; }


viewable() {  # client id -> 1/0 (map state of the client window inside its frame)
  "$XG" | grep "^  win=$(printf '0x%X' "$(printf '%d' "$1")") " | sed -n 's/.*viewable=\([01]\).*/\1/p'
}
stackpos() {  # client id -> index of its frame among root children (bottom = 0)
  "$XG" | awk -v id="$(printf '0x%X' "$(printf '%d' "$1")")" '/^win=/{n++} /^  win=/{ if ($1=="win="id) print n }'
}
toppos() {  # id of an unframed top-level window -> index among root children
  "$XG" | awk -v id="$(printf '0x%X' "$(printf '%d' "$1")")" '/^win=/{n++; if ($1=="win="id) print n}'
}
wmstate() { xprop -id "$1" WM_STATE | sed -n 's/.*window state: *//p' | sed 's/[^A-Za-z].*//'; }

start_xvfb
kill_scratch_wm; stop_clients
M=5; T=19   # Daloa: left/right/bottom border 5, title 19

echo "== 1. startup on an empty display"
start_wm
wmctrl -m 2>/dev/null | grep -q 'Name: tiewm'; check "wmctrl -m reports tiewm (EWMH check window)" $?
kill -0 "$WMPID" 2>/dev/null; check "tiewm still running" $?

echo "== 2. refuses to start when a WM already owns the root"
OUT=$("$WM" 2>&1); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -q 'another window manager'; check "second tiewm exits with message (rc=$RC)" $?
stop_wm

echo "== 3. adopts a window that exists before the WM starts"
newwin pre -t "Pre-existing" -w 300 -h 200 -c ffaa00 -s 60 -p 200,150
PRE=$LAST_ID; G0=$(absgeom "$PRE")
start_wm
G1=$(absgeom "$PRE")
[ "$(field "$G0" x)" = "$(field "$G1" x)" ] && [ "$(field "$G0" y)" = "$(field "$G1" y)" ]; check "client stays where it was ($G0 -> $G1)" $?
"$XG" | grep -q "win=$(hexnorm "$PRE")" ; R1=$?
"$XG" | awk -v id="$(printf '0x%X' "$PRE")" '/^win=/{top=$1} /^  win=/{ if ($1=="win="id) print top}' | grep -q 'win=' ; check "client is now inside a frame window" $?
[ "$(active)" = "" ] || true
stop_clients

echo "== 4. new window is framed, centred, focused"
newwin a -t "Window A" -w 400 -h 300 -c 00cc66 -s 90
A=$LAST_ID; GA=$(absgeom "$A")
EX=$(( (1280 - (400+2*M)) / 2 + M )); EY=$(( (800 - (300+T+M)) / 2 + T ))
[ "$(field "$GA" x)" = "$EX" ] && [ "$(field "$GA" y)" = "$EY" ]; check "centred: expected client at $EX,$EY got $GA" $?
[ "$(hexnorm "$(active)")" = "$(hexnorm "$A")" ]; check "new window becomes _NET_ACTIVE_WINDOW" $?
xprop -id "$A" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M"; check "_NET_FRAME_EXTENTS set" $?
xprop -id "$A" _NET_WM_DESKTOP | grep -q "= 0"; check "_NET_WM_DESKTOP = 0 (lxqt-panel taskbar needs it to list the window)" $?
wmctrl -l | grep -q "Window A"; check "wmctrl -l lists it via _NET_CLIENT_LIST" $?

echo "== 5. click on a second window: focus switches and the app still gets the click"
newwin b -t "Window B" -w 300 -h 200 -c 3366ff -s 90 -p 40,60
B=$LAST_ID
newwin a2 -t "Window A2" -w 300 -h 200 -c ffcc00 -s 90 -p 700,500
A2=$LAST_ID
"$XDO" move 800 600 click 1; sec
[ "$(hexnorm "$(active)")" = "$(hexnorm "$A2")" ]; check "clicking A2 keeps/sets focus on A2" $?
"$XDO" move 100 100 click 1; sec
[ "$(hexnorm "$(active)")" = "$(hexnorm "$B")" ]; check "clicking B moves focus to B" $?
grep -q 'ButtonPress x=60 y=40 button=1' "$TMP/b.log"; check "B received the replayed click at client coords 60,40" $?
"$XDO" move 800 600 click 1; sec
grep -q 'ButtonPress x=100 y=100 button=1' "$TMP/a2.log"; check "A2 received its click" $?

echo "== 6. move: titlebar drag, Alt+drag, with Num Lock/Caps Lock on and off"
GB0=$(absgeom "$B"); BX0=$(field "$GB0" x); BY0=$(field "$GB0" y)
"$XDO" drag 150 $((BY0-8)) 250 $((BY0+42)); sec 0.6      # titlebar of B: client top is BY0, title is above it
GB1=$(absgeom "$B")
[ "$(field "$GB1" x)" -eq $((BX0+100)) ] && [ "$(field "$GB1" y)" -eq $((BY0+50)) ]; check "titlebar drag moved B by +100,+50 ($GB0 -> $GB1)" $?
GB0=$GB1; BX0=$(field "$GB0" x); BY0=$(field "$GB0" y)
"$XDO" keydown Alt_L drag $((BX0+50)) $((BY0+50)) $((BX0+30)) $((BY0+20)) keyup Alt_L; sec 0.6
GB1=$(absgeom "$B")
[ "$(field "$GB1" x)" -eq $((BX0-20)) ] && [ "$(field "$GB1" y)" -eq $((BY0-30)) ]; check "Alt+drag moved B by -20,-30 ($GB0 -> $GB1)" $?
for LK in Num_Lock Caps_Lock; do
  "$XDO" key $LK; sec
  GB0=$(absgeom "$B"); BX0=$(field "$GB0" x); BY0=$(field "$GB0" y)
  "$XDO" keydown Alt_L drag $((BX0+50)) $((BY0+50)) $((BX0+70)) $((BY0+60)) keyup Alt_L; sec 0.6
  GB1=$(absgeom "$B")
  [ "$(field "$GB1" x)" -eq $((BX0+20)) ] && [ "$(field "$GB1" y)" -eq $((BY0+10)) ]; check "Alt+drag still works with $LK toggled ($GB0 -> $GB1)" $?
  "$XDO" key $LK; sec
done

echo "== 7. resize: edge/corner drag, minimum size honoured"
stop_clients
newwin r -t "Resize me" -w 300 -h 200 -c 8844cc -s 90 -p 300,250 -m 200,150
R=$LAST_ID
# bottom-right corner of the frame: client (300,250) size 300x200 -> frame right edge x=605+? frame: x 295..605, y 231..455
"$XDO" drag 603 453 663 493; sec 0.6
GR=$(absgeom "$R")
[ "$(field "$GR" w)" -eq 360 ] && [ "$(field "$GR" h)" -eq 240 ]; check "SE corner drag grew client to 360x240 (got $GR)" $?
# left edge drag to the right far past the minimum width: client must stop at min 200
GR0=$(absgeom "$R"); RX=$(field "$GR0" x); RY=$(field "$GR0" y)
"$XDO" drag $((RX-3)) $((RY+60)) $((RX+400)) $((RY+60)); sec 0.6
GR=$(absgeom "$R")
[ "$(field "$GR" w)" -eq 200 ]; check "left-edge drag stops at min width 200 (got $GR)" $?
grep -q 'ConfigureNotify x=.* w=200 h=240 synthetic=1' "$TMP/r.log"; check "client was told its size with a synthetic ConfigureNotify" $?

echo "== 8. close button sends WM_DELETE_WINDOW and the client exits cleanly"
GR=$(absgeom "$R"); RX=$(field "$GR" x); RY=$(field "$GR" y); RW=$(field "$GR" w)
# close button: right group ends at frame right - 5(border) - 1(offset); close is the last, 24 wide: its centre is ~12 left of that
"$XDO" move $((RX+RW+M-1-12)) $((RY-T+8)) click 1; sec 0.8
grep -q WM_DELETE_WINDOW "$TMP/r.log"; check "testwin received WM_DELETE_WINDOW" $?
sleep 0.5; kill -0 "$PID_r" 2>/dev/null; [ $? -ne 0 ]; check "testwin exited after close" $?
wmctrl -l | grep -q 'Resize me'; [ $? -ne 0 ]; check "closed window removed from client list" $?

echo "== 9. maximize button / double-click toggles"
newwin m -t "Maximize" -w 300 -h 200 -c cc3333 -s 90 -p 300,250
MX=$LAST_ID
GM0=$(absgeom "$MX"); MXX=$(field "$GM0" x); MYY=$(field "$GM0" y)
# maximize button is third from the right: S H M C ; centre of M ~ right - 1 - 24 - 12 + (overlap 1)
"$XDO" move $((MXX+300+M-1-24+1-12)) $((MYY-T+8)) click 1; sec 0.8
GM1=$(absgeom "$MX")
[ "$(field "$GM1" w)" -eq $((1280-2*M)) ] && [ "$(field "$GM1" h)" -eq $((800-T-M)) ]; check "maximize fills the work area (got $GM1)" $?
xprop -id "$MX" _NET_WM_STATE | grep -q MAXIMIZED_VERT; check "_NET_WM_STATE has MAXIMIZED_VERT" $?
"$XDO" move 640 $((T/2)) click 1 click 1; sec 0.8
GM2=$(absgeom "$MX")
[ "$(field "$GM2" w)" -eq 300 ] && [ "$(field "$GM2" x)" -eq "$MXX" ]; check "double-click on titlebar restores the old geometry (got $GM2)" $?

echo "== 10. title change repaints the frame"
stop_clients
newwin t -t "Before" -w 300 -h 200 -c 336699 -s 90 -p 300,250 -T "After the change,6"
import -window root "$TMP/t1.png" 2>/dev/null
sleep 6; import -window root "$TMP/t2.png" 2>/dev/null
D=$(compare -metric AE "$TMP/t1.png" "$TMP/t2.png" null: 2>&1 | head -1 | awk '{printf "%d", $1}')
[ "${D:-0}" -gt 100 ]; check "screen differs after the title changed (AE=$D)" $?

echo "== 11. frame matches the reference rendered by real xfwm4"
stop_clients
newwin ref -t "Other window" -w 300 -h 200 -c 00ffff -s 90 -p 605,419
sleep 0.5; import -window root "$TMP/full.png" 2>/dev/null
magick "$TMP/full.png" -crop 310x224+600+400 +repage "$TMP/frame.png"
AE=$(compare -metric AE -fuzz 3% "$TMP/frame.png" "$ROOT/ref/frame-active-310x224.png" null: 2>&1 | head -1 | awk '{printf "%d", $1}')
[ "${AE:-99999}" -lt 700 ]; check "live frame vs xfwm4 reference: $AE of 69440 px differ (icon + glyph AA expected, limit 700)" $?
cp "$TMP/frame.png" "$ROOT/out/live-frame-active.png" 2>/dev/null

echo "== 12. killing the WM leaves clients mapped"
stop_clients
newwin k -t "Survivor" -w 300 -h 200 -c 999999 -s 90 -p 500,300
K=$LAST_ID
kill -KILL "$WMPID"; wait "$WMPID" 2>/dev/null; sleep 0.8
"$XG" | grep -q "win=$(printf '0x%X' "$(printf '%d' "$K")").*viewable=1"; check "client is a viewable top-level window after SIGKILL of the WM (save-set)" $?
start_wm
sleep 0.5; "$XG" | grep -q "name=\"Survivor\""; check "a restarted WM adopts it again" $?
stop_wm
stop_clients
echo "== 13. keyboard: Alt+F4 closes the focused window"
start_wm
stop_clients
newwin f4 -t "Alt F4" -w 300 -h 200 -c 559955 -s 60 -p 400,300
"$XDO" keydown Alt_L key F4 keyup Alt_L; sec 0.8
grep -q WM_DELETE_WINDOW "$TMP/f4.log"; check "Alt+F4 sent WM_DELETE_WINDOW to the focused window" $?

echo "== 14. keyboard: Super+Return toggles maximize"
newwin sr -t "Super Return" -w 300 -h 200 -c 995599 -s 60 -p 400,300
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.8
G=$(absgeom "$LAST_ID"); [ "$(field "$G" w)" -eq $((1280-2*M)) ]; check "Super+Return maximizes ($G)" $?
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.8
G=$(absgeom "$LAST_ID"); [ "$(field "$G" w)" -eq 300 ]; check "Super+Return restores ($G)" $?
stop_clients

echo "== 15. keyboard: Alt+Tab cycles in most-recently-used order"
newwin p -t "P" -w 200 -h 150 -c aa0000 -s 120 -p 100,100; P=$LAST_ID
newwin q -t "Q" -w 200 -h 150 -c 00aa00 -s 120 -p 400,100; Q=$LAST_ID
newwin r -t "R" -w 200 -h 150 -c 0000aa -s 120 -p 700,100; R=$LAST_ID
[ "$(hexnorm "$(active)")" = "$(hexnorm "$R")" ]; check "last mapped window (R) is active" $?
"$XDO" keydown Alt_L key Tab keyup Alt_L; sec 0.5
[ "$(hexnorm "$(active)")" = "$(hexnorm "$Q")" ]; check "Alt+Tab: R -> Q" $?
"$XDO" keydown Alt_L key Tab keyup Alt_L; sec 0.5
[ "$(hexnorm "$(active)")" = "$(hexnorm "$R")" ]; check "Alt+Tab again swaps back: Q -> R" $?
"$XDO" keydown Alt_L key Tab key Tab keyup Alt_L; sec 0.5
[ "$(hexnorm "$(active)")" = "$(hexnorm "$P")" ]; check "Alt held, Tab twice reaches the third window (P)" $?
"$XDO" keydown Alt_L keydown Shift_L key Tab keyup Shift_L keyup Alt_L; sec 0.5
[ "$(hexnorm "$(active)")" = "$(hexnorm "$R")" ]; check "Alt+Shift+Tab goes backwards to the least recent (R)" $?
"$XDO" key a; sec 0.3
grep -q KeyPress "$TMP/r.log"; check "keyboard was released after cycling (plain key reaches the focused app)" $?
stop_clients

echo "== 16. fullscreen: wmctrl request and Alt+F11"
newwin fs -t "Fullscreen" -w 300 -h 200 -c 227799 -s 90 -p 400,300; FS=$LAST_ID
wmctrl -i -r "$FS" -b add,fullscreen; sec 0.8
G=$(absgeom "$FS")
[ "$(field "$G" x)" -eq 0 ] && [ "$(field "$G" y)" -eq 0 ] && [ "$(field "$G" w)" -eq 1280 ] && [ "$(field "$G" h)" -eq 800 ]; check "fullscreen covers the whole screen ($G)" $?
xprop -id "$FS" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "frame extents are zero while fullscreen" $?
xprop -id "$FS" _NET_WM_STATE | grep -q FULLSCREEN; check "_NET_WM_STATE has FULLSCREEN" $?
wmctrl -i -r "$FS" -b remove,fullscreen; sec 0.8
G=$(absgeom "$FS"); [ "$(field "$G" x)" -eq 400 ] && [ "$(field "$G" w)" -eq 300 ]; check "leaving fullscreen restores geometry ($G)" $?
xprop -id "$FS" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M"; check "frame extents restored" $?
"$XDO" keydown Alt_L key F11 keyup Alt_L; sec 0.8
G=$(absgeom "$FS"); [ "$(field "$G" w)" -eq 1280 ]; check "Alt+F11 enters fullscreen ($G)" $?
"$XDO" keydown Alt_L key F11 keyup Alt_L; sec 0.8
G=$(absgeom "$FS"); [ "$(field "$G" w)" -eq 300 ]; check "Alt+F11 leaves fullscreen ($G)" $?
stop_clients

echo "== 17. iconify: H button, Alt+F9, WM_CHANGE_STATE, restore via _NET_ACTIVE_WINDOW and Alt+Tab"
newwin base -t "Base" -w 200 -h 150 -c 444444 -s 120 -p 100,500; BASE=$LAST_ID
newwin ic -t "Iconify me" -w 300 -h 200 -c 774477 -s 120 -p 500,300; IC=$LAST_ID
G=$(absgeom "$IC"); RX=$(field "$G" x); RY=$(field "$G" y); RW=$(field "$G" w)
"$XDO" move $((RX+RW-59)) $((RY-T+8)) click 1; sec 0.8
[ "$(viewable "$IC")" = "0" ]; check "H button hides the window" $?
[ "$(wmstate "$IC")" = "Iconic" ]; check "WM_STATE is Iconic" $?
xprop -id "$IC" _NET_WM_STATE | grep -q HIDDEN; check "_NET_WM_STATE has HIDDEN" $?
[ "$(hexnorm "$(active)")" = "$(hexnorm "$BASE")" ]; check "focus moved to the next window" $?
grep -q UnmapNotify "$TMP/ic.log"; check "client saw the unmap (so it knows it is iconic)" $?
wmctrl -i -a "$IC"; sec 0.8
[ "$(viewable "$IC")" = "1" ] && [ "$(wmstate "$IC")" = "Normal" ]; check "_NET_ACTIVE_WINDOW restores it" $?
[ "$(hexnorm "$(active)")" = "$(hexnorm "$IC")" ]; check "restored window is active" $?
"$XDO" keydown Alt_L key F9 keyup Alt_L; sec 0.8
[ "$(viewable "$IC")" = "0" ]; check "Alt+F9 hides the focused window" $?
"$XDO" keydown Alt_L key Tab keyup Alt_L; sec 0.8   
[ "$(viewable "$IC")" = "1" ] && [ "$(hexnorm "$(active)")" = "$(hexnorm "$IC")" ]; check "Alt+Tab reaches the iconic window, restores and focuses it" $?
stop_clients
newwin ic2 -t "Self iconify" -w 300 -h 200 -c 337733 -s 30 -p 500,300 -i 1; IC2=$LAST_ID
sleep 1.6
[ "$(viewable "$IC2")" = "0" ] && [ "$(wmstate "$IC2")" = "Iconic" ]; check "WM_CHANGE_STATE (XIconifyWindow from the app) iconifies" $?
stop_clients

echo "== 18. transient dialogs: centred on parent, stay above, focus returns on close"
newwin par -t "Parent" -w 400 -h 300 -c 3a5f8a -s 120 -p 300,200; PAR=$LAST_ID
newwin dlg -t "Dialog" -w 200 -h 100 -c e0c050 -s 120 -P "$PAR"; DLG=$LAST_ID
G=$(absgeom "$DLG"); DX=$(field "$G" x); DY=$(field "$G" y)
[ "$DX" -ge 399 ] && [ "$DX" -le 401 ] && [ "$DY" -ge 299 ] && [ "$DY" -le 301 ]; check "dialog is centred over its parent (client at $DX,$DY, expected 400,300)" $?
[ "$(hexnorm "$(active)")" = "$(hexnorm "$DLG")" ]; check "dialog gets focus" $?
"$XDO" move 310 240 click 1; sec 0.5      # click the parent, away from the dialog
[ "$(hexnorm "$(active)")" = "$(hexnorm "$PAR")" ]; check "clicking the parent focuses it" $?
[ "$(stackpos "$DLG")" -gt "$(stackpos "$PAR")" ]; check "dialog is still stacked above its raised parent (dlg=$(stackpos "$DLG") par=$(stackpos "$PAR"))" $?
"$XDO" move 500 360 click 1; sec 0.4       # focus the dialog again
"$XDO" keydown Alt_L key F4 keyup Alt_L; sec 0.8
grep -q WM_DELETE_WINDOW "$TMP/dlg.log"; check "Alt+F4 closed the dialog" $?
[ "$(hexnorm "$(active)")" = "$(hexnorm "$PAR")" ]; check "focus returns to the parent after the dialog closes" $?
stop_clients
echo "== 19. stacking layers: desktop window at the bottom, panel-like dock on top, conky-like dock below normal windows"
newwin dk -t "Fake panel" -w 400 -h 40 -c 111111 -s 120 -p 0,760 -y dock; DK=$LAST_ID
newwin bl -t "Fake conky" -w 200 -h 300 -c 225522 -s 120 -p 900,50 -y dockbelow; BL=$LAST_ID
newwin ds -t "Fake desktop" -w 1280 -h 800 -c 202030 -s 120 -p 0,0 -y desktop; DS=$LAST_ID    # mapped last, like pcmanfm-desktop
newwin nm -t "Normal window" -w 400 -h 300 -c aa7733 -s 120 -p 880,30; NM=$LAST_ID
"$XDO" move 900 100 click 1; sec 0.5
[ "$(toppos "$DS")" -lt "$(toppos "$BL")" ]; check "desktop window is below the conky-like dock (ds=$(toppos "$DS") bl=$(toppos "$BL"))" $?
[ "$(toppos "$BL")" -lt "$(stackpos "$NM")" ]; check "conky-like dock is below normal windows (bl=$(toppos "$BL") nm=$(stackpos "$NM"))" $?
[ "$(stackpos "$NM")" -lt "$(toppos "$DK")" ]; check "panel-like dock is above normal windows (nm=$(stackpos "$NM") dk=$(toppos "$DK"))" $?
[ "$(toppos "$DS")" -le 3 ]; check "desktop window is at the very bottom (index $(toppos "$DS"))" $?
wmctrl -i -r "$NM" -b add,fullscreen; sec 0.6
[ "$(stackpos "$NM")" -gt "$(toppos "$DK")" ]; check "a fullscreen window covers the panel-like dock" $?
wmctrl -i -r "$NM" -b remove,fullscreen; sec 0.6
[ "$(stackpos "$NM")" -lt "$(toppos "$DK")" ]; check "panel-like dock is back on top after leaving fullscreen" $?
stop_clients

stop_wm

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
