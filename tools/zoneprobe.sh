#!/bin/bash
# Title-strip probe: makes a copy of Moheli whose five title tiles are solid, distinct colours (title-1 red, 2 yellow, 3 green,
# 4 cyan, 5 blue), renders it with real xfwm4 and with tiewm on the scratch display :99, and prints where each colour begins
# and ends along the first row of the active frame. Equal lines = the same layout. Needs python3 with PIL (python-pillow).
#   tools/zoneprobe.sh NAME,TILEW,CORNERW,BUTTON_OFFSET [...]
#   FW=false (full_width_title) and TITLE="text" select the other layouts.  Example: tools/zoneprobe.sh v0,4,7,0 v1,8,7,0
# xfwm4 runs on a private D-Bus session with a private HOME / config, so your own settings are never touched.
set -u
export DISPLAY=:99
HERE="$(cd "$(dirname "$0")" && pwd)"; R="$(dirname "$HERE")"
TW=$R/tools/testwin; XG=$R/tools/xgeom; WM=$R/tiewm
S="${ZONEPROBE_TMP:-/tmp/tiewm-zoneprobe}"; mkdir -p "$S"
[ -e /tmp/.X11-unix/X99 ] || { Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 & sleep 1; }
variant() {  # name tilew cornerw offset
  local N=$1 TWID=$2 CW=$3 OFF=$4
  local D=$S/home-$N/.themes/Probe/xfwm4
  rm -rf "$S/home-$N"; mkdir -p "$D"
  cp /usr/share/themes/Moheli/xfwm4/* "$D/"
  local i=1; for c in red yellow green cyan blue; do
    for st in active inactive; do
      magick -size ${TWID}x23 xc:$c "$D/title-$i-$st.png"; magick -size ${TWID}x23 xc:$c "$D/title-$i-$st.xpm"
    done; i=$((i+1))
  done
  for side in left right; do for st in active inactive; do   # corner width
    magick -size ${CW}x23 xc:none "PNG32:$D/top-$side-$st.png"; magick -size ${CW}x23 xc:none "$D/top-$side-$st.xpm"
  done; done
  sed -i "s/^button_offset=.*/button_offset=$OFF/" "$D/themerc"
  sed -i "s/^full_width_title=.*/full_width_title=${FW:-true}/" "$D/themerc"
  mkdir -p "$S/home-$N/.local/share"; ln -s "$S/home-$N/.themes" "$S/home-$N/.local/share/themes"
}
shot() {  # name who(xfwm4|tiewm)
  local N=$1 W=$2 H=$S/home-$N
  mkdir -p "$H/cfg/xfce4/xfconf/xfce-perchannel-xml" "$H/cfg/gtk-3.0"
  cp ~/.config/gtk-3.0/settings.ini "$H/cfg/gtk-3.0/" 2>/dev/null
  cat >"$H/cfg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0"><property name="general" type="empty">
<property name="theme" type="string" value="Probe"/><property name="title_font" type="string" value="Sans Bold 11"/>
<property name="use_compositing" type="bool" value="false"/><property name="title_alignment" type="string" value="left"/></property></channel>
XML
  if [ $W = xfwm4 ]; then
    ( unset WAYLAND_DISPLAY; export HOME="$H" XDG_CONFIG_HOME="$H/cfg" XDG_DATA_HOME="$H/.local/share" XDG_CACHE_HOME="$H/cache"
      exec setsid dbus-run-session -- xfwm4 --compositor=off ) >"$H/x.log" 2>&1 &
    sleep 2.5
  else
    printf "[general]\ntitle_align = left\n" > "$H/t.conf"; HOME="$H" TIEWM_CONFIG="$H/t.conf" TIEWM_LOG="$H/t.log" TIEWM_THEME=Probe "$WM" 2>"$H/t.err" & TP=$!; sleep 1
  fi
  "$TW" -t " " -w 300 -h 200 -c 3a3a3a -s 30 -p 150,120 >/dev/null 2>&1 &
  sleep 1.2
  "$TW" -t "${TITLE:- }" -w 300 -h 200 -c 3a3a3a -s 30 -p 600,380 >"$H/b.log" 2>&1 &
  sleep 1.5
  local B=$(sed -n 's/^mapped id=\(0x[0-9a-fA-F]*\).*/\1/p' "$H/b.log" | head -1)
  local F=$("$XG" | awk -v id="$(printf '0x%X' "$(printf '%d' "$B")")" '/^win=/{top=$0} /^  win=/{ if ($1=="win="id) print top}' | sed -n 's/.*x=\([-0-9]*\) y=\([-0-9]*\) w=\([0-9]*\) h=\([0-9]*\).*/\1 \2 \3 \4/p')
  import -window root "$H/full-$W.png" 2>/dev/null
  pkill -x testwin; sleep 0.4
  if [ $W = xfwm4 ]; then
    for p in $(pgrep -x xfwm4); do tr '\0' '\n' </proc/$p/environ 2>/dev/null | grep -qx "XDG_CONFIG_HOME=$H/cfg" && kill -TERM $p; done; sleep 1
  else kill -TERM $TP 2>/dev/null; wait $TP 2>/dev/null; sleep 0.5; fi
  set -- $F
  python3 - "$H/full-$W.png" $1 $2 $3 $4 <<'PY'
import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert("RGB"); x,y,w,h=map(int,sys.argv[2:6])
names={(255,0,0):"R",(255,255,0):"Y",(0,128,0):"G",(0,255,255):"C",(0,0,255):"B"}
def runs(row):
    out=[];prev=None;start=0
    for i in range(w):
        c=names.get(im.getpixel((x+i,y+row)),"?")
        if c!=prev:
            if prev is not None: out.append(f"{prev}[{start}-{i-1}]")
            prev=c;start=i
    out.append(f"{prev}[{start}-{w-1}]"); return " ".join(out)
print("   row0:",runs(0)); print("   row22:",runs(22))
PY
}
for spec in "$@"; do
  set -- $(echo $spec | tr ',' ' '); N=$1
  variant $N $2 $3 $4
  echo "== $N (tile $2 px, corner $3 px, button_offset $4)"
  echo " xfwm4:"; shot $N xfwm4
  echo " tiewm:"; shot $N tiewm
done
