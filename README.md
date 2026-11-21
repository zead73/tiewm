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

Works (281 scenario checks, `tools/wmtest.sh`, scratch Xvfb on :99 only): manage/adopt/unmanage, centred
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

Log file (`~/.local/state/tiewm/tiewm.log`, `log_file` / `log_level = off|info|debug`, `tiewm --log` prints the path):
startup line (version, display, theme, desktops), which config was used and its warnings, every managed/unmanaged window,
key reloads, shutdown, and any exception raised inside an event handler (which is caught: one buggy handler cannot take the
session down). Lines are flushed immediately; a file over 512 KiB is rotated to `.1` at start; an unwritable log is ignored.
`TIEWM_LOG=FILE|none` and `TIEWM_DEBUG=1` (debug level + mirror to stderr) override.

Decorations (`_MOTIF_WM_HINTS`): a window that asks for no decorations (decorations field 0, or ALL minus TITLE, or
anything without TITLE: "border only" counts as none) gets no frame graphics at all: the frame is exactly the client,
`_NET_FRAME_EXTENTS` = 0, and nothing is drawn. Changes of the hint while the window is open are followed (titlebar
appears/disappears, the client stays where it is). Undecorated windows still move with Alt+drag, resize with
Alt+right-drag or Alt+F8, maximize/fullscreen/close/menu (Alt+space) as usual; Shade is disabled for them.
The window menu's "No titlebar" entry (Alt+space opens it on an undecorated window) turns the frame off or on for any
window by hand; the client never moves, and a titlebar that would land above the work area pushes the window down.

Minimized windows: an app that asks to start minimized (`WM_HINTS` initial_state = iconic) is managed but left hidden
(WM_STATE Iconic, `_NET_WM_STATE_HIDDEN`, in the client list, no focus stolen) until it is restored from a taskbar, Alt+Tab
or by the app; and at startup tiewm adopts unmapped windows a previous window manager left minimized (WM_STATE Iconic),
keeping them minimized. Unmapped windows that are merely withdrawn are not adopted.

Modal dialogs: a transient window with `_NET_WM_STATE_MODAL` (set at map time or by client message) blocks the window it
is transient for: focusing that window (click on its client area or titlebar, taskbar/`_NET_ACTIVE_WINDOW`, Alt+Tab,
desktop switch) puts the focus on the dialog instead, a click in its client area is swallowed (the app never sees it),
chains (dialog over dialog) go to the topmost one, and closing the dialog hands the focus back. Not modal = no blocking.
Only transient-for blocking is implemented (no WM_CLIENT_LEADER group blocking for modal windows without a parent).

Window states set by the app: `modal`, `above`, `below`, `sticky` at map time are honoured, and everything tiewm does not
manage itself (`skip_taskbar`, `skip_pager`, `demands_attention`, anything unknown) is kept and written back instead of
being wiped, so lxqt-panel still hides skip_taskbar windows. skip_taskbar/skip_pager/demands_attention/modal can also be
changed by client message afterwards. (fullscreen/maximized/shaded/hidden requested in the initial property are not
applied at map time; apps ask for those by client message after mapping.)

App icon: the window's icon (`_NET_WM_ICON`: the smallest size that is at least 16 px, else the biggest, area-averaged
down or up to 16x16 and centred on the menu button) is drawn there when the theme asks for it (`show_app_icon` in the
theme's `themerc`; Daloa does) or the config says `show_app_icon = true`; `false` turns it off. Apps without an icon get a
plain window glyph; icon changes are followed. (No icon-theme lookup by class or WM_HINTS pixmap fallback.) The size follows the theme: see "Theme verification" below.

Button states: titlebar buttons use the theme's `prelight` image under the pointer and its `pressed` image while held
(only while the pointer is still over the button; releasing elsewhere cancels the click). Needs the theme to ship those
images; missing ones fall back to the normal image.

Undecorated border: `undecorated_border = N` (0..16 px, default 0) gives windows without a titlebar a thin solid border in
the palette colour (focused/unfocused) with real resize zones (edges, 16 px corner zones, resize cursors); the frame grows
around the client, `_NET_FRAME_EXTENTS` = N, and the border disappears while maximized or fullscreen.

Window rules: `[windows]` in the config (`Class = titlebar|no_titlebar`, matched by WM_CLASS class or instance, case
insensitive) override what an app asks for. The window menu's "No titlebar" writes the rule itself: only when the choice
differs from the app's own hints (choosing what the app asks for removes the rule again), as one added/changed/removed
line inside `[windows]` with everything else untouched (permissions kept, replaced atomically; a missing file, folder or
section is created). Applies to windows opened afterwards; SIGHUP re-reads hand edits. `--check-config` lists the rules.

Shade: the S button, the window menu, `_NET_WM_STATE_SHADED` (wmctrl -b add,shaded) or the `shade` key action roll a window up
to its titlebar (frame resized, client stays mapped but clipped and still gets its real size in ConfigureNotify; no resize
edges while rolled up; maximize/fullscreen/a client resize request unroll it first).

Keyboard move/resize: Alt+F7 / Alt+F8 (`move_window` / `resize_window`) grab the keyboard; arrow keys move or resize by
10 px (Shift: 1 px; step-sized windows such as terminals resize one step at a time, min/max honoured), Return confirms,
Escape puts the window back. Not available for maximized, fullscreen, minimized windows (resize also not when shaded).

Window menu (`twmenu.pas`, drawn with Xlib/Xft, no toolkit): right-click the titlebar, click the O button, or Alt+space
(`window_menu`). Minimize, Maximize/Restore, Fullscreen, Always on top, On all workspaces, Move to Workspace N (the
current one is disabled), Close. Mouse (hover, release to select, click outside to close) and keyboard (Up/Down, Return,
Escape); the release of the click that opened it is ignored. Always on top (`_NET_WM_STATE_ABOVE`) and Always below (`_NET_WM_STATE_BELOW`) are real states and exclude each other.
Layers, bottom to top: desktop window, conky-style below-docks, below-windows, normal windows, above-windows, docks
(fullscreen windows go over everything).

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

App-driven moves and window gravity: `_NET_WM_MOVERESIZE` (what GTK client-side-decorated and frameless Qt windows send
when you drag their own title area or edge): all eight resize directions, move, and the keyboard variants (same modes as
Alt+F8 / Alt+F7); a stale request with no button held is ignored, and the pointer drag then behaves exactly like a titlebar
drag. `_NET_MOVERESIZE_WINDOW` (`wmctrl -e`) places and sizes a window by a given gravity. Initial positions and
ConfigureRequests now follow ICCCM `win_gravity`: with the default (NorthWest) the *frame's* corner goes where the app asked
(as `xterm -geometry +100+100` users expect); Static puts the client itself there; the other gravities anchor the frame on
the matching edge or centre. `_NET_WM_STATE_BELOW` and the two new messages are listed in `_NET_SUPPORTED`.

Careful when testing: the live session runs a process called `tiewm` too, so test scripts must never `pkill` by name
(`wmtest.sh` only signals a tiewm whose DISPLAY is :99).

Nested trial (`tools/nested.sh start|stop|shot`, needs xorg-server-xephyr): tiewm in Xephyr :2 with its own D-Bus
session and a copy of the LXQt config, running the real lxqt-panel, pcmanfm-qt, qterminal and Vivaldi (throwaway
profile). Verified 2026-11-20: panel docks with its 32 px strut (maximize = work area), taskbar lists windows and
click-to-activate / click-again-to-minimize / restore work, Alt+Tab, fullscreen, a real Qt dialog (Create Folder) is
transient/centred/focused, Vivaldi F11 fullscreen on and off. Found and fixed: lxqt-panel's taskbar shows nothing
unless every window has `_NET_WM_DESKTOP`.

## Done: titlebar removal for windows that draw their own

- **Remove the titlebar of a window that already draws its own** (Electron/CSD apps such as the Claude desktop app),
  and remember the choice in the config file.
  1. ~~Honour `_MOTIF_WM_HINTS` (decorations = 0) automatically~~ **done**: the Claude desktop window asks for no
     decorations (`_MOTIF_WM_HINTS = 0x2, 0, 0, 0, 0`, `WM_CLASS = com.anthropic.claude`) and now gets none.
  2. ~~A manual toggle for apps that do not ask~~ **done**: "No titlebar" in the window menu (menu only, no key action).
     The user's choice wins over any later `_MOTIF_WM_HINTS` change.
  3. ~~Persist it per application in the config file~~ **done**: a `[windows]` section, `Class = no_titlebar` or
     `Class = titlebar`, matched by `WM_CLASS` (class or instance, case-insensitive); the menu toggle writes/removes the
     line itself and leaves the rest of the file, comments included, byte-for-byte alone.
  4. ~~Keep undecorated windows usable~~ **done**: Alt+drag moves them, Alt+right-drag / Alt+F8 resize them, and the
     optional `undecorated_border = N` config setting adds a thin N-pixel resize border (drag an edge or corner).

Deliberately not done: other key bindings, `--replace`,
multi-monitor, session
management, gravity/transient-for handling, `_NET_WM_MOVERESIZE`. Not yet run against the real LXQt
session or lxqt-panel.

## What was learned from real xfwm4 (Daloa, Adwaita-dark, 2026-11-20)

- A part = XPM (symbolic colours filled from a GTK-derived palette) with the PNG alpha-blended
  on top; where the XPM is transparent the PNG is not drawn. The PNG sets the size.
- Palette: `*_hilight_N` = base shaded 1.3, `*_shadow_N` = base shaded 0.7 (GTK2 HLS shade),
  `*_mid_N` = average of the two (all verified against xfwm4, truncating not rounding). Here color_1 active = #15539E,
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

## Theme verification against real xfwm4

`tools/themecheck.sh [theme ...]` renders the same two windows (empty title, a deterministic 16x16 icon) under real xfwm4
and under tiewm for every installed xfwm4 theme on the scratch display :99 and counts the pixels that differ by more than
3 levels (`tools/imgdiff`), client area excluded; diff pictures go to `out/themes/`. xfwm4 runs on a private D-Bus session
with a private config folder, so the real xfwm4 settings are never touched. Result (2026-11-20, GTK theme Adwaita-dark),
inactive / active window: **Daloa 0/0, Default 0/0, Default-hdpi 0/0, Default-xhdpi 0/0, Kokodi 0/0, Nordic 0/0,
Moheli 0/4** (the 4 are single pixels where Moheli's two title zones meet on the first and last row). Frame extents match
xfwm4 for all seven.

What the comparison found (each is now implemented):
- The palette: a probe theme with one title column per symbolic colour name, rendered by xfwm4, gave the exact table
  (`tools/palettecheck.pas` checks the derived values): base blue is #15539E, shades are *truncated* not rounded, and
  `active_text_color` / `*_text_shadow_color` / `*_border_color` exist.
- Button glyphs that use the symbol `active_text_color` take the value the theme's own `themerc` sets for it
  (Default: `active_text_color_2`), not the palette's.
- Title strip zones: `title-1` tiled under the left button group, `title-5` under the right group, `title-3` between
  (`full_width_title`, the default); `title-2`/`title-4` only around the text when it is off. The zones reach past the
  buttons by (corner width - border width) pixels.
- A part is sized by its XPM, with the PNG laid over it from the top-left (Daloa's menu button is the top 16 rows of its
  19-row PNG). A title tile can be a row taller than the title: it is clipped to the title height.
- Corner parts that have only a PNG (Nordic): every pixel that is not fully opaque is cut out.
- Buttons are centred vertically in the title: y = (title height - button height + 1) / 2.
- App icon: scaled to the smaller side of the menu button's XPM (22 px in Default, 44 in Default-xhdpi), centred with the
  vertical offset rounded up, and the menu button is drawn only over the icon's rows when it is taller than the icon.

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
