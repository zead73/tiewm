# tiewm

A floating X11 window manager in Free Pascal, meant to replace xfwm4 under LXQt.
picom already does the compositing, so the WM only has to manage and draw frames.
Feature list: `../xfwm4-checklist.md`.

## Status (2026-11-20)

Step 1, the xfwm4 theme engine, is done as far as it can be tested without an X server:

- `twimage.pas` – ARGB pixel buffers, PNG load/save, XPM parser with symbolic colours.
- `twtheme.pas` – reads `/usr/share/themes/<name>/xfwm4` (themerc + parts), derives the
  palette, composes a whole frame (corners, title strip, buttons, sides, bottom) into a `TImg`.
- `tools/themetest.pas` – composes a frame and diffs it against a real xfwm4 screenshot.
- `tools/themescan.pas` – loads and composes every installed xfwm4 theme (7 here, all load).
- `tools/testwin.pas` – test client (logs ConfigureNotify/clicks/focus/WM_DELETE, optional min size,
  USPosition, delayed title change); `tools/xdo.pas` – fake input via XTest; `tools/xgeom.pas` – window
  tree / root-relative geometry dump; `tools/wmtest.sh` – the scenario suite; `tools/paintbench.pas` –
  paint timing (2560x1440 frame: ~31 ms).

Step 2, title text and shape, is also done (needs a display; tested in Xvfb):

- `twxshape.pas` – own binding to libXext's Shape extension (FPC has none).
- `twxft.pas` – own Xft/fontconfig binding (FPC's Xft unit lacks colour alloc and has awkward
  records) + `PangoToFontconfig` ("Sans Bold 11" -> "Sans:bold:size=11").
- `twxdraw.pas` – `TTitleFont` (width, ellipsis fit, outline/shadow draw), `ImgToPixmap`,
  `MaskFromImg`, and `PaintFrame` which returns a finished frame pixmap + shape mask.
- `tools/framecheck.pas` – diffs `PaintFrame` output against real xfwm4; `tools/shapewin.pas`
  puts a shaped frame window on screen for a screenshot check.

Step 3, the window manager (`tiewm.pas` + `twwm.pas`), is a verified vertical slice. Build: `./build.sh`.
Run it ONLY on a display you mean to manage: `DISPLAY=:99 ./tiewm` (it refuses to start if another WM owns
the root; `TIEWM_THEME`, `TIEWM_FONT`, `TIEWM_DEBUG=1` are the only settings so far). SIGTERM/SIGINT hand all
windows back to the root cleanly.

Works (106 scenario checks, `tools/wmtest.sh`, scratch Xvfb on :99 only): manage/adopt/unmanage, centred
placement (honours USPosition), themed frames with shape, click-to-focus with click replay to the app,
raise on click, active/inactive repaint, title updates, titlebar drag and Alt+drag (also with Num/Caps Lock),
Alt+right-drag resize, edge/corner resize with min-size and size-increment hints, close button
(WM_DELETE_WINDOW, XKillClient fallback), maximize button / double-click / `_NET_WM_STATE`, dock struts for
the work area, save-set so clients survive a WM crash, EWMH: `_NET_SUPPORTED`, `_NET_SUPPORTING_WM_CHECK`,
`_NET_CLIENT_LIST(_STACKING)`, `_NET_ACTIVE_WINDOW` (+ client message), `_NET_CLOSE_WINDOW`,
`_NET_FRAME_EXTENTS`, `_NET_WORKAREA`, 1 desktop.

Added for the live-trial plan: keys Alt+F4 (close), Alt+Tab / Alt+Shift+Tab (MRU cycling while Alt is held,
keyboard grabbed, includes iconic windows), Super+Return (maximize), Alt+F9 (iconify), Alt+F11 (fullscreen),
all with Caps/Num Lock; fullscreen (`_NET_WM_STATE_FULLSCREEN`, no decorations, extents 0, raised above docks);
iconify (H button, Alt+F9, `WM_CHANGE_STATE`, `_NET_WM_STATE_HIDDEN`, WM_STATE Iconic, restored by
`_NET_ACTIVE_WINDOW` / Alt+Tab / the client mapping itself again); `WM_TRANSIENT_FOR` dialogs (centred over the
parent, kept above it when it is raised, iconified with it, focus returns to the parent when the dialog closes).

Config file `~/.config/tiewm/tiewm.conf` (`tiewm.conf.example` documents everything; `TIEWM_CONFIG=FILE` picks another):
theme, title font and alignment, button layout, number of desktops, font hinting, palette colours, and every key binding
(actions: close, cycle, cycle_back, maximize, iconify, fullscreen, desktop_left/right, move_left/right,
goto_desktop_N, move_to_desktop_N; listing an action replaces its defaults, `none` disables it). A bad line is only a
warning and the default stays; an unknown theme falls back to Daloa. `tiewm --check-config [FILE]` validates a file
without a display (exit 1 if there are warnings); SIGHUP re-reads the key bindings in a running tiewm. Environment
variables TIEWM_THEME / TIEWM_FONT / TIEWM_DESKTOPS override the file. Tests never read the real config (they point
TIEWM_CONFIG at a missing file).

Workspaces: 4 desktops (`TIEWM_DESKTOPS=N`, 1..20), `_NET_NUMBER_OF_DESKTOPS` / `_CURRENT_DESKTOP` / `_DESKTOP_NAMES`
("Workspace N") / per-desktop `_NET_WORKAREA`, `_NET_WM_DESKTOP` on every client (and its client message to move a window),
`_NET_CURRENT_DESKTOP` client message (lxqt-panel switcher, wmctrl -s), sticky windows (`_NET_WM_STATE_STICKY` = desktop
0xFFFFFFFF), new windows and transients open on the current desktop (transients on their parent's), activating a window on
another desktop switches to it (xfwm4's activate_action=switch), Alt+Tab only cycles the current desktop's windows,
Ctrl+Alt+Left/Right switch (no wrap), Ctrl+Alt+Shift+Left/Right move the focused window and follow it. Hidden = frame
unmapped (client stays mapped, WM_STATE stays Normal); docks and the desktop window show on every desktop. Verified with
the real lxqt-panel switcher in the nested session.

Stacking layers (found on the first real session, 2026-11-20: the full-screen pcmanfm-desktop window covered the
panel and conky): desktop-type windows are kept at the very bottom, docks with `_NET_WM_STATE_BELOW` (conky) just
above them, normal frames above that, other docks (the panel) on top; while a window is fullscreen the panel is
left underneath. Re-applied after every raise, fullscreen change and dock/desktop mapping.

Careful when testing: the live session runs a process called `tiewm` too, so test scripts must never `pkill` by name
(`wmtest.sh` only signals a tiewm whose DISPLAY is :99).

Nested trial (`tools/nested.sh start|stop|shot`, needs xorg-server-xephyr): tiewm in Xephyr :2 with its own D-Bus
session and a copy of the LXQt config, running the real lxqt-panel, pcmanfm-qt, qterminal and Vivaldi (throwaway
profile). Verified 2026-11-20: panel docks with its 32 px strut (maximize = work area), taskbar lists windows and
click-to-activate / click-again-to-minimize / restore work, Alt+Tab, fullscreen, a real Qt dialog (Create Folder) is
transient/centred/focused, Vivaldi F11 fullscreen on and off. Found and fixed: lxqt-panel's taskbar shows nothing
unless every window has `_NET_WM_DESKTOP`.

Deliberately not done: shade, other key bindings `--replace`,
multi-monitor, window menu, `_NET_WM_STATE_ABOVE`, modal dialogs, adopting windows that are
iconic when the WM starts, button prelight/pressed images, app icon in the menu button, session
management, gravity/transient-for handling, `_NET_WM_MOVERESIZE`. Not yet run against the real LXQt
session or lxqt-panel.

## What was learned from real xfwm4 (Daloa, Adwaita-dark, 2026-11-20)

- A part = XPM (symbolic colours filled from a GTK-derived palette) with the PNG alpha-blended
  on top; where the XPM is transparent the PNG is not drawn. The PNG sets the size.
- Palette: `*_hilight_N` = base shaded 1.3, `*_shadow_N` = base shaded 0.7 (GTK2 HLS shade),
  `*_mid_N` = average of the two (mid not yet verified). Here color_1 active = #14529E,
  inactive = #323232, color_2 = #353535 for both. Left/right/bottom borders use color_2.
- `themerc` beats xfconf for `button_offset` (1) and `button_spacing` (-1): pixels match themerc.
- Buttons start at x = left border + button_offset and overlap by -spacing; the right group is
  placed right-to-left but drawn left-to-right (each button's left edge wins).
- Frame extents come from the parts: left/right/bottom = pixmap widths/height, top = title tile height
  (Daloa 5,5,19,5 — same as `_NET_FRAME_EXTENTS` xfwm4 reports).

Frame graphics vs. real xfwm4 (ignoring client area, title text, app icon): 19 of 6343 pixels (active)
and 19 of 9743 (inactive) – all in the menu button's left edge column (x=6).

Title text and shape (`framecheck`): borders+bottom 0 differing pixels; title row incl. text 128 of 5472
(active, 2.3%) and 38 of 7372 (inactive, 0.5%) – all antialiasing differences in the glyphs. Shape: the
4 corner cuts land exactly on background pixels of the reference, and a real shaped window shows the
root through them.

Text rules measured from xfwm4 (Sans Bold 11, Xvfb 96 dpi):
- text x = end of the left buttons + 5 (+ title_horizontal_offset); baseline =
  (title height - font height)/2 + ascent + title_vertical_offset_*  (19, 21, 16 -> baseline 16)
- greyscale antialiasing and full hinting match best (hintstyle 3: 128 vs 227 mismatches at slight, 434 none);
  the user's fontconfig forces rgba=rgb *after* name parsing, so it has to be set on the matched pattern
- `title_shadow_active=frame` = outline in `active_shadow_1`, drawn at the 4 neighbouring offsets
- inactive text colour (not in Daloa's themerc) measured as #919190; no shadow when `false`
- the menu button's app icon is not drawn yet (client icon support is a later step)

## Reproducing the reference frames

    Xvfb :99 -screen 0 1024x768x24 &
    DISPLAY=:99 xfwm4 --compositor=off &
    DISPLAY=:99 tools/testwin "Active window" 400 300 ff00ff &
    DISPLAY=:99 tools/testwin "Other window" 300 200 00ffff &
    DISPLAY=:99 import -window root ref/daloa-full.png

Build tools: `fpc -Mobjfpc -Sh -O1 -Fu.. themetest.pas` (from `tools/`). `framecheck` and `shapewin` need
`DISPLAY` pointing at an X server (Xvfb is fine).

## License

The source code is MIT licensed, see [LICENSE](LICENSE). The exception is the Daloa renders described below.

## Third-party material

The images `ref/daloa-full.png`, `ref/frame-active-310x224.png`, `ref/frame-inactive-410x324.png` and
`out/tiewm-demo.png` are renders of the **Daloa** xfwm4 theme (made by real xfwm4 and by tiewm). Daloa is
GPL-licensed ("Created May 2006 by Mike Massonnet, modified by Olivier Fourdan, released under the GNU GPL", per its
README), so these images are covered by the GPL of that theme, **not** by the license of tiewm's source code.
They are test fixtures and a demo screenshot only.

No theme files are included in this repository: themes are read at runtime from `/usr/share/themes/<name>/xfwm4` or
`~/.themes/<name>/xfwm4`, and each theme keeps its own license.
