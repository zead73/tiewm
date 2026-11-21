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
# never read the real ~/.config/tiewm/tiewm.conf: tests use defaults unless a scenario says otherwise
export TIEWM_CONFIG="$TMP/none.conf"
rm -f "$TMP/none.conf"
# and never write the real ~/.local/state/tiewm/tiewm.log
export TIEWM_LOG="$TMP/tiewm.log"
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
  if [ ! -e /tmp/.X11-unix/X99 ]; then
    Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
    sleep 1
  fi
}
start_wm() { "$WM" 2>"$TMP/wm.log" & WMPID=$!; sleep 0.8; }
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
[ "$(stackpos "$DLG")" -gt "$(stackpos "$PAR")" ]; RC=$?; check "dialog is still stacked above its raised parent (dlg=$(stackpos "$DLG") par=$(stackpos "$PAR"))" $RC
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
[ "$(toppos "$DS")" -lt "$(toppos "$BL")" ]; RC=$?; check "desktop window is below the conky-like dock (ds=$(toppos "$DS") bl=$(toppos "$BL"))" $RC
[ "$(toppos "$BL")" -lt "$(stackpos "$NM")" ]; RC=$?; check "conky-like dock is below normal windows (bl=$(toppos "$BL") nm=$(stackpos "$NM"))" $RC
[ "$(stackpos "$NM")" -lt "$(toppos "$DK")" ]; RC=$?; check "panel-like dock is above normal windows (nm=$(stackpos "$NM") dk=$(toppos "$DK"))" $RC
[ "$(toppos "$DS")" -le 3 ]; RC=$?; check "desktop window is at the very bottom (index $(toppos "$DS"))" $RC
wmctrl -i -r "$NM" -b add,fullscreen; sec 0.6
[ "$(stackpos "$NM")" -gt "$(toppos "$DK")" ]; check "a fullscreen window covers the panel-like dock" $?
wmctrl -i -r "$NM" -b remove,fullscreen; sec 0.6
[ "$(stackpos "$NM")" -lt "$(toppos "$DK")" ]; check "panel-like dock is back on top after leaving fullscreen" $?
stop_clients

echo "== 20. workspaces: 4 desktops, switch/move/sticky/activate, Alt+Tab stays on the desktop, Ctrl+Alt+arrows"
cur() { xprop -root _NET_CURRENT_DESKTOP | sed 's/.*= //'; }
deskof() { xprop -id "$1" _NET_WM_DESKTOP | sed 's/.*= //'; }
noactive() { xprop -root _NET_ACTIVE_WINDOW | grep -q 'not found'; }
[ "$(wmctrl -d | wc -l)" = "4" ] && [ "$(cur)" = "0" ]; check "4 desktops, starting on desktop 0" $?
xprop -root _NET_DESKTOP_NAMES | grep -q 'Workspace 1.*Workspace 4'; check "_NET_DESKTOP_NAMES set" $?
newwin w1 -t "W1" -w 300 -h 200 -c 884400 -s 300 -p 100,100; W1=$LAST_ID
[ "$(deskof "$W1")" = "0" ]; check "new window lands on the current desktop (0)" $?
wmctrl -s 1; sec 0.6
[ "$(cur)" = "1" ] && [ "$(viewable "$W1")" = "0" ]; check "switching to desktop 1 hides W1" $?
noactive; check "no window is active on the empty desktop" $?
newwin w2 -t "W2" -w 300 -h 200 -c 008844 -s 300 -p 500,100; W2=$LAST_ID
[ "$(deskof "$W2")" = "1" ] && [ "$(viewable "$W2")" = "1" ]; check "window created on desktop 1 belongs to desktop 1" $?
[ "$(hexnorm "$(active)")" = "$(hexnorm "$W2")" ]; check "and gets focus" $?
wmctrl -s 0; sec 0.6
[ "$(viewable "$W1")" = "1" ] && [ "$(viewable "$W2")" = "0" ]; check "back on desktop 0: W1 shown, W2 hidden" $?
[ "$(hexnorm "$(active)")" = "$(hexnorm "$W1")" ]; check "focus returns to W1 (most recent on that desktop)" $?
wmctrl -i -r "$W1" -t 2; sec 0.6
[ "$(deskof "$W1")" = "2" ] && [ "$(viewable "$W1")" = "0" ]; check "moving W1 to desktop 2 hides it and updates _NET_WM_DESKTOP" $?
wmctrl -i -a "$W1"; sec 0.8
[ "$(cur)" = "2" ] && [ "$(viewable "$W1")" = "1" ] && [ "$(hexnorm "$(active)")" = "$(hexnorm "$W1")" ]; check "activating a window on another desktop switches to it" $?
wmctrl -i -r "$W2" -b add,sticky; sec 0.6
[ "$(deskof "$W2")" = "4294967295" ] && xprop -id "$W2" _NET_WM_STATE | grep -q STICKY; check "sticky: desktop becomes 0xFFFFFFFF and STATE_STICKY is set" $?
wmctrl -s 3; sec 0.6
[ "$(viewable "$W2")" = "1" ] && [ "$(viewable "$W1")" = "0" ]; check "sticky window follows to desktop 3, W1 stays behind" $?
newwin dkw -t "Fake panel" -w 400 -h 40 -c 111111 -s 300 -p 0,760 -y dock; DKW=$LAST_ID
wmctrl -s 0; sec 0.5
"$XG" | grep -q "win=$(printf '0x%X' "$(printf '%d' "$DKW")") .*viewable=1"; check "dock windows are visible on every desktop" $?
stop_clients
wmctrl -s 0; sec 0.4
newwin x -t "X" -w 200 -h 150 -c 555500 -s 300 -p 100,100; X=$LAST_ID
newwin y -t "Y" -w 200 -h 150 -c 005555 -s 300 -p 400,100; Y=$LAST_ID
newwin z -t "Z" -w 200 -h 150 -c 550055 -s 300 -p 700,100; Z=$LAST_ID
wmctrl -i -r "$Z" -t 1; sec 0.5
"$XDO" keydown Alt_L key Tab keyup Alt_L; sec 0.5
[ "$(cur)" = "0" ] && [ "$(hexnorm "$(active)")" = "$(hexnorm "$X")" ]; check "Alt+Tab cycles only this desktop's windows (Z on desktop 1 is skipped)" $?
"$XDO" keydown Control_L keydown Alt_L key Right keyup Alt_L keyup Control_L; sec 0.6
[ "$(cur)" = "1" ] && [ "$(viewable "$Z")" = "1" ]; check "Ctrl+Alt+Right goes to desktop 1" $?
"$XDO" keydown Control_L keydown Alt_L key Left keyup Alt_L keyup Control_L; sec 0.6
[ "$(cur)" = "0" ]; check "Ctrl+Alt+Left goes back to desktop 0" $?
"$XDO" keydown Control_L keydown Alt_L key Left keyup Alt_L keyup Control_L; sec 0.6
[ "$(cur)" = "0" ]; check "no wrap-around past desktop 0" $?
FOC=$(hexnorm "$(active)")
"$XDO" keydown Control_L keydown Alt_L keydown Shift_L key Right keyup Shift_L keyup Alt_L keyup Control_L; sec 0.8
[ "$(cur)" = "1" ] && [ "$(deskof "$FOC")" = "1" ] && [ "$(viewable "$FOC")" = "1" ] && [ "$(hexnorm "$(active)")" = "$FOC" ]; check "Ctrl+Alt+Shift+Right moves the focused window to desktop 1 and follows it" $?
wmctrl -s 0; sec 0.4
stop_clients

echo "== 21. config file: parsing, warnings, theme/desktops/key overrides, SIGHUP reload, env override"
cat >"$TMP/c1.conf" <<'EOC'
# test config
theme = Kokodi
desktops = 2
title_align = center
[colors]
active_color_1 = #aa3300
[keys]
close = Super+q
cycle = Super+Tab, Alt+Tab
cycle_back = none
iconify = none
goto_desktop_2 = Alt+2
EOC
cat >"$TMP/c2.conf" <<'EOC'
bogus_setting = 1
desktops = 99
title_align = diagonal
nonsense line
[colors]
active_color_1 = blue
[keys]
close = Hyper+F4
frobnicate = Alt+F1
maximize = Alt+F4
[nowhere]
EOC
OUT=$("$WM" --check-config "$TMP/none.conf" 2>&1); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q 'not found, using defaults' && echo "$OUT" | grep -q 'key close = Alt+F4' && echo "$OUT" | grep -q 'key move_right = Ctrl+Alt+Shift+Right'; check "--check-config with no file: defaults, exit 0" $?
OUT=$("$WM" --check-config "$TMP/c1.conf" 2>&1); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q 'theme = Kokodi' && echo "$OUT" | grep -q 'desktops = 2' && echo "$OUT" | grep -q 'title_align = center' && echo "$OUT" | grep -q 'active_color_1 = #AA3300'; check "--check-config reads general and colour settings" $?
echo "$OUT" | grep -q 'key close = Super+q' && echo "$OUT" | grep -q 'key iconify = (none)' && echo "$OUT" | grep -q 'key cycle_back = (none)' && echo "$OUT" | grep -q 'key cycle = Super+Tab' && echo "$OUT" | grep -q 'key goto_desktop_2 = Alt+2' && echo "$OUT" | grep -q 'key maximize = Super+Return'; check "key overrides replace per action; unlisted actions keep their defaults" $?
OUT=$("$WM" --check-config "$TMP/c2.conf" 2>&1); RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -q 'line 1: unknown setting' && echo "$OUT" | grep -q 'line 2: desktops must be 1..20' && echo "$OUT" | grep -q 'line 3: title_align' && echo "$OUT" | grep -q 'line 4: expected' && echo "$OUT" | grep -q 'line 6: .*colour' && echo "$OUT" | grep -q 'line 8: cannot parse key combination "Hyper+F4"' && echo "$OUT" | grep -q 'line 9: unknown key action' && echo "$OUT" | grep -q 'line 11: unknown section'; check "bad config: exit 1 and a warning per problem with its line number" $?
echo "$OUT" | grep -q 'line 10: Alt+F4 is already bound to'; check "a combination bound twice is reported (first binding wins)" $?

stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/c2.conf"; start_wm
newwin cfg2 -t "Broken config" -w 300 -h 200 -c 4466aa -s 60 -p 400,300
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M" && [ "$(wmctrl -d | wc -l)" = "4" ]; check "a broken config still starts with the defaults (Daloa, 4 desktops)" $?
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/c1.conf"; start_wm
newwin cfg1 -t "Custom config" -w 300 -h 200 -c 66aa44 -s 90 -p 400,300; C1=$LAST_ID
xprop -id "$C1" _NET_FRAME_EXTENTS | grep -q "= 6, 6, 29, 6"; check "theme = Kokodi: frame extents come from that theme (6,6,29,6)" $?
[ "$(wmctrl -d | wc -l)" = "2" ]; check "desktops = 2" $?
"$XDO" keydown Alt_L key F4 keyup Alt_L; sec 0.6
! grep -q WM_DELETE_WINDOW "$TMP/cfg1.log"; check "Alt+F4 no longer closes (close was rebound)" $?
"$XDO" keydown Super_L key q keyup Super_L; sec 0.8
grep -q WM_DELETE_WINDOW "$TMP/cfg1.log"; check "Super+q closes (new binding)" $?
newwin cfg3 -t "Second" -w 300 -h 200 -c aa4466 -s 90 -p 700,300; C3=$LAST_ID
newwin cfg4 -t "Third" -w 300 -h 200 -c 44aaaa -s 90 -p 100,500; C4=$LAST_ID
"$XDO" keydown Alt_L key F9 keyup Alt_L; sec 0.6
[ "$(viewable "$C4")" = "1" ]; check "iconify = none: Alt+F9 does nothing" $?
"$XDO" keydown Super_L key Tab keyup Super_L; sec 0.5
[ "$(hexnorm "$(active)")" = "$(hexnorm "$C3")" ]; check "cycle = Super+Tab: cycling starts with Super and ends when it is released" $?
"$XDO" key a; sec 0.3
grep -q KeyPress "$TMP/cfg3.log"; check "keyboard released after Super+Tab (a plain key reaches the focused app)" $?
"$XDO" keydown Alt_L key 2 keyup Alt_L; sec 0.6
[ "$(cur)" = "1" ]; check "goto_desktop_2 = Alt+2 switches to desktop 2" $?
"$XDO" keydown Alt_L key F4 keyup Alt_L; sec 0.3
cat >"$TMP/c1.conf" <<'EOC'
theme = Kokodi
desktops = 2
[keys]
close = Alt+F4
EOC
kill -HUP "$WMPID"; sec 0.8
wmctrl -s 0; sec 0.5
"$XDO" move 150 600 click 1; sec 0.4
"$XDO" keydown Alt_L key F4 keyup Alt_L; sec 0.8
grep -q WM_DELETE_WINDOW "$TMP/cfg4.log"; check "SIGHUP reloads the key bindings (Alt+F4 closes again, no restart)" $?
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/c1.conf"; TIEWM_DESKTOPS=3 start_wm
[ "$(wmctrl -d | wc -l)" = "3" ]; check "TIEWM_DESKTOPS in the environment overrides the file" $?
stop_wm; stop_clients
printf 'theme = NoSuchTheme\n' >"$TMP/c3.conf"; export TIEWM_CONFIG="$TMP/c3.conf"; start_wm
newwin cfg5 -t "Bad theme" -w 300 -h 200 -c 8866cc -s 60 -p 400,300
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M"; check "an unknown theme falls back to Daloa instead of failing" $?
grep -q 'not found, using Daloa' "$TMP/wm.log"; check "and says so on stderr" $?
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm

echo "== 22. log file: startup/manage/shutdown lines, rotation, level off, config warnings, debug mirror"
stop_wm; stop_clients
rm -f "$TMP/log22.log" "$TMP/log22.log.1"
export TIEWM_CONFIG="$TMP/none.conf" TIEWM_LOG="$TMP/log22.log"; start_wm
newwin lg -t "Log me" -w 300 -h 200 -c 336633 -s 60 -p 400,300
sec 0.4
grep -q 'tiewm .* starting on :99 (theme Daloa, 4 desktops' "$TMP/log22.log"; check "log has a startup line" $?
grep -q 'config: none' "$TMP/log22.log" && grep -q 'managing the display' "$TMP/log22.log"; check "log says which config it used and that it is managing" $?
grep -q 'managed 0x[0-9A-Fa-f]* "Log me"' "$TMP/log22.log"; check "log records a managed window with its title" $?
stop_wm; sleep 0.5
grep -q 'shutting down' "$TMP/log22.log" && grep -q ' bye' "$TMP/log22.log"; check "clean shutdown is logged" $?
stop_clients
head -c 600000 /dev/zero | tr '\0' 'x' | fold -w 100 >"$TMP/log22.log"
start_wm; sleep 0.4
[ -f "$TMP/log22.log.1" ] && [ "$(stat -c %s "$TMP/log22.log")" -lt 10000 ]; check "a log over 512 KiB is rotated to .1 at start" $?
stop_wm
printf 'log_level = off\nlog_file = %s\n' "$TMP/off.log" >"$TMP/c4.conf"; rm -f "$TMP/off.log"
export TIEWM_CONFIG="$TMP/c4.conf"; unset TIEWM_LOG; start_wm; sleep 0.4
[ ! -e "$TMP/off.log" ]; check "log_level = off writes no file" $?
stop_wm
printf 'bogus = 1\nlog_file = %s\n' "$TMP/warn.log" >"$TMP/c5.conf"; rm -f "$TMP/warn.log"
export TIEWM_CONFIG="$TMP/c5.conf"; start_wm; sleep 0.4
grep -q 'config warning: line 1: unknown setting' "$TMP/warn.log"; check "config warnings go to the log file (log_file from the config)" $?
stop_wm
export TIEWM_CONFIG="$TMP/none.conf" TIEWM_LOG="$TMP/log22.log"; rm -f "$TMP/log22.log"
TIEWM_DEBUG=1 start_wm; sleep 0.4
grep -q 'starting on' "$TMP/wm.log"; check "TIEWM_DEBUG mirrors the log to stderr" $?
stop_wm
export TIEWM_CONFIG="$TMP/none.conf" TIEWM_LOG="$TMP/tiewm.log"
start_wm

echo "== 23. window menu (keyboard and mouse) and always-on-top"
menuinfo() { "$XG" | grep 'name="tiewm-menu"' | head -1; }
menuopen() { menuinfo | grep -q 'viewable=1'; }
stop_clients
newwin mn -t "Menu test" -w 300 -h 200 -c 7733aa -s 300 -p 400,300; MN=$LAST_ID
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.6
menuopen; check "Alt+space opens the window menu" $?
"$XDO" key Escape; sec 0.5
! menuopen; check "Escape closes it" $?
"$XDO" key a; sec 0.3
grep -q KeyPress "$TMP/mn.log"; check "the keyboard is released after the menu closes" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Return; sec 0.8
G=$(absgeom "$MN"); [ "$(field "$G" w)" -eq $((1280-2*M)) ]; check "menu: Maximize (2nd item) maximizes ($G)" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Return; sec 0.8
G=$(absgeom "$MN"); [ "$(field "$G" w)" -eq 300 ]; check "menu: the same item now says Restore and restores ($G)" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Return; sec 0.8
xprop -id "$MN" _NET_WM_STATE | grep -q ABOVE; check "menu: Always on top sets _NET_WM_STATE_ABOVE" $?
newwin ot -t "Other" -w 300 -h 200 -c 227733 -s 300 -p 100,500; OT=$LAST_ID
"$XDO" move 150 600 click 1; sec 0.5
[ "$(stackpos "$MN")" -gt "$(stackpos "$OT")" ]; RC=$?; check "an always-on-top window stays above a window that was just raised (mn=$(stackpos "$MN") ot=$(stackpos "$OT"))" $RC
"$XDO" move 500 420 click 1; sec 0.4
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Return; sec 0.8
! xprop -id "$MN" _NET_WM_STATE | grep -q ABOVE; check "menu: Always on top toggles off again" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Return; sec 0.8
[ "$(deskof "$MN")" = "4294967295" ]; check "menu: On all workspaces makes the window sticky" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Return; sec 0.8
[ "$(deskof "$MN")" = "0" ]; check "menu: and toggles it back to the current desktop" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5
"$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.8
[ "$(deskof "$MN")" = "2" ] && [ "$(viewable "$MN")" = "0" ]; check "menu: Move to Workspace 3 (the current one is disabled and skipped)" $?
wmctrl -s 0; stop_clients; sec 0.3
newwin mm -t "Mouse menu" -w 300 -h 200 -c aa5522 -s 120 -p 500,300; MM=$LAST_ID
G=$(absgeom "$MM"); RX=$(field "$G" x); RY=$(field "$G" y)
"$XDO" move $((RX+60)) $((RY-T+8)) click 3; sec 0.7
menuopen; check "right-click on the titlebar opens the menu" $?
I=$(menuinfo); MX=$(echo "$I" | sed -n 's/.* x=\([0-9-]*\) .*/\1/p'); MY=$(echo "$I" | sed -n 's/.* y=\([0-9-]*\) .*/\1/p'); MW=$(echo "$I" | sed -n 's/.* w=\([0-9]*\) .*/\1/p'); MH=$(echo "$I" | sed -n 's/.* h=\([0-9]*\) .*/\1/p')
"$XDO" move 1200 700 click 1; sec 0.5
! menuopen; check "a click outside closes the menu without doing anything" $?
[ "$(viewable "$MM")" = "1" ] && ! grep -q WM_DELETE_WINDOW "$TMP/mm.log"; check "and the window is untouched" $?
"$XDO" move $((RX-5+6+12)) $((RY-T+8)) click 1; sec 0.7
menuopen; check "clicking the O button opens the menu too" $?
I=$(menuinfo); MX=$(echo "$I" | sed -n 's/.* x=\([0-9-]*\) .*/\1/p'); MY=$(echo "$I" | sed -n 's/.* y=\([0-9-]*\) .*/\1/p'); MW=$(echo "$I" | sed -n 's/.* w=\([0-9]*\) .*/\1/p'); MH=$(echo "$I" | sed -n 's/.* h=\([0-9]*\) .*/\1/p')
"$XDO" move $((MX+MW/2)) $((MY+MH-8)) click 1; sec 0.8
grep -q WM_DELETE_WINDOW "$TMP/mm.log"; check "clicking the last row (Close) sends WM_DELETE_WINDOW" $?
! menuopen; check "the menu is gone after selecting" $?
stop_clients

echo "== 24. shade (button, menu, EWMH) and keyboard move/resize (Alt+F7 / Alt+F8)"
frameh() { "$XG" | awk -v id="$(printf '0x%X' "$(printf '%d' "$1")")" '/^win=/{top=$0} /^  win=/{ if ($1=="win="id) print top}' | sed -n 's/.* h=\([0-9]*\) .*/\1/p'; }
stop_clients
newwin sh -t "Shade me" -w 300 -h 200 -c 996633 -s 300 -p 500,300; SH=$LAST_ID
G=$(absgeom "$SH"); RX=$(field "$G" x); RY=$(field "$G" y); RW=$(field "$G" w)
"$XDO" move $((RX+RW-82)) $((RY-T+8)) click 1; sec 0.7
[ "$(frameh "$SH")" = "$T" ]; RC=$?; check "S button rolls the window up to its titlebar (frame height $(frameh "$SH"), expected $T)" $RC
xprop -id "$SH" _NET_WM_STATE | grep -q SHADED; check "_NET_WM_STATE has SHADED" $?
tail -3 "$TMP/sh.log" | grep -q 'ConfigureNotify .* w=300 h=200 synthetic=1'; check "the client is still told its real size (300x200), not the rolled-up one" $?
"$XDO" move $((RX+RW-82)) $((RY-T+8)) click 1; sec 0.7
[ "$(frameh "$SH")" = "$((200+T+M))" ]; RC=$?; check "S button again unrolls it (frame height $(frameh "$SH"))" $RC
! xprop -id "$SH" _NET_WM_STATE | grep -q SHADED; check "SHADED is gone again" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.8
[ "$(frameh "$SH")" = "$T" ]; check "window menu: Shade (7th item) shades" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.8
[ "$(frameh "$SH")" = "$((200+T+M))" ]; check "window menu: and unshades" $?
wmctrl -i -r "$SH" -b add,shaded; sec 0.6
[ "$(frameh "$SH")" = "$T" ]; check "wmctrl -b add,shaded shades (_NET_WM_STATE client message)" $?
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.8
G=$(absgeom "$SH"); [ "$(field "$G" h)" = "$((800-T-M))" ] && ! xprop -id "$SH" _NET_WM_STATE | grep -q SHADED; check "maximizing a shaded window unrolls it first ($G)" $?
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.6
stop_clients
newwin km -t "Key move" -w 300 -h 200 -c 336699 -s 300 -p 400,300 -m 200,150; KM=$LAST_ID
G0=$(absgeom "$KM"); X0=$(field "$G0" x); Y0=$(field "$G0" y); W0=$(field "$G0" w); H0=$(field "$G0" h)
"$XDO" keydown Alt_L key F7 keyup Alt_L key Right key Right key Down key Return; sec 0.6
G=$(absgeom "$KM"); [ "$(field "$G" x)" -eq $((X0+20)) ] && [ "$(field "$G" y)" -eq $((Y0+10)) ]; check "Alt+F7, Right Right Down, Return moves the window by +20,+10 ($G)" $?
"$XDO" keydown Alt_L key F7 keyup Alt_L key Left key Left key Up key Up key Escape; sec 0.6
G2=$(absgeom "$KM"); [ "$G2" = "$G" ]; check "Escape cancels a keyboard move (window back where it was)" $?
"$XDO" keydown Alt_L key F7 keyup Alt_L keydown Shift_L key Right keyup Shift_L key Return; sec 0.6
G=$(absgeom "$KM"); [ "$(field "$G" x)" -eq $((X0+21)) ]; check "Shift+arrow moves by one pixel" $?
"$XDO" key a; sec 0.3
grep -q KeyPress "$TMP/km.log"; check "keyboard released after the move ended" $?
"$XDO" keydown Alt_L key F8 keyup Alt_L key Right key Right key Down key Return; sec 0.6
G=$(absgeom "$KM"); [ "$(field "$G" w)" -eq $((W0+20)) ] && [ "$(field "$G" h)" -eq $((H0+10)) ]; check "Alt+F8, Right Right Down, Return grows the window by +20,+10 ($G)" $?
grep -q "w=$((W0+20)) h=$((H0+10)) synthetic" "$TMP/km.log"; check "the client was told about the new size" $?
"$XDO" keydown Alt_L key F8 keyup Alt_L key Right key Right key Right key Escape; sec 0.6
G2=$(absgeom "$KM"); [ "$(field "$G2" w)" -eq $((W0+20)) ]; check "Escape cancels a keyboard resize" $?
"$XDO" keydown Alt_L key F8 keyup Alt_L
for I in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do "$XDO" key Left; done
"$XDO" key Return; sec 0.6
G=$(absgeom "$KM"); [ "$(field "$G" w)" -eq 200 ]; check "keyboard resize stops at the window's minimum width (200)" $?
stop_clients

echo "== 25. always below: state, exclusive with above, stays under normal windows, layer order with desktop/conky"
newwin ds2 -t "Fake desktop" -w 1280 -h 800 -c 202030 -s 300 -p 0,0 -y desktop; DS2=$LAST_ID
newwin bl2 -t "Fake conky" -w 200 -h 300 -c 225522 -s 300 -p 1000,50 -y dockbelow; BL2=$LAST_ID
newwin bw -t "Below me" -w 300 -h 200 -c 5544aa -s 300 -p 400,300; BW=$LAST_ID
newwin nw -t "Normal" -w 300 -h 200 -c 44aa55 -s 300 -p 800,100; NW=$LAST_ID
wmctrl -i -r "$BW" -b add,below; sec 0.6
xprop -id "$BW" _NET_WM_STATE | grep -q BELOW; check "wmctrl -b add,below sets _NET_WM_STATE_BELOW" $?
"$XDO" move 500 400 click 1; sec 0.6
[ "$(stackpos "$BW")" -lt "$(stackpos "$NW")" ]; RC=$?; check "a below window stays under a normal one even right after being clicked (bw=$(stackpos "$BW") nw=$(stackpos "$NW"))" $RC
[ "$(toppos "$DS2")" -lt "$(toppos "$BL2")" ] && [ "$(toppos "$BL2")" -lt "$(stackpos "$BW")" ]; RC=$?; check "layers bottom to top: desktop < conky-like dock < below window (ds=$(toppos "$DS2") bl=$(toppos "$BL2") bw=$(stackpos "$BW"))" $RC
wmctrl -i -r "$BW" -b add,above; sec 0.6
xprop -id "$BW" _NET_WM_STATE | grep -q ABOVE && ! xprop -id "$BW" _NET_WM_STATE | grep -q BELOW; check "setting above clears below (they exclude each other)" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Return; sec 0.8
xprop -id "$BW" _NET_WM_STATE | grep -q BELOW && ! xprop -id "$BW" _NET_WM_STATE | grep -q ABOVE; check "window menu: Always below (5th item) sets below and clears above" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Return; sec 0.8
! xprop -id "$BW" _NET_WM_STATE | grep -q BELOW; check "window menu: and toggles it off" $?
stop_clients

echo "== 26. _MOTIF_WM_HINTS: windows that ask for no decorations get none (no titlebar, no borders)"
stop_clients
newwin nd -t "No decorations" -w 300 -h 200 -c cc6600 -s 300 -p 400,300 -D none; ND=$LAST_ID
xprop -id "$ND" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "decorations = 0: _NET_FRAME_EXTENTS are zero" $?
G=$(absgeom "$ND"); [ "$(field "$G" x)" -eq 400 ] && [ "$(field "$G" y)" -eq 300 ] && [ "$(frameh "$ND")" = "200" ]; RC=$?; check "the frame is exactly the client ($G, frame height $(frameh "$ND"))" $RC
import -window root "$TMP/nd.png" 2>/dev/null
[ "$(magick "$TMP/nd.png" -format '%[hex:p{410,299}]' info:)" = "000000" ] && [ "$(magick "$TMP/nd.png" -format '%[hex:p{410,300}]' info:)" = "CC6600" ]; check "nothing is drawn around the client (pixel above it is the bare root)" $?
grep -q '(no decorations)' "$TMP/tiewm.log"; check "the log says it was managed without decorations" $?
newwin dall -t "All decorations" -w 300 -h 200 -c 0066cc -s 300 -p 800,300 -D all; DALL=$LAST_ID
xprop -id "$DALL" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M"; check "decorations = ALL: normal frame" $?
newwin dnt -t "All but title" -w 300 -h 200 -c 66cc00 -s 300 -p 100,500 -D notitle; DNT=$LAST_ID
xprop -id "$DNT" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "ALL minus TITLE: no frame" $?
newwin dti -t "Title only" -w 300 -h 200 -c cc0066 -s 300 -p 500,500 -D title; DTI=$LAST_ID
xprop -id "$DTI" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M"; check "TITLE requested: normal frame" $?
newwin dbo -t "Border only" -w 200 -h 100 -c 00cccc -s 300 -p 1000,500 -D border; DBO=$LAST_ID
xprop -id "$DBO" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "BORDER only (no title): treated as undecorated" $?
stop_clients
newwin ndd -t "Dynamic on" -w 300 -h 200 -c aa66cc -s 300 -p 400,300 -D all -M none,2; NDD=$LAST_ID
G0=$(absgeom "$NDD")
xprop -id "$NDD" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M"; check "starts decorated" $?
sleep 2.6
G1=$(absgeom "$NDD")
xprop -id "$NDD" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0" && [ "$G0" = "$G1" ]; check "hints changed to none later: titlebar goes away and the client does not move ($G0 -> $G1)" $?
stop_clients
newwin ndn -t "Dynamic off" -w 300 -h 200 -c 66aacc -s 300 -p 400,300 -D none -M all,2; NDN=$LAST_ID
G0=$(absgeom "$NDN"); sleep 2.6; G1=$(absgeom "$NDN")
xprop -id "$NDN" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M" && [ "$G0" = "$G1" ]; check "hints changed to all later: titlebar comes back, client stays put ($G0 -> $G1)" $?
stop_clients
newwin u1 -t "Undecorated" -w 300 -h 200 -c cc6600 -s 300 -p 400,300 -D none; U1=$LAST_ID
newwin u2 -t "Normal" -w 300 -h 200 -c 0066cc -s 300 -p 800,300; U2=$LAST_ID
"$XDO" move 450 350 click 1; sec 0.5
[ "$(hexnorm "$(active)")" = "$(hexnorm "$U1")" ] && grep -q 'ButtonPress x=50 y=50' "$TMP/u1.log"; check "clicking an undecorated window focuses it and the click reaches the app" $?
G0=$(absgeom "$U1"); X0=$(field "$G0" x); Y0=$(field "$G0" y)
"$XDO" keydown Alt_L drag $((X0+50)) $((Y0+50)) $((X0+150)) $((Y0+100)) keyup Alt_L; sec 0.6
G=$(absgeom "$U1"); [ "$(field "$G" x)" -eq $((X0+100)) ] && [ "$(field "$G" y)" -eq $((Y0+50)) ]; check "Alt+drag moves an undecorated window ($G)" $?
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.8
G=$(absgeom "$U1"); [ "$(field "$G" x)" -eq 0 ] && [ "$(field "$G" y)" -eq 0 ] && [ "$(field "$G" w)" -eq 1280 ] && [ "$(field "$G" h)" -eq 800 ]; check "maximize fills the work area exactly, no border ($G)" $?
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.8
G=$(absgeom "$U1"); [ "$(field "$G" w)" -eq 300 ] && [ "$(field "$G" x)" -eq $((X0+100)) ]; check "and restores ($G)" $?
G0=$(absgeom "$U1")
wmctrl -i -r "$U1" -b add,fullscreen; sec 0.7
G=$(absgeom "$U1"); [ "$(field "$G" w)" -eq 1280 ] && [ "$(field "$G" h)" -eq 800 ]; check "fullscreen works on an undecorated window ($G)" $?
wmctrl -i -r "$U1" -b remove,fullscreen; sec 0.7
G=$(absgeom "$U1"); [ "$G" = "$G0" ] && xprop -id "$U1" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "leaving fullscreen returns it undecorated at the same place ($G)" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.6
menuopen; check "the window menu still opens (Alt+space)" $?
"$XDO" key Escape; sec 0.4
"$XDO" keydown Alt_L key F4 keyup Alt_L; sec 0.7
grep -q WM_DELETE_WINDOW "$TMP/u1.log"; check "Alt+F4 closes it" $?
stop_clients

echo "== 27. window menu: No titlebar toggle (the user's choice beats the app's own hints)"
stop_clients
newwin nt -t "Toggle me" -w 300 -h 200 -c 996600 -s 300 -p 400,300; NT=$LAST_ID
G0=$(absgeom "$NT")
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.8
G1=$(absgeom "$NT")
xprop -id "$NT" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0" && [ "$G0" = "$G1" ] && [ "$(frameh "$NT")" = "200" ]; check "menu: No titlebar (8th item) removes the frame and the client does not move ($G0 -> $G1)" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.8
G2=$(absgeom "$NT")
xprop -id "$NT" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M" && [ "$G0" = "$G2" ]; check "menu: the same entry (now checked; Shade is greyed out so it is the 7th enabled item) brings the titlebar back, client still in place ($G2)" $?
stop_clients
newwin top -t "At the top" -w 300 -h 200 -c 669900 -s 300 -p 700,0 -D none; TOP=$LAST_ID
G=$(absgeom "$TOP"); [ "$(field "$G" y)" -eq 0 ]; check "an undecorated window can sit at the very top (y=0)" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.8
G=$(absgeom "$TOP")
xprop -id "$TOP" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M" && [ "$(field "$G" y)" -eq "$T" ]; RC=$?; check "turning the titlebar on pushes the window down so the bar is visible (client y=$(field "$G" y), expected $T)" $RC
stop_clients
newwin ov -t "Override" -w 300 -h 200 -c 006699 -s 300 -p 400,300 -D all -M title,6; OV=$LAST_ID
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.8
xprop -id "$OV" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "user removed the titlebar of a window that asked for one" $?
sleep 5
grep -q 'motif hints changed to title' "$TMP/ov.log" && xprop -id "$OV" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "a later hint change from the app does not bring it back (the user's choice wins)" $?
grep -q 'titlebar off' "$TMP/tiewm.log"; check "the log records the toggle" $?
stop_clients

echo "== 28. window rules ([windows] in the config): parse, match by WM_CLASS, written by the menu toggle, file otherwise untouched"
stop_wm; stop_clients
cat >"$TMP/c6.conf" <<'EOC'
[windows]
# comment inside windows
testclass = no_titlebar
other = titlebar
broken = maybe
EOC
OUT=$("$WM" --check-config "$TMP/c6.conf" 2>&1); RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -q 'window testclass = no_titlebar' && echo "$OUT" | grep -q 'window other = titlebar' && echo "$OUT" | grep -q 'line 5: window rule for "broken"'; check "--check-config lists the rules and warns about a bad value" $?
export TIEWM_CONFIG="$TMP/c6.conf"; start_wm
newwin r1 -t "By class" -w 300 -h 200 -c aa3333 -s 60 -p 100,100 -C inst1,TestClass
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "rule no_titlebar applies to a window by its class (case-insensitive)" $?
newwin r2 -t "By instance" -w 300 -h 200 -c 33aa33 -s 60 -p 500,100 -C Testclass,Whatever
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "... or by its instance name" $?
newwin r3 -t "No rule" -w 300 -h 200 -c 3333aa -s 60 -p 100,400 -C zzz,Zzz
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M"; check "a window without a rule is decorated as usual" $?
newwin r4 -t "Rule beats the hint" -w 300 -h 200 -c aaaa33 -s 60 -p 500,400 -D none -C q,Other
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M"; check "rule titlebar overrides an app that asks for no decorations" $?
stop_wm; stop_clients
cat >"$TMP/c7.conf" <<'EOC'
# my comment at the top
theme = Daloa

[keys]
# keys comment
close = Alt+F4

[windows]
# existing rules
existing = no_titlebar

[colors]
# colours below
active_color_1 = #112233
EOC
cp "$TMP/c7.conf" "$TMP/c7.orig"
export TIEWM_CONFIG="$TMP/c7.conf"; start_wm
newwin w1 -t "Write rule" -w 300 -h 200 -c 3366aa -s 200 -p 400,300 -C appx,Fancy
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.9
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "menu toggle removes the titlebar" $?
grep -q '^Fancy = no_titlebar$' "$TMP/c7.conf"; check "and writes 'Fancy = no_titlebar' to the config" $?
[ "$(diff "$TMP/c7.orig" "$TMP/c7.conf" | grep -c '^[<>]')" = "1" ] && diff "$TMP/c7.orig" "$TMP/c7.conf" | grep -q '^> Fancy = no_titlebar$'; check "exactly one line was added; comments and other sections are untouched" $?
L1=$(grep -n '^existing' "$TMP/c7.conf" | cut -d: -f1); L2=$(grep -n '^Fancy' "$TMP/c7.conf" | cut -d: -f1); L3=$(grep -n '^\[colors\]' "$TMP/c7.conf" | cut -d: -f1)
[ "$L2" -gt "$L1" ] && [ "$L2" -lt "$L3" ]; check "the rule went into the [windows] section (line $L2 between $L1 and $L3)" $?
stop_clients
newwin w2 -t "Same class again" -w 300 -h 200 -c 66aa33 -s 200 -p 400,300 -C appx2,fancy
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "the next window of that class starts without a titlebar (no restart needed)" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.9
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M"; check "toggling back gives the titlebar again" $?
cmp -s "$TMP/c7.orig" "$TMP/c7.conf"; check "and the rule is removed: the file is byte-identical to the original" $?
stop_clients
newwin w3 -t "Persist" -w 300 -h 200 -c aa6633 -s 200 -p 400,300 -C appy,Persist
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.9
stop_wm; stop_clients
start_wm
newwin w4 -t "After restart" -w 300 -h 200 -c 6633aa -s 200 -p 400,300 -C appy,Persist
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "the choice survives a tiewm restart (read from the file)" $?
stop_clients
sed -i '/^\[windows\]/a Persist2 = no_titlebar' "$TMP/c7.conf"
kill -HUP "$WMPID"; sec 0.8
newwin w5 -t "After HUP" -w 300 -h 200 -c 33aa66 -s 200 -p 400,300 -C appz,Persist2
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "SIGHUP picks up a rule added by hand" $?
stop_wm; stop_clients
printf 'theme = Daloa\n' >"$TMP/c8.conf"
export TIEWM_CONFIG="$TMP/c8.conf"; start_wm
newwin w6 -t "No windows section" -w 300 -h 200 -c 3366aa -s 200 -p 400,300 -C appx,Fancy
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.9
printf 'theme = Daloa\n\n[windows]\nFancy = no_titlebar\n' >"$TMP/c8.expected"
cmp -s "$TMP/c8.expected" "$TMP/c8.conf"; check "a config without [windows] gets the section appended after a blank line" $?
stop_wm; stop_clients
rm -rf "$TMP/newdir"; export TIEWM_CONFIG="$TMP/newdir/sub/tiewm.conf"; start_wm
newwin w7 -t "No config file" -w 300 -h 200 -c 3366aa -s 200 -p 400,300 -C appx,Fancy
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.9
grep -q '^\[windows\]$' "$TMP/newdir/sub/tiewm.conf" && grep -q '^Fancy = no_titlebar$' "$TMP/newdir/sub/tiewm.conf"; check "with no config file at all, the file and its folders are created" $?
stop_wm; stop_clients
printf '[windows]\n' >"$TMP/c10.conf"; export TIEWM_CONFIG="$TMP/c10.conf"; start_wm
newwin w8 -t "Hint equals choice" -w 300 -h 200 -c aa33aa -s 200 -p 400,300 -D none -C hintapp,Hinty
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.9
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M" && grep -q '^Hinty = titlebar$' "$TMP/c10.conf"; check "an app that asks for no titlebar: choosing one is saved as 'titlebar'" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.9
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0" && ! grep -q 'Hinty' "$TMP/c10.conf"; check "choosing what the app asks for again removes the rule" $?
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm

echo "== 29. undecorated_border: an optional thin resize border for windows without a titlebar"
stop_wm; stop_clients
printf 'undecorated_border = 4\n' >"$TMP/c11.conf"; printf 'undecorated_border = 99\n' >"$TMP/c12.conf"
"$WM" --check-config "$TMP/c11.conf" | grep -q 'undecorated_border = 4'; check "--check-config shows undecorated_border" $?
OUT=$("$WM" --check-config "$TMP/c12.conf" 2>&1); RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -q 'line 1: undecorated_border must be 0..16'; check "a value out of range is only a warning" $?
export TIEWM_CONFIG="$TMP/c11.conf"; start_wm
newwin ub -t "Border" -w 300 -h 200 -c cc9900 -s 300 -p 400,300 -D none; UB=$LAST_ID
xprop -id "$UB" _NET_FRAME_EXTENTS | grep -q "= 4, 4, 4, 4"; check "an undecorated window gets 4 px extents" $?
G=$(absgeom "$UB"); [ "$(field "$G" x)" -eq 400 ] && [ "$(field "$G" y)" -eq 300 ] && [ "$(frameh "$UB")" = "208" ]; RC=$?; check "the client stays where the app put it; the frame is 4 px bigger on every side ($G, frame h $(frameh "$UB"))" $RC
import -window root "$TMP/ub1.png" 2>/dev/null
[ "$(magick "$TMP/ub1.png" -format '%[hex:p{398,350}]' info:)" = "15539E" ] && [ "$(magick "$TMP/ub1.png" -format '%[hex:p{410,350}]' info:)" = "CC9900" ]; check "the border is drawn in the active colour, the client inside it" $?
newwin ub2 -t "Normal neighbour" -w 300 -h 200 -c 0099cc -s 300 -p 800,300; UB2=$LAST_ID
sleep 0.3; import -window root "$TMP/ub2.png" 2>/dev/null
[ "$(magick "$TMP/ub2.png" -format '%[hex:p{398,350}]' info:)" = "323232" ]; check "it turns grey when another window has the focus" $?
xprop -id "$UB2" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M"; check "decorated windows are not affected" $?
"$XDO" move 450 400 click 1; sec 0.5
[ "$(hexnorm "$(active)")" = "$(hexnorm "$UB")" ]; check "clicking inside focuses it again" $?
G0=$(absgeom "$UB"); X0=$(field "$G0" x); Y0=$(field "$G0" y); W0=$(field "$G0" w); H0=$(field "$G0" h)
"$XDO" drag $((X0+W0+2)) $((Y0+100)) $((X0+W0+62)) $((Y0+100)); sec 0.7
G=$(absgeom "$UB"); [ "$(field "$G" w)" -eq $((W0+60)) ] && [ "$(field "$G" x)" -eq "$X0" ]; check "dragging the right border resizes it (+60 wide: $G)" $?
"$XDO" drag $((X0+100)) $((Y0+H0+2)) $((X0+100)) $((Y0+H0+42)); sec 0.7
G=$(absgeom "$UB"); [ "$(field "$G" h)" -eq $((H0+40)) ]; check "the bottom border resizes it (+40 high: $G)" $?
G0=$(absgeom "$UB"); X0=$(field "$G0" x); Y0=$(field "$G0" y); W0=$(field "$G0" w); H0=$(field "$G0" h)
"$XDO" drag $((X0-2)) $((Y0-2)) $((X0-32)) $((Y0-22)); sec 0.7
G=$(absgeom "$UB"); [ "$(field "$G" x)" -eq $((X0-30)) ] && [ "$(field "$G" y)" -eq $((Y0-20)) ] && [ "$(field "$G" w)" -eq $((W0+30)) ] && [ "$(field "$G" h)" -eq $((H0+20)) ]; check "the top-left corner resizes from that corner ($G)" $?
G0=$(absgeom "$UB")
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.8
G=$(absgeom "$UB")
[ "$(field "$G" x)" -eq 0 ] && [ "$(field "$G" w)" -eq 1280 ] && [ "$(field "$G" h)" -eq 800 ] && xprop -id "$UB" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "maximized: no border, fills the work area ($G)" $?
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.8
G=$(absgeom "$UB"); [ "$G" = "$G0" ] && xprop -id "$UB" _NET_FRAME_EXTENTS | grep -q "= 4, 4, 4, 4"; check "restored: the border and the exact old geometry are back ($G)" $?
wmctrl -i -r "$UB" -b add,fullscreen; sec 0.7
G=$(absgeom "$UB"); [ "$(field "$G" w)" -eq 1280 ] && xprop -id "$UB" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "fullscreen: no border ($G)" $?
wmctrl -i -r "$UB" -b remove,fullscreen; sec 0.7
G=$(absgeom "$UB"); [ "$G" = "$G0" ] && xprop -id "$UB" _NET_FRAME_EXTENTS | grep -q "= 4, 4, 4, 4"; check "and it returns with the border ($G)" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.9
G=$(absgeom "$UB")
xprop -id "$UB" _NET_FRAME_EXTENTS | grep -q "= $M, $M, $T, $M" && [ "$G" = "$G0" ]; check "menu: No titlebar off gives it the real titlebar, client in place ($G)" $?
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.9
G=$(absgeom "$UB")
xprop -id "$UB" _NET_FRAME_EXTENTS | grep -q "= 4, 4, 4, 4" && [ "$G" = "$G0" ]; check "menu: and on again goes back to the thin border ($G)" $?
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin ub0 -t "Default: no border" -w 300 -h 200 -c cc9900 -s 300 -p 400,300 -D none
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS | grep -q "= 0, 0, 0, 0"; check "with the default (undecorated_border = 0) nothing changes: no border at all" $?
stop_clients

echo "== 30. titlebar buttons: hover (prelight) and pressed images"
stop_clients
newwin hv -t "Hover me" -w 300 -h 200 -c 7a5599 -s 300 -p 400,300; HV=$LAST_ID
G=$(absgeom "$HV"); RX=$(field "$G" x); RY=$(field "$G" y); RW=$(field "$G" w)
CX=$((RX+RW-25)); SX=$((RX+RW-94)); BY=$((RY-19))      # left edge of the close and shade buttons, top of the titlebar
crop() { magick "$1" -crop 24x19+"$2"+"$BY" +repage "$3"; }
ae() { compare -metric AE "$1" "$2" null: 2>&1 | awk '{printf "%d", $1}'; }
"$XDO" move 900 700; sec 0.5
import -window root "$TMP/hv-base.png" 2>/dev/null
crop "$TMP/hv-base.png" "$CX" "$TMP/hv-base-close.png"; crop "$TMP/hv-base.png" "$SX" "$TMP/hv-base-shade.png"
"$XDO" move $((CX+12)) $((BY+9)); sec 0.5
import -window root "$TMP/hv-hover.png" 2>/dev/null
crop "$TMP/hv-hover.png" "$CX" "$TMP/hv-hover-close.png"
[ "$(ae "$TMP/hv-base-close.png" "$TMP/hv-hover-close.png")" -gt 20 ]; RC=$?; check "the close button looks different under the pointer ($(ae "$TMP/hv-base-close.png" "$TMP/hv-hover-close.png") pixels changed)" $RC
crop "$TMP/hv-hover.png" "$SX" "$TMP/hv-hover-shade.png"
[ "$(ae "$TMP/hv-base-shade.png" "$TMP/hv-hover-shade.png")" = "0" ]; check "the neighbouring shade button is unchanged" $?
"$XDO" move $((RX+60)) $((BY+9)); sec 0.5
import -window root "$TMP/hv-off.png" 2>/dev/null
crop "$TMP/hv-off.png" "$CX" "$TMP/hv-off-close.png"
[ "$(ae "$TMP/hv-base-close.png" "$TMP/hv-off-close.png")" = "0" ]; check "moving onto the title text puts the button back to normal" $?
"$XDO" move $((SX+12)) $((BY+9)); sec 0.4
import -window root "$TMP/hv-hover2.png" 2>/dev/null; crop "$TMP/hv-hover2.png" "$SX" "$TMP/hv-hover2-shade.png"
"$XDO" down 1; sec 0.5
import -window root "$TMP/hv-press.png" 2>/dev/null; crop "$TMP/hv-press.png" "$SX" "$TMP/hv-press-shade.png"
[ "$(ae "$TMP/hv-hover2-shade.png" "$TMP/hv-press-shade.png")" -gt 5 ] && [ "$(ae "$TMP/hv-base-shade.png" "$TMP/hv-press-shade.png")" -gt 20 ]; RC=$?; check "a held button shows its own pressed image ($(ae "$TMP/hv-hover2-shade.png" "$TMP/hv-press-shade.png") px vs hover)" $RC
"$XDO" move 900 700; sec 0.5
import -window root "$TMP/hv-away.png" 2>/dev/null; crop "$TMP/hv-away.png" "$SX" "$TMP/hv-away-shade.png"
[ "$(ae "$TMP/hv-base-shade.png" "$TMP/hv-away-shade.png")" = "0" ]; check "dragging off the button while held: it goes back to normal" $?
"$XDO" up 1; sec 0.6
[ "$(frameh "$HV")" = "$((200+T+M))" ]; check "and releasing outside does not trigger the button (window not shaded)" $?
"$XDO" move $((SX+12)) $((BY+9)) click 1; sec 0.8
[ "$(frameh "$HV")" = "$T" ]; check "a normal click on the same button still works (shades)" $?
stop_clients

echo "== 31. app icon on the menu button (_NET_WM_ICON, theme show_app_icon, config override)"
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
iconpx() {   # centre of the menu button of the (focused) window whose client is at $1,$2
  import -window root "$TMP/icon.png" 2>/dev/null
  magick "$TMP/icon.png" -format '%[hex:p{'$(( $1 + 13 ))','$(( $2 - 10 ))'}]' info:
}
newwin i1 -t "Icon 16" -w 300 -h 200 -c 444444 -s 60 -p 400,300 -I ff00ff:16
[ "$(iconpx 400 300)" = "FF00FF" ]; check "a 16x16 icon is drawn in the middle of the menu button" $?
stop_clients
newwin i2 -t "Two sizes" -w 300 -h 200 -c 444444 -s 60 -p 400,300 -I ff0000:48,0000ff:16
[ "$(iconpx 400 300)" = "0000FF" ]; check "with several sizes the one that fits (16) is used, not the big one" $?
stop_clients
newwin i3 -t "Only big" -w 300 -h 200 -c 444444 -s 60 -p 400,300 -I ff0000:48
[ "$(iconpx 400 300)" = "FF0000" ]; check "a big icon is scaled down to fit" $?
stop_clients
newwin i4 -t "Only small" -w 300 -h 200 -c 444444 -s 60 -p 400,300 -I 00ff00:8
[ "$(iconpx 400 300)" = "00FF00" ]; check "a small icon is scaled up to fit" $?
stop_clients
newwin i5 -t "No icon" -w 300 -h 200 -c 444444 -s 60 -p 400,300
[ "$(iconpx 400 300)" = "E9ECEF" ]; check "an app without an icon gets the generic window glyph" $?
stop_clients
newwin i6 -t "Icon changes" -w 300 -h 200 -c 444444 -s 60 -p 400,300 -I ff00ff:16 -J 00ffff,2
[ "$(iconpx 400 300)" = "FF00FF" ]; check "icon before the change" $?
sleep 2.6
[ "$(iconpx 400 300)" = "00FFFF" ]; check "a changed _NET_WM_ICON is picked up and repainted" $?
stop_wm; stop_clients
printf 'show_app_icon = false\n' >"$TMP/c13.conf"; export TIEWM_CONFIG="$TMP/c13.conf"; start_wm
newwin i7 -t "Icons off" -w 300 -h 200 -c 444444 -s 60 -p 400,300 -I ff00ff:16
[ "$(iconpx 400 300)" != "FF00FF" ] && [ "$(iconpx 400 300)" != "E9ECEF" ]; check "show_app_icon = false: no icon at all" $?
stop_wm; stop_clients
printf 'show_app_icon = true\ntheme = Moheli\n' >"$TMP/c14.conf"; export TIEWM_CONFIG="$TMP/c14.conf"; start_wm
newwin i8 -t "Forced on" -w 300 -h 200 -c 444444 -s 60 -p 400,300 -I ff00ff:16
xprop -id "$LAST_ID" _NET_FRAME_EXTENTS >/dev/null; import -window root "$TMP/icon8.png" 2>/dev/null
magick "$TMP/icon8.png" -crop 120x40+395+270 +repage txt:- | grep -qi 'FF00FF'; check "show_app_icon = true shows it even where the theme does not ask for one (Moheli)" $?
stop_wm; stop_clients
printf 'show_app_icon = maybe\n' >"$TMP/c15.conf"
"$WM" --check-config "$TMP/c15.conf" 2>&1 | grep -q 'line 1: show_app_icon must be'; check "a bad show_app_icon value is only a warning" $?
export TIEWM_CONFIG="$TMP/none.conf"; start_wm

echo "== 32. modal dialogs, and the window states an app sets itself are kept"
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin mp -t "Main window" -w 500 -h 400 -c 335577 -s 300 -p 100,100; MP=$LAST_ID
newwin md -t "Modal dialog" -w 200 -h 120 -c cc8833 -s 300 -p 800,150 -P "$MP" -S modal; MD=$LAST_ID
xprop -id "$MD" _NET_WM_STATE | grep -q MODAL; check "the app's _NET_WM_STATE_MODAL survives (it is not overwritten)" $?
[ "$(hexnorm "$(active)")" = "$(hexnorm "$MD")" ]; check "the dialog has the focus" $?
"$XDO" move 300 300 click 1; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$MD")" ]; check "clicking the blocked main window keeps/gives the focus to the dialog" $?
! grep -q ButtonPress "$TMP/mp.log"; check "and the click never reaches the main window's app" $?
G=$(absgeom "$MP"); PX=$(field "$G" x); PY=$(field "$G" y)
"$XDO" move $((PX+60)) $((PY-T+8)) click 1; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$MD")" ]; check "clicking the main window's titlebar also focuses the dialog" $?
[ "$(stackpos "$MD")" -gt "$(stackpos "$MP")" ]; RC=$?; check "the dialog stays above its parent (md=$(stackpos "$MD") mp=$(stackpos "$MP"))" $RC
wmctrl -i -a "$MP"; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$MD")" ]; check "activating the main window from a taskbar goes to the dialog instead" $?
"$XDO" keydown Alt_L key Tab keyup Alt_L; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$MD")" ]; check "Alt+Tab to the main window lands on the dialog" $?
"$XDO" keydown Alt_L key F4 keyup Alt_L; sec 0.8
grep -q WM_DELETE_WINDOW "$TMP/md.log"; check "Alt+F4 closes the dialog" $?
[ "$(hexnorm "$(active)")" = "$(hexnorm "$MP")" ]; check "focus returns to the main window" $?
"$XDO" move 300 300 click 1; sec 0.6
grep -q ButtonPress "$TMP/mp.log"; check "with the dialog gone, clicks reach the main window again" $?
stop_clients
newwin np -t "Main 2" -w 500 -h 400 -c 335577 -s 300 -p 100,100; NP=$LAST_ID
newwin nd -t "Not modal" -w 200 -h 120 -c cc8833 -s 300 -p 800,150 -P "$NP"; ND=$LAST_ID
"$XDO" move 300 300 click 1; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$NP")" ] && grep -q ButtonPress "$TMP/np.log"; check "a transient that is NOT modal does not block its parent" $?
wmctrl -i -r "$ND" -b add,modal; sec 0.6
"$XDO" move 300 300 click 1; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$ND")" ]; check "wmctrl -b add,modal (client message) makes it block from then on" $?
wmctrl -i -r "$ND" -b remove,modal; sec 0.6
"$XDO" move 300 300 click 1; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$NP")" ]; check "and removing modal unblocks it" $?
stop_clients
newwin cp -t "Chain base" -w 500 -h 400 -c 335577 -s 300 -p 100,100; CP=$LAST_ID
newwin ca -t "Chain A" -w 250 -h 150 -c aa8833 -s 300 -p 700,100 -P "$CP" -S modal; CA=$LAST_ID
newwin cb -t "Chain B" -w 200 -h 120 -c 33aa88 -s 300 -p 700,400 -P "$CA" -S modal; CB=$LAST_ID
"$XDO" move 300 300 click 1; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$CB")" ]; check "dialog over dialog: clicking the main window focuses the topmost dialog" $?
"$XDO" move 800 150 click 1; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$CB")" ]; check "the middle dialog is blocked by the top one" $?
stop_clients
newwin s1 -t "Skip taskbar" -w 300 -h 200 -c 888888 -s 60 -p 400,300 -S skip_taskbar,skip_pager; S1=$LAST_ID
xprop -id "$S1" _NET_WM_STATE | grep -q SKIP_TASKBAR && xprop -id "$S1" _NET_WM_STATE | grep -q SKIP_PAGER; check "skip_taskbar and skip_pager set by the app are kept (the panel needs them)" $?
wmctrl -i -r "$S1" -b add,demands_attention 2>/dev/null; wmctrl -i -r "$S1" -b remove,skip_pager; sec 0.5
xprop -id "$S1" _NET_WM_STATE | grep -q SKIP_TASKBAR && ! xprop -id "$S1" _NET_WM_STATE | grep -q SKIP_PAGER; check "client messages add and remove such states" $?
stop_clients
newwin s2 -t "Starts above and sticky" -w 300 -h 200 -c 888888 -s 60 -p 400,300 -S above,sticky; S2=$LAST_ID
xprop -id "$S2" _NET_WM_STATE | grep -q ABOVE && [ "$(deskof "$S2")" = "4294967295" ]; check "an app that starts above and on all desktops is honoured" $?
stop_clients

echo "== 33. minimized windows: apps that start minimized, and windows a previous WM left minimized"
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin sm -t "Starts minimized" -w 300 -h 200 -c 7755aa -s 300 -p 400,300 -W iconic; SM=$LAST_ID
sec 0.5
[ "$(viewable "$SM")" = "0" ] && [ "$(wmstate "$SM")" = "Iconic" ]; check "WM_HINTS initial_state = iconic: the window starts hidden with WM_STATE Iconic" $?
xprop -id "$SM" _NET_WM_STATE | grep -q HIDDEN; check "and _NET_WM_STATE_HIDDEN is set" $?
wmctrl -l | grep -q "Starts minimized"; check "it is still in the client list (a taskbar can restore it)" $?
[ "$(hexnorm "$(active)" 2>/dev/null)" != "$(hexnorm "$SM")" ]; check "it did not steal the focus" $?
wmctrl -i -a "$SM"; sec 0.8
[ "$(viewable "$SM")" = "1" ] && [ "$(wmstate "$SM")" = "Normal" ] && [ "$(hexnorm "$(active)")" = "$(hexnorm "$SM")" ]; check "restoring it through _NET_ACTIVE_WINDOW shows and focuses it" $?
G=$(absgeom "$SM"); [ "$(field "$G" x)" -eq 400 ] && [ "$(field "$G" y)" -eq 300 ]; check "at the position it asked for ($G)" $?
stop_clients
newwin nm -t "Normal start" -w 300 -h 200 -c 5577aa -s 300 -p 400,300
[ "$(viewable "$LAST_ID")" = "1" ]; check "a normal window is unaffected" $?
stop_wm; stop_clients
newwin pi -t "Left minimized" -w 300 -h 200 -c aa7755 -s 300 -p 300,200 -U iconic; PI=$LAST_ID
newwin pw -t "Left withdrawn" -w 300 -h 200 -c 55aa77 -s 300 -p 600,200 -U withdrawn; PW=$LAST_ID
newwin pn -t "Left mapped" -w 300 -h 200 -c 77aa55 -s 300 -p 300,500; PN=$LAST_ID
start_wm; sec 0.6
wmctrl -l | grep -q "Left minimized"; check "a window a previous WM had minimized (unmapped, WM_STATE Iconic) is adopted at startup" $?
[ "$(viewable "$PI")" = "0" ] && [ "$(wmstate "$PI")" = "Iconic" ]; check "and stays minimized" $?
! wmctrl -l | grep -q "Left withdrawn"; check "an unmapped window that is merely withdrawn is not adopted" $?
wmctrl -l | grep -q "Left mapped" && [ "$(viewable "$PN")" = "1" ]; check "mapped windows are adopted as before" $?
wmctrl -i -a "$PI"; sec 0.8
[ "$(viewable "$PI")" = "1" ] && [ "$(wmstate "$PI")" = "Normal" ]; check "the adopted minimized window can be restored" $?
G=$(absgeom "$PI"); [ "$(field "$G" x)" -eq 300 ] && [ "$(field "$G" y)" -eq 200 ]; check "where it was ($G)" $?
grep -q '(minimized)' "$TMP/tiewm.log"; check "the log notes minimized windows" $?
stop_clients

echo "== 34. _NET_WM_MOVERESIZE: apps asking the WM to start a move or resize"
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin mr -t "App-driven move" -w 300 -h 200 -c 5588aa -s 300 -p 400,300 -R 8; MR=$LAST_ID
G0=$(absgeom "$MR"); X0=$(field "$G0" x); Y0=$(field "$G0" y); W0=$(field "$G0" w); H0=$(field "$G0" h)
CX=$((X0+W0/2)); CY=$((Y0+H0/2))
"$XDO" move $CX $CY down 1 sleep 400 move $((CX+80)) $((CY+40)) sleep 300 up 1; sec 0.6
grep -q 'sent _NET_WM_MOVERESIZE 8' "$TMP/mr.log"; check "the app sent the request on a button press" $?
G=$(absgeom "$MR"); [ "$(field "$G" x)" -eq $((X0+80)) ] && [ "$(field "$G" y)" -eq $((Y0+40)) ]; check "direction MOVE: dragging the pointer moves the window by +80,+40 ($G)" $?
"$XDO" move $((CX+80)) $((CY+40)) sleep 300 move $((CX+200)) $((CY+100)) sleep 300
G2=$(absgeom "$MR"); [ "$(field "$G2" x)" -eq "$(field "$G" x)" ]; check "after the button is released the drag is over (window stays put)" $?
stop_clients
newwin mr2 -t "App-driven resize SE" -w 300 -h 200 -c 5588aa -s 300 -p 400,300 -R 4; MR=$LAST_ID
G0=$(absgeom "$MR"); X0=$(field "$G0" x); Y0=$(field "$G0" y); W0=$(field "$G0" w); H0=$(field "$G0" h)
CX=$((X0+W0/2)); CY=$((Y0+H0/2))
"$XDO" move $CX $CY down 1 sleep 400 move $((CX+50)) $((CY+30)) sleep 300 up 1; sec 0.6
G=$(absgeom "$MR"); [ "$(field "$G" w)" -eq $((W0+50)) ] && [ "$(field "$G" h)" -eq $((H0+30)) ] && [ "$(field "$G" x)" -eq "$X0" ]; check "direction BOTTOMRIGHT: grows by +50,+30 with the top-left fixed ($G)" $?
stop_clients
newwin mr3 -t "App-driven resize NW" -w 300 -h 200 -c 5588aa -s 300 -p 400,300 -R 0; MR=$LAST_ID
G0=$(absgeom "$MR"); X0=$(field "$G0" x); Y0=$(field "$G0" y); W0=$(field "$G0" w); H0=$(field "$G0" h)
CX=$((X0+W0/2)); CY=$((Y0+H0/2))
"$XDO" move $CX $CY down 1 sleep 400 move $((CX-40)) $((CY-20)) sleep 300 up 1; sec 0.6
G=$(absgeom "$MR"); [ "$(field "$G" w)" -eq $((W0+40)) ] && [ "$(field "$G" h)" -eq $((H0+20)) ] && [ "$(field "$G" x)" -eq $((X0-40)) ] && [ "$(field "$G" y)" -eq $((Y0-20)) ]; check "direction TOPLEFT: grows by +40,+20, bottom-right corner fixed ($G)" $?
stop_clients
newwin mr4 -t "App-driven keyboard move" -w 300 -h 200 -c 5588aa -s 300 -p 400,300 -R 10; MR=$LAST_ID
G0=$(absgeom "$MR"); X0=$(field "$G0" x); Y0=$(field "$G0" y); W0=$(field "$G0" w); H0=$(field "$G0" h)
"$XDO" move $((X0+W0/2)) $((Y0+H0/2)) click 1; sec 0.6
"$XDO" key Right key Right key Down key Return; sec 0.6
G=$(absgeom "$MR"); [ "$(field "$G" x)" -eq $((X0+20)) ] && [ "$(field "$G" y)" -eq $((Y0+10)) ]; check "direction MOVE_KEYBOARD starts the Alt+F7 mode: arrows then Return move it +20,+10 ($G)" $?
stop_clients
xprop -root _NET_SUPPORTED | grep -q _NET_WM_MOVERESIZE; check "_NET_WM_MOVERESIZE is listed in _NET_SUPPORTED" $?
xprop -root _NET_SUPPORTED | grep -q _NET_WM_STATE_BELOW; check "_NET_WM_STATE_BELOW is listed too" $?
stop_clients

echo "== 35. window gravity (ICCCM) and _NET_MOVERESIZE_WINDOW"
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin g0 -t "Gravity default" -w 300 -h 200 -c 8855aa -s 300 -p 400,300 -G 0; GA=$LAST_ID
G=$(absgeom "$GA"); [ "$(field "$G" x)" -eq $((400+M)) ] && [ "$(field "$G" y)" -eq $((300+T)) ]; check "no gravity set (NorthWest): the FRAME's corner is at the requested 400,300 ($G)" $?
stop_clients
newwin g1 -t "Gravity static" -w 300 -h 200 -c 8855aa -s 300 -p 400,300 -G 10; GA=$LAST_ID
G=$(absgeom "$GA"); [ "$(field "$G" x)" -eq 400 ] && [ "$(field "$G" y)" -eq 300 ]; check "Static: the CLIENT is at 400,300 ($G)" $?
stop_clients
newwin g2 -t "Gravity SE" -w 300 -h 200 -c 8855aa -s 300 -p 400,300 -G 9; GA=$LAST_ID
G=$(absgeom "$GA"); [ "$(field "$G" x)" -eq $((400-M)) ] && [ "$(field "$G" y)" -eq $((300-M)) ]; check "SouthEast: the frame's bottom-right corner follows the client's ($G)" $?
stop_clients
newwin g3 -t "Gravity center" -w 300 -h 200 -c 8855aa -s 300 -p 400,300 -G 5; GA=$LAST_ID
G=$(absgeom "$GA"); [ "$(field "$G" x)" -eq 400 ] && [ "$(field "$G" y)" -eq $((300-(T+M)/2+T)) ]; check "Center: centred on the requested point ($G)" $?
stop_clients
newwin g4 -t "Move request" -w 300 -h 200 -c 8855aa -s 300 -p 400,300 -G 10; GA=$LAST_ID
wmctrl -i -r "$GA" -e 10,200,150,-1,-1; sec 0.6
G=$(absgeom "$GA"); [ "$(field "$G" x)" -eq 200 ] && [ "$(field "$G" y)" -eq 150 ] && [ "$(field "$G" w)" -eq 300 ]; check "wmctrl -e with Static gravity places the client at 200,150, size kept ($G)" $?
wmctrl -i -r "$GA" -e 1,200,150,400,250; sec 0.6
G=$(absgeom "$GA"); [ "$(field "$G" x)" -eq $((200+M)) ] && [ "$(field "$G" y)" -eq $((150+T)) ] && [ "$(field "$G" w)" -eq 400 ] && [ "$(field "$G" h)" -eq 250 ]; check "wmctrl -e with NorthWest gravity puts the frame at 200,150 and resizes to 400x250 ($G)" $?
xprop -root _NET_SUPPORTED | grep -q _NET_MOVERESIZE_WINDOW; check "_NET_MOVERESIZE_WINDOW is listed in _NET_SUPPORTED" $?
stop_clients

echo "== 36. stick button (T)"
stop_wm; stop_clients
printf '[general]\nbutton_layout = O|TSHMC\n' > "$TMP/c36.conf"
export TIEWM_CONFIG="$TMP/c36.conf"; start_wm
newwin tb -t "Stick me" -w 300 -h 200 -c 996633 -s 300 -p 500,300 -G 10; TB=$LAST_ID
G=$(absgeom "$TB"); RX=$(field "$G" x); RY=$(field "$G" y); RW=$(field "$G" w)
[ "$(deskof "$TB")" = "0" ]; check "starts on desktop 0" $?
"$XDO" move $((RX+RW-104)) $((RY-T+8)) click 1; sec 0.7
[ "$(deskof "$TB")" = "4294967295" ]; check "T button puts the window on all workspaces" $?
xprop -id "$TB" _NET_WM_STATE | grep -q STICKY; check "_NET_WM_STATE has STICKY" $?
"$XDO" move $((RX+RW-104)) $((RY-T+8)) click 1; sec 0.7
[ "$(deskof "$TB")" = "0" ]; check "T button again returns it to the current desktop" $?
"$XDO" move $((RX+RW-82)) $((RY-T+8)) click 1; sec 0.7
[ "$(frameh "$TB")" = "$T" ]; check "the S button next to it still shades" $?
stop_clients
export TIEWM_CONFIG="$TMP/none.conf"

echo "== 37. _NET_WM_ALLOWED_ACTIONS, _NET_REQUEST_FRAME_EXTENTS, splash windows"
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin aa -t "Actions" -w 300 -h 200 -c 7799aa -s 300 -p 400,300; AA=$LAST_ID
A=$(xprop -id "$AA" _NET_WM_ALLOWED_ACTIONS)
echo "$A" | grep -q _NET_WM_ACTION_CLOSE && echo "$A" | grep -q _NET_WM_ACTION_MAXIMIZE_HORZ && echo "$A" | grep -q _NET_WM_ACTION_SHADE && echo "$A" | grep -q _NET_WM_ACTION_MINIMIZE; check "a normal window lists close/maximize/shade/minimize as allowed" $?
xprop -root _NET_SUPPORTED | grep -q _NET_WM_ALLOWED_ACTIONS && xprop -root _NET_SUPPORTED | grep -q _NET_REQUEST_FRAME_EXTENTS; check "both properties are listed in _NET_SUPPORTED" $?
stop_clients
newwin ad -t "Undecorated" -w 300 -h 200 -c 7799aa -s 300 -p 400,300 -D none; AD=$LAST_ID
! xprop -id "$AD" _NET_WM_ALLOWED_ACTIONS | grep -q _NET_WM_ACTION_SHADE; check "a window without a titlebar cannot be shaded" $?
stop_clients
newwin rf -t "Asks extents" -w 300 -h 200 -c 7799aa -s 300 -p 400,300 -X; sec 0.3
grep -q "requested extents=$M,$M,$T,$M" "$TMP/rf.log"; RC=$?; check "_NET_REQUEST_FRAME_EXTENTS before mapping is answered ($(grep -a 'requested extents' "$TMP/rf.log"))" $RC
stop_clients
newwin rn -t "Asks extents, no frame" -w 300 -h 200 -c 7799aa -s 300 -p 400,300 -X -D none; sec 0.3
grep -q "requested extents=0,0,0,0" "$TMP/rn.log"; RC=$?; check "and answers 0,0,0,0 for a window that wants no decorations ($(grep -a 'requested extents' "$TMP/rn.log"))" $RC
stop_clients
newwin sp -t "Splash" -w 300 -h 200 -c 7799aa -s 300 -p 400,300 -y splash; SP=$LAST_ID
[ "$(xprop -id "$SP" _NET_FRAME_EXTENTS | sed 's/.*= //')" = "0, 0, 0, 0" ]; RC=$?; check "a splash window gets no frame: $(xprop -id "$SP" _NET_FRAME_EXTENTS)" $RC
stop_clients

echo "== 38. _NET_WM_PING: closing a hung app twice kills it"
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin pg -t "Answers pings" -w 300 -h 200 -c 99aa77 -s 60 -p 400,300; PG=$LAST_ID
wmctrl -i -c "$PG"; sec 1
grep -q '^ping' "$TMP/pg.log" && grep -q WM_DELETE_WINDOW "$TMP/pg.log"; check "closing sends WM_DELETE_WINDOW and a _NET_WM_PING" $?
! kill -0 "$PID_pg" 2>/dev/null; check "a responsive app closes normally" $?
stop_clients
newwin hg -t "Hung" -w 300 -h 200 -c aa7799 -s 60 -p 400,300 -H; HG=$LAST_ID
G=$(absgeom "$HG"); RX=$(field "$G" x); RY=$(field "$G" y); RW=$(field "$G" w)
"$XDO" move $((RX+RW-16)) $((RY-T+8)) click 1; sec 1
kill -0 "$PID_hg" 2>/dev/null; check "first click on Close: a hung app is asked politely and stays" $?
"$XDO" move $((RX+RW-16)) $((RY-T+8)) click 1; sec 0.8
kill -0 "$PID_hg" 2>/dev/null; check "a second click within 3 s does not kill it yet" $?
sleep 3
"$XDO" move $((RX+RW-16)) $((RY-T+8)) click 1; sec 1
! kill -0 "$PID_hg" 2>/dev/null; check "a click after 3 s without an answer kills it" $?
grep -q 'did not answer a ping' "$TMP/tiewm.log"; check "and the log says why" $?
stop_clients

echo "== 39. several monitors (RandR 1.5 virtual monitors in a 2560x800 Xvfb on :97)"
stop_wm; stop_clients
MON=$HERE/monset
Xvfb :97 -screen 0 2560x800x24 -nolisten tcp >/dev/null 2>&1 & XV97=$!
sleep 1
export DISPLAY=:97
"$MON" 600 left=0,0,1280,800 right=1280,0,1280,800 >/dev/null 2>&1 & MONPID=$!
sleep 0.7
export TIEWM_CONFIG="$TMP/none.conf"; rm -f "$TMP/tiewm.log"; start_wm
grep -q '2 monitor(s): 1280x800+0+0 1280x800+1280+0' "$TMP/tiewm.log"; RC=$?; check "the log lists both monitors ($(grep -a 'monitor(s)' "$TMP/tiewm.log" | tail -1))" $RC
"$XDO" move 1900 400; sec 0.2
newwin mr -t "Opens right" -w 400 -h 300 -c 5577cc -s 120; MR=$LAST_ID
G=$(absgeom "$MR"); [ "$(field "$G" x)" -eq $((1280+(1280-400-2*M)/2+M)) ] && [ "$(field "$G" x)" -gt 1280 ]; check "a new window opens centred on the monitor the pointer is on ($G)" $?
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.6
G=$(absgeom "$MR"); [ "$(field "$G" x)" -eq $((1280+M)) ] && [ "$(field "$G" w)" -eq $((1280-2*M)) ]; check "maximize fills the right monitor only ($G)" $?
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.5
"$XDO" keydown Alt_L key F11 keyup Alt_L; sec 0.6
G=$(absgeom "$MR"); [ "$(field "$G" x)" -eq 1280 ] && [ "$(field "$G" w)" -eq 1280 ] && [ "$(field "$G" h)" -eq 800 ]; check "fullscreen fills the right monitor only ($G)" $?
"$XDO" keydown Alt_L key F11 keyup Alt_L; sec 0.5
"$XDO" move 300 400; sec 0.2
newwin ml -t "Opens left" -w 400 -h 300 -c cc7755 -s 120; ML=$LAST_ID
G=$(absgeom "$ML"); [ "$(field "$G" x)" -lt 1280 ] && [ "$(field "$G" x)" -eq $(((1280-400-2*M)/2+M)) ]; check "with the pointer on the left monitor a new window opens there ($G)" $?
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.6
G=$(absgeom "$ML"); [ "$(field "$G" x)" -eq $M ] && [ "$(field "$G" w)" -eq $((1280-2*M)) ]; check "and maximizes to the left monitor ($G)" $?
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.5
# put the right-hand window back to maximized, then unplug the right monitor
"$XDO" move 1900 400 click 1; sec 0.3
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.5
newwin mf -t "Floating right" -w 300 -h 200 -c 77cc55 -s 120 -p 1800,300 -G 10; MF=$LAST_ID
"$MON" 0 del=right >/dev/null 2>&1      # the right monitor is unplugged
sleep 3.5      # the WM polls the monitor list every 2 s (servers send no event for client-defined monitors)
grep -q ' 1 monitor(s): 1280x800+0+0' "$TMP/tiewm.log"; RC=$?; check "unplugging the right monitor is noticed ($(grep -a 'monitor(s)' "$TMP/tiewm.log" | tail -1))" $RC
G=$(absgeom "$MR"); [ "$(field "$G" x)" -eq $M ] && [ "$(field "$G" w)" -eq $((1280-2*M)) ]; check "a maximized window refits to the monitor that is left ($G)" $?
G=$(absgeom "$MF"); [ "$(( $(field "$G" x) + $(field "$G" w) ))" -le 1280 ]; check "a window that was on the unplugged monitor is pulled back onto the remaining one ($G)" $?
stop_clients
stop_wm
kill "$MONPID" 2>/dev/null; wait "$MONPID" 2>/dev/null
kill "$XV97" 2>/dev/null; wait "$XV97" 2>/dev/null
export DISPLAY=:99

echo "== 40. urgency hint, aspect-ratio hints, Alt+F12"
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin ua -t "Urgent later" -w 300 -h 200 -c cc9955 -s 120 -p 100,100 -Q 3; UA=$LAST_ID
newwin ub -t "Has focus" -w 300 -h 200 -c 55cc99 -s 120 -p 600,100; UB=$LAST_ID
sleep 3.5
xprop -id "$UA" _NET_WM_STATE | grep -q DEMANDS_ATTENTION; check "the WM_HINTS urgency bit shows up as _NET_WM_STATE_DEMANDS_ATTENTION" $?
wmctrl -i -a "$UA"; sec 0.6
! xprop -id "$UA" _NET_WM_STATE | grep -q DEMANDS_ATTENTION; check "focusing the window clears it" $?
stop_clients
newwin as -t "Aspect max 2:1" -w 300 -h 200 -c 9955cc -s 120 -p 400,300 -a 1:3,2:1; AS=$LAST_ID
G=$(absgeom "$AS"); RX=$(field "$G" x); RY=$(field "$G" y); RW=$(field "$G" w); RH=$(field "$G" h)
"$XDO" move $((RX+RW+M-2)) $((RY+RH+M-2)) down 1 sleep 300 move $((RX+RW+M-2+300)) $((RY+RH+M-2)) sleep 300 up 1; sec 0.6
G=$(absgeom "$AS"); [ "$(field "$G" w)" -le $((2*$(field "$G" h))) ] && [ "$(field "$G" w)" -gt 300 ]; RC=$?; check "widening a window with max aspect 2:1 stops at twice its height ($G)" $RC
stop_clients
newwin af -t "Alt F12" -w 300 -h 200 -c 99cc55 -s 120 -p 400,300; AF=$LAST_ID
"$XDO" move 500 400 click 1; sec 0.4
"$XDO" keydown Alt_L key F12 keyup Alt_L; sec 0.5
xprop -id "$AF" _NET_WM_STATE | grep -q ABOVE; check "Alt+F12 puts the focused window always on top" $?
"$XDO" keydown Alt_L key F12 keyup Alt_L; sec 0.5
! xprop -id "$AF" _NET_WM_STATE | grep -q ABOVE; check "and again takes it off" $?
stop_clients

echo "== 41. Alt+Tab list popup"
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin l1 -t "First window" -w 300 -h 200 -c cc5555 -s 120 -p 100,100; L1=$LAST_ID
newwin l2 -t "Second window" -w 300 -h 200 -c 55cc55 -s 120 -p 500,100; L2=$LAST_ID
newwin l3 -t "Third window" -w 300 -h 200 -c 5555cc -s 120 -p 900,100; L3=$LAST_ID
ovr() { "$XG" | grep -a "override=1" | grep -a "viewable=1" | head -1; }
[ -z "$(ovr)" ]; check "no popup while not cycling" $?
"$XDO" keydown Alt_L key Tab; sec 0.6
O=$(ovr); [ -n "$O" ]; check "Alt+Tab shows a list window while Alt is held ($O)" $?
H=$(echo "$O" | sed -n 's/.* h=\([0-9]*\) .*/\1/p'); [ "${H:-0}" -gt 60 ]; check "tall enough for three rows (h=$H)" $?
import -window root "$TMP/altab.png" 2>/dev/null
"$XDO" key Tab; sec 0.4
[ -n "$(ovr)" ]; check "it stays while cycling on" $?
"$XDO" keyup Alt_L; sec 0.5
[ -z "$(ovr)" ]; check "releasing Alt closes it" $?
stop_clients

echo "== 42. move a window to the next / previous monitor (Super+Shift+Right / Left)"
stop_wm; stop_clients
MON=$HERE/monset
Xvfb :97 -screen 0 2560x800x24 -nolisten tcp >/dev/null 2>&1 & XV97=$!
sleep 1
export DISPLAY=:97
"$MON" 60 left=0,0,1280,800 right=1280,0,1280,800 >/dev/null 2>&1 & MONPID=$!
sleep 0.7
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin mv -t "Hop" -w 400 -h 300 -c 55aa55 -s 120 -p 100,150 -G 10; MV=$LAST_ID
"$XDO" move 300 300 click 1; sec 0.4
G0=$(absgeom "$MV"); X0=$(field "$G0" x); Y0=$(field "$G0" y)
"$XDO" keydown Super_L keydown Shift_L key Right keyup Shift_L keyup Super_L; sec 0.6
G=$(absgeom "$MV"); [ "$(field "$G" x)" -eq $((X0+1280)) ] && [ "$(field "$G" y)" -eq "$Y0" ]; RC=$?; check "Super+Shift+Right moves it to the right monitor at the same place ($G)" $RC
"$XDO" keydown Super_L keydown Shift_L key Right keyup Shift_L keyup Super_L; sec 0.6
G=$(absgeom "$MV"); [ "$(field "$G" x)" -eq $((X0+1280)) ]; RC=$?; check "Right again on the right-most monitor does nothing: no wrapping round ($G)" $RC
"$XDO" keydown Super_L keydown Shift_L key Left keyup Shift_L keyup Super_L; sec 0.6
G=$(absgeom "$MV"); [ "$(field "$G" x)" -eq "$X0" ]; RC=$?; check "Super+Shift+Left moves it back to the left monitor ($G)" $RC
"$XDO" keydown Super_L keydown Shift_L key Left keyup Shift_L keyup Super_L; sec 0.6
G=$(absgeom "$MV"); [ "$(field "$G" x)" -eq "$X0" ]; RC=$?; check "Left again on the left-most monitor does nothing ($G)" $RC
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.8
G=$(absgeom "$MV"); [ "$(field "$G" x)" -eq $((X0+1280)) ]; RC=$?; check "window menu: \"Move to Monitor 2\" (12th enabled item) moves it there ($G)" $RC
"$XDO" keydown Alt_L key space keyup Alt_L; sec 0.5; "$XDO" key Down key Down key Down key Down key Down key Down key Down key Down key Down key Down key Down key Down key Return; sec 0.8
G=$(absgeom "$MV"); [ "$(field "$G" x)" -eq "$X0" ]; RC=$?; check "window menu: \"Move to Monitor 1\" brings it back (its own monitor's entry is disabled, so it is the 12th enabled item again) ($G)" $RC
"$XDO" keydown Super_L keydown Shift_L key Right keyup Shift_L keyup Super_L; sec 0.6
"$XDO" keydown Super_L key Return keyup Super_L; sec 0.6
"$XDO" keydown Super_L keydown Shift_L key Left keyup Shift_L keyup Super_L; sec 0.6
G=$(absgeom "$MV"); [ "$(field "$G" x)" -eq $M ] && [ "$(field "$G" w)" -eq $((1280-2*M)) ]; RC=$?; check "a maximized window arrives maximized on the other monitor ($G)" $RC
stop_clients
stop_wm
kill "$MONPID" 2>/dev/null; wait "$MONPID" 2>/dev/null
kill "$XV97" 2>/dev/null; wait "$XV97" 2>/dev/null
export DISPLAY=:99

echo "== 43. focus follows the mouse (focus_mode = follow)"
stop_wm; stop_clients
printf '[general]\nfocus_mode = follow\nfocus_delay = 150\n' > "$TMP/c43.conf"
export TIEWM_CONFIG="$TMP/c43.conf"; start_wm
newwin fa -t "Follow A" -w 300 -h 200 -c cc7755 -s 120 -p 100,200 -G 10; FA=$LAST_ID
newwin fb -t "Follow B" -w 300 -h 200 -c 5577cc -s 120 -p 600,200 -G 10; FB=$LAST_ID
"$XDO" move 250 300; sec 0.7
[ "$(hexnorm "$(active)")" = "$(hexnorm "$FA")" ]; RC=$?; check "pointer over A for longer than the delay: A has the focus" $RC
"$XDO" move 750 300; sec 0.7
[ "$(hexnorm "$(active)")" = "$(hexnorm "$FB")" ]; RC=$?; check "pointer over B: B has the focus, without a click" $RC
"$XDO" move 250 300 sleep 40 move 750 300; sec 0.7
[ "$(hexnorm "$(active)")" = "$(hexnorm "$FB")" ]; RC=$?; check "passing over A faster than the delay does not focus it" $RC
"$XDO" move 1100 700; sec 0.5
[ "$(hexnorm "$(active)")" = "$(hexnorm "$FB")" ]; RC=$?; check "moving onto the bare desktop keeps the focus where it was" $RC
stop_clients
export TIEWM_CONFIG="$TMP/none.conf"
stop_wm

echo "== 44. group modality: a modal window with no parent blocks its WM_CLIENT_LEADER group"
stop_wm; stop_clients
export TIEWM_CONFIG="$TMP/none.conf"; start_wm
newwin gm -t "Group main" -w 500 -h 400 -c 335577 -s 120 -p 100,100 -L self; GM=$LAST_ID
newwin go -t "Unrelated" -w 300 -h 200 -c 557733 -s 120 -p 800,100; GO=$LAST_ID
newwin gd -t "Group dialog" -w 250 -h 150 -c aa8833 -s 120 -p 800,400 -L "$GM" -S modal; GD=$LAST_ID
"$XDO" move 300 300 click 1; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$GD")" ]; RC=$?; check "clicking the group's main window focuses its modal dialog instead" $RC
"$XDO" move 900 150 click 1; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$GO")" ]; RC=$?; check "a window outside the group is not blocked" $RC
wmctrl -i -r "$GD" -b remove,modal; sec 0.6
"$XDO" move 300 300 click 1; sec 0.6
[ "$(hexnorm "$(active)")" = "$(hexnorm "$GM")" ]; RC=$?; check "once the dialog is no longer modal the main window takes the focus again" $RC
stop_clients

stop_wm

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
