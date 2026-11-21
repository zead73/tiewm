#!/bin/bash
# Renders the same two windows under real xfwm4 and under tiewm for each xfwm4 theme and compares
# the frames pixel by pixel. Runs only on the scratch display :99. xfwm4 runs on a PRIVATE D-Bus
# session with a private config folder, so the real xfwm4/xfconf settings are never read or
# changed (the GTK theme setting is copied in so the palette matches).
#   tools/themecheck.sh [theme ...]      default: every installed theme that has an xfwm4 folder
set -u
export DISPLAY=:99
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
OUT="$ROOT/out/themes"; mkdir -p "$OUT"
PRIV="${THEMECHECK_TMP:-/tmp/tiewm-themecheck}"; rm -rf "$PRIV"; mkdir -p "$PRIV"
IMGDIFF_NOTE=1
TW="$HERE/testwin"; XG="$HERE/xgeom"; WM="$ROOT/tiewm"

themes=("$@")
if [ ${#themes[@]} -eq 0 ]; then
  for d in /usr/share/themes/*/xfwm4 "$HOME"/.themes/*/xfwm4; do
    [ -d "$d" ] && themes+=("$(basename "$(dirname "$d")")")
  done
fi

# stops the xfwm4 started above: matched by its own environment (our private config), never by name alone
stop_xfwm4() {
  for p in $(pgrep -x xfwm4); do
    if tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qx "XDG_CONFIG_HOME=$P"; then kill -TERM "$p" 2>/dev/null; fi
  done
}

pgrep -x Xvfb >/dev/null || { Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 & sleep 1; }

frame_of() {   # client id -> "x y w h" of its frame (top-level parent)
  "$XG" | awk -v id="$(printf '0x%X' "$(printf '%d' "$1")")" '/^win=/{top=$0} /^  win=/{ if ($1=="win="id) print top}' \
    | sed -n 's/.*x=\([-0-9]*\) y=\([-0-9]*\) w=\([0-9]*\) h=\([0-9]*\).*/\1 \2 \3 \4/p'
}
extents_of() { xprop -id "$1" _NET_FRAME_EXTENTS 2>/dev/null | sed 's/.*= //'; }

# starts the two test windows, waits, writes "<A id> <B id>" to $1
make_windows() {
  "$TW" -t "${THEMECHECK_TITLE:- }" -w 300 -h 200 -c 3a3a3a -s 60 -p 150,120 -I 00ff00:16 >"$PRIV/a.log" 2>&1 &
  sleep 1.2
  "$TW" -t "${THEMECHECK_TITLE:- }" -w 300 -h 200 -c 3a3a3a -s 60 -p 600,380 -I 00ff00:16 >"$PRIV/b.log" 2>&1 &
  sleep 1.5
  A=$(sed -n 's/^mapped id=\(0x[0-9a-fA-F]*\).*/\1/p' "$PRIV/a.log" | head -1)
  B=$(sed -n 's/^mapped id=\(0x[0-9a-fA-F]*\).*/\1/p' "$PRIV/b.log" | head -1)
}

capture() {   # tag
  local tag="$1"
  make_windows
  EXT_A=$(extents_of "$A"); EXT_B=$(extents_of "$B")
  FA=$(frame_of "$A"); FB=$(frame_of "$B")
  import -window root "$PRIV/$tag-full.png" 2>/dev/null
  echo "$EXT_A|$EXT_B|$FA|$FB" >"$PRIV/$tag.info"
  pkill -x testwin; sleep 0.4
}

printf '%-14s %-18s %-18s %-13s %-9s %s\n' THEME "xfwm4 extents" "tiewm extents" "act diff" "inact diff" notes
for T in "${themes[@]}"; do
  # --- real xfwm4, private session
  P="$PRIV/cfg-$T"; mkdir -p "$P/xfce4/xfconf/xfce-perchannel-xml" "$P/gtk-3.0"
  cp "$HOME/.config/gtk-3.0/settings.ini" "$P/gtk-3.0/" 2>/dev/null
  cat >"$P/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="$T"/>
    <property name="title_font" type="string" value="Sans Bold 11"/>
    <property name="use_compositing" type="bool" value="false"/>
    <property name="title_alignment" type="string" value="left"/>
  </property>
</channel>
XML
  ( unset WAYLAND_DISPLAY; export XDG_CONFIG_HOME="$P" XDG_CACHE_HOME="$P/cache"
    exec setsid dbus-run-session -- xfwm4 --compositor=off ) >"$PRIV/xfwm4-$T.log" 2>&1 &
  XP=$!
  sleep 2.5
  capture "x-$T"
  stop_xfwm4; sleep 1
  # --- tiewm
  TIEWM_CONFIG=/nonexistent TIEWM_LOG="$PRIV/tiewm-$T.log" TIEWM_THEME="$T" "$WM" 2>"$PRIV/tiewm-$T.err" &
  TP=$!; sleep 1
  capture "t-$T"
  kill -TERM "$TP" 2>/dev/null; wait "$TP" 2>/dev/null; sleep 0.5

  # --- compare each window's frame
  IFS='|' read -r XEA XEB XFA XFB <"$PRIV/x-$T.info"
  IFS='|' read -r TEA TEB TFA TFB <"$PRIV/t-$T.info"
  notes=""
  res=()
  for which in A B; do
    if [ $which = A ]; then XF="$XFA"; TF="$TFA"; XE="$XEA"; else XF="$XFB"; TF="$TFB"; XE="$XEB"; fi
    set -- $XF; xx=$1; xy=$2; xw=$3; xh=$4
    set -- $TF; tx=$1; ty=$2; tw=$3; th=$4
    if [ -z "${xw:-}" ] || [ -z "${tw:-}" ]; then res+=("n/a"); notes="$notes [$which: no frame found]"; continue; fi
    if [ "$xw" != "$tw" ] || [ "$xh" != "$th" ]; then res+=("size!"); notes="$notes [$which frame ${xw}x${xh} vs ${tw}x${th}]"; continue; fi
    set -- $(echo "$XE" | tr -d ','); el=$1; er=$2; et=$3; eb=$4
    magick "$PRIV/x-$T-full.png" -crop ${xw}x${xh}+${xx}+${xy} +repage "$OUT/$T-$which-xfwm4.png"
    magick "$PRIV/t-$T-full.png" -crop ${tw}x${th}+${tx}+${ty} +repage "$OUT/$T-$which-tiewm.png"
    for f in xfwm4 tiewm; do   # blank the client area in both
      magick "$OUT/$T-$which-$f.png" -fill black -draw "rectangle $el,$et $((xw-er-1)),$((xh-eb-1))" "$OUT/$T-$which-$f-m.png"
    done
    compare -metric AE -fuzz 3% "$OUT/$T-$which-xfwm4-m.png" "$OUT/$T-$which-tiewm-m.png" "$OUT/$T-$which-diff.png" >/dev/null 2>&1   # picture only
    n=$("$HERE/imgdiff" "$OUT/$T-$which-xfwm4-m.png" "$OUT/$T-$which-tiewm-m.png" 3 | awk '{print $1}')   # > 3 levels on any channel
    res+=("$n")
  done
  printf '%-14s %-18s %-18s %-9s %-9s %s\n' "$T" "$XEA" "$TEA" "${res[0]}" "${res[1]}" "$notes"
done
pkill -x testwin 2>/dev/null
