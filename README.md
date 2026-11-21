# tiewm

A floating X11 window manager written in Free Pascal (FPC 3.2.2, plain Xlib, no LCL). It draws real xfwm4 themes, so it
can replace xfwm4 under LXQt; picom already does the compositing, so the WM only has to manage windows and draw frames.
The point of the project is learning and showing what Pascal can do.

Status (tiewm 0.5): in daily use as the author's window manager, on two monitors. 331 scenario checks pass against a
scratch X server, and all seven installed xfwm4 themes match real xfwm4 pixel for pixel.

- [Features](#features)
- [Default keys and mouse](#default-keys-and-mouse)
- [Configuration](#configuration)
- [Building and running](#building-and-running)
- [Testing](#testing)
- [Source layout](#source-layout)
- [How the theme engine works](#how-the-theme-engine-works)
- [Not done](#not-done)
- [License](#license)

## Features

### Windows and frames

- **xfwm4 themes**: any theme in `/usr/share/themes/<name>/xfwm4` or `~/.themes/<name>/xfwm4` (themerc plus XPM/PNG parts),
  with title text (Xft), the shape cut for rounded corners, button hover / pressed / toggled images and the application's icon
  on the menu button. An unknown theme falls back to Daloa.
- **Titlebar buttons**: layout string such as `O|SHMC` (O menu, T stick, S shade, H hide, M maximize, C close; letters before
  `|` go left). The default has no T, as in xfwm4; `O|TSHMC` adds the "on all workspaces" button. Buttons whose state is on
  (stick, shade, maximize) use the theme's `-toggled` image; a button shows "pressed" only while the pointer is still over it.
- **Decorations** (`_MOTIF_WM_HINTS`): a window that asks for no titlebar gets no frame graphics at all (the frame is exactly
  the client, `_NET_FRAME_EXTENTS` = 0); changes of the hint are followed. Undecorated windows still move with Alt+drag, resize
  with Alt+right-drag or Alt+F8, and have the window menu. `undecorated_border = N` gives them a thin resize border. Splash
  windows (`_NET_WM_WINDOW_TYPE_SPLASH`) get no frame.
- **Remove the titlebar of a window by hand**: "No titlebar" in the window menu. The choice is saved per application (by
  `WM_CLASS`) as a line in the `[windows]` section of the config file; nothing else in the file is touched.
- **States**: maximize (button, double-click, key, `_NET_WM_STATE`), fullscreen, minimize, shade (rolled up to the titlebar),
  always on top, always below, on all workspaces, skip taskbar / pager, demands attention. States an app sets at map time
  are honoured and the ones tiewm does not manage itself are kept, so the panel still hides skip-taskbar windows.
- **Minimized windows**: an app that starts minimized stays hidden (WM_STATE Iconic, in the client list, no focus stolen); at
  startup, windows a previous WM left minimized are adopted and stay minimized.
- **Dialogs**: `WM_TRANSIENT_FOR` windows are centred over their parent, kept above it, minimized with it, and hand the focus
  back when closed. A *modal* dialog (`_NET_WM_STATE_MODAL`) blocks the window it belongs to (or, if it names no parent, the
  windows sharing its `WM_CLIENT_LEADER`): focusing the blocked window focuses the dialog instead and clicks on it are swallowed.
- **Urgency**: the `WM_HINTS` urgency bit shows as `_NET_WM_STATE_DEMANDS_ATTENTION` for the panel and clears when the window
  gets the focus.

### Moving, resizing and size hints

- Drag the titlebar or any edge or corner; Alt+left-drag moves and Alt+right-drag resizes (also with Num/Caps Lock on).
- Alt+F7 / Alt+F8 move / resize the focused window with the arrow keys (10 px, Shift for 1 px, Return confirms, Escape cancels).
- `WM_NORMAL_HINTS`: minimum / maximum size, resize increments (terminals resize a cell at a time), base size and aspect ratio.
- **Gravity** (ICCCM `win_gravity`): with the default NorthWest, the *frame's* corner goes where an app asked to be placed (as
  `xterm -geometry +100+100` users expect); Static puts the client itself there.
- **Apps with their own titlebars** (GTK client-side decorations, frameless Qt windows) can start a move or resize through
  `_NET_WM_MOVERESIZE` (all directions, keyboard variants, cancel). `_NET_MOVERESIZE_WINDOW` (`wmctrl -e`) works too.
- New windows are centred on the monitor under the pointer, or where the app asks (USPosition / PPosition).

### Focus and stacking

- Click to focus and raise (the click is replayed to the app). Optional **focus follows the mouse**: `focus_mode = follow`
  focuses the window under the pointer after `focus_delay` ms (default 250), without raising; passing over a window faster than
  the delay does nothing, and the bare desktop keeps the focus.
- **Alt+Tab** cycles the current workspace's windows in most-recently-used order, minimized ones included, while Alt is held.
  A list of the windows is drawn in the middle of the pointer's monitor (selected row highlighted, minimized ones dimmed and
  marked "(minimized)"); no thumbnails.
- **Layers**, bottom to top: desktop window, conky-style docks with `_NET_WM_STATE_BELOW`, below-windows, normal windows,
  above-windows, other docks (the panel). A fullscreen window goes over everything. Re-applied after every raise.
- **Closing**: `WM_DELETE_WINDOW`, with `XKillClient` for apps that do not support it. If an app supports `_NET_WM_PING`, it is
  pinged when closed; click Close again more than 3 seconds after an unanswered ping and tiewm kills it.

### Window menu

Right-click the titlebar, click the O button, or press Alt+space. Minimize, Maximize/Restore, Fullscreen, Always on top, Always
below, On all workspaces, Shade, No titlebar, Move to Workspace N, Move to Monitor N (only with more than one monitor), Close.
It is drawn with Xlib/Xft (`twmenu.pas`, no toolkit): mouse (hover, release to select, click outside to close) and keyboard
(Up/Down, Return, Escape).

### Workspaces

4 desktops by default (`desktops = N`, 1 to 20; names "Workspace N"). Sticky windows are on all of them. Activating a window
on another workspace switches to it. Hidden windows are simply unmapped frames (WM_STATE stays Normal). Panel switchers
(`_NET_CURRENT_DESKTOP`), `wmctrl -s` and moving windows with `_NET_WM_DESKTOP` all work. No wrap-around at the ends.

### Several monitors

Uses the RandR 1.5 monitor list (`twxrandr.pas`). Maximize fills the free area of the monitor the window is on; fullscreen
fills that monitor only; dock struts count for a monitor only where their band reaches into it (partial struts are honoured,
so a panel on one monitor does not shrink the other). Plug or unplug a monitor, or change resolution: fullscreen and
maximized windows refit, and a window left off every monitor is pulled onto the nearest one. RandR sends events for real
hardware changes but none for client-defined monitors (`xrandr --setmonitor`), so the main loop also polls every 2 seconds.
Monitors are ordered left to right. `_NET_WORKAREA` is the box around all of them.

### Compatibility (what panels, taskbars and toolkits get)

`_NET_SUPPORTED`, `_NET_SUPPORTING_WM_CHECK`, `_NET_CLIENT_LIST(_STACKING)`, `_NET_ACTIVE_WINDOW` (property and client message),
`_NET_CLOSE_WINDOW`, `_NET_NUMBER_OF_DESKTOPS`, `_NET_CURRENT_DESKTOP`, `_NET_DESKTOP_NAMES`, `_NET_DESKTOP_GEOMETRY`,
`_NET_DESKTOP_VIEWPORT`, `_NET_WORKAREA`, `_NET_WM_DESKTOP` (on every client; lxqt-panel's taskbar shows nothing without it),
`_NET_WM_STATE` and its client messages, `_NET_WM_ALLOWED_ACTIONS` (no resize or maximize for a fixed-size window, no shade
without a titlebar), `_NET_FRAME_EXTENTS`, `_NET_REQUEST_FRAME_EXTENTS`, `_NET_WM_STRUT(_PARTIAL)`, `_NET_WM_MOVERESIZE`,
`_NET_MOVERESIZE_WINDOW`, `_NET_WM_PING`, `_NET_WM_ICON`, `_NET_WM_WINDOW_TYPE`, `WM_CHANGE_STATE`, `WM_STATE`, `WM_PROTOCOLS`.
Clients survive a crash of the WM (save-set), and SIGTERM / SIGINT hand every window back to the root.

## Default keys and mouse

| Action | Default |
|---|---|
| Close | Alt+F4 |
| Next / previous window | Alt+Tab / Alt+Shift+Tab |
| Maximize | Super+Return (also double-click the titlebar) |
| Minimize | Alt+F9 |
| Fullscreen | Alt+F11 |
| Always on top | Alt+F12 |
| Keyboard move / resize | Alt+F7 / Alt+F8 |
| Window menu | Alt+space (also right-click the titlebar) |
| Previous / next workspace | Ctrl+Alt+Left / Ctrl+Alt+Right |
| Move window to previous / next workspace and follow it | Ctrl+Alt+Shift+Left / Right |
| Move window to the monitor on its left / right | Super+Shift+Left / Right (no wrapping) |
| Shade | no default key (S button or window menu) |
| Move / resize with the mouse | Alt+left-drag / Alt+right-drag |

Every key is rebindable in the config file. Caps Lock and Num Lock never matter. Print Screen is not handled by tiewm (LXQt's
shortcut daemon does it).

## Configuration

`~/.config/tiewm/tiewm.conf`; [`tiewm.conf.example`](tiewm.conf.example) documents every setting. `TIEWM_CONFIG=FILE` picks
another file. A bad line is only a warning and the default stays. `tiewm --check-config [FILE]` validates a file without a
display (exit 1 if there are warnings). SIGHUP re-reads the key bindings and the window rules of a running tiewm; other
settings need a restart.

- **`[general]`**: `theme`, `title_font`, `menu_font`, `title_align`, `button_layout`, `desktops`, `undecorated_border`,
  `focus_mode`, `focus_delay`, `show_app_icon` (`auto` follows the theme), `font_greyscale`, `font_hinting`, `log_file`,
  `log_level` (`off|info|debug`).
- **`[colors]`**: the palette that stands in for the GTK colours xfwm4 reads (active / inactive frame colours, text, border).
  The defaults are the values xfwm4 produces with the Adwaita-dark GTK theme. They cannot be read from GTK without linking
  libgtk (Adwaita's colours are compiled into it), so change them here if you use another GTK theme.
- **`[keys]`**: `action = Combo[, Combo ...]`. Listing an action replaces all its defaults; `none` disables it. Actions: `close`,
  `cycle`, `cycle_back`, `maximize`, `iconify`, `fullscreen`, `above`, `desktop_left`, `desktop_right`, `move_left`, `move_right`,
  `window_menu`, `shade`, `move_window`, `resize_window`, `move_to_next_monitor`, `move_to_prev_monitor`, `goto_desktop_N`,
  `move_to_desktop_N`.
- **`[windows]`**: per-application rules matched by `WM_CLASS` (class or instance, any case): `Class = titlebar|no_titlebar`.
  The window menu writes these itself (only when your choice differs from what the app asks for), in place and atomically.
- **Environment**: `TIEWM_THEME`, `TIEWM_FONT`, `TIEWM_DESKTOPS`, `TIEWM_CONFIG`, `TIEWM_LOG=FILE|none`, `TIEWM_DEBUG=1` (debug
  level, mirrored to stderr) override the file.
- **Log**: `~/.local/state/tiewm/tiewm.log` (`tiewm --log` prints the path): version, display, theme, monitors, which config was
  used and its warnings, every managed / unmanaged window, why a hung app was killed, and any exception raised inside an event
  handler (caught, so one buggy handler cannot take the session down). Flushed per line; rotated to `.1` over 512 KiB.

## Building and running

    ./build.sh            # builds tiewm and every tool in tools/ (units go to a temp dir)

Needs FPC 3.2.2 and the X11 libraries (Xlib, Xft, Xext, Xrandr, Xtst for the tests). Run it **only on a display you mean to
manage**: it refuses to start while another window manager owns the root.

    DISPLAY=:99 ./tiewm   # on a scratch Xvfb, for example
    tiewm --version       # prints the version
    tiewm --log           # prints the log file path

To use it as your window manager, point the session at the binary (for LXQt, the window manager setting in the session
options, with `tiewm` in the PATH).

## Testing

- `tools/wmtest.sh` is the scenario suite: it starts its own Xvfb on **:99** (and a second one on :97 for the multi-monitor
  scenarios), drives real X clients with XTest and checks the result. It takes about 10 minutes, so run it in the
  background. It never reads your real config or writes your real log, and it only signals a tiewm whose `DISPLAY` is :99.
  **Never `pkill tiewm` in test scripts: the live session runs a process with the same name.**
- `tools/testwin.pas` is the test client (logs what the WM does to it; options for hints, states, types, gravity, urgency,
  aspect, ping, a hung app, ...); `tools/xdo.pas` sends fake input via XTest; `tools/xgeom.pas` dumps the window tree with
  root-relative geometry; `tools/monset.pas` defines virtual RandR monitors.
- `tools/themecheck.sh [theme ...]` renders the same two windows under **real xfwm4** and under tiewm for every installed
  theme and counts the pixels that differ (see below). xfwm4 runs on a private D-Bus session with a private config folder,
  so your real xfwm4 settings are never touched.
- `tools/zoneprobe.sh` paints a copy of Moheli's title tiles in distinct colours and prints where each one begins and ends in
  xfwm4's frame and in tiewm's (this is how the title-strip layout below was found).
- `tools/nested.sh start|stop|shot` runs tiewm in Xephyr with its own D-Bus session and a copy of the LXQt config, with the real
  lxqt-panel, pcmanfm-qt, qterminal and Vivaldi, fully isolated from the live session.
- `tools/paintbench.pas` times frame painting (a 2560x1440 frame takes about 2 ms, because only the border strips are
  converted and uploaded). `tools/palettecheck.pas`, `themetest`, `themescan`, `framecheck` and `shapewin` are the theme
  engine's own checks.

## Source layout

| File | What it is |
|---|---|
| `tiewm.pas` | the program: options, signals, start-up |
| `twwm.pas` | the window manager: events, frames, focus, drags, keys, menu actions, workspaces, monitors, EWMH |
| `twconfig.pas` | config file parsing and writing, key bindings, window rules |
| `twtheme.pas` | reads an xfwm4 theme and composes a whole frame into an image |
| `twimage.pas` | ARGB pixel buffers, PNG load / save, XPM parser with symbolic colours |
| `twxdraw.pas` | title text, frame pixmap and shape mask |
| `twxft.pas`, `twxshape.pas`, `twxrandr.pas` | own bindings to Xft / fontconfig, the Shape extension and RandR (FPC ships none that fit) |
| `twmenu.pas` | the popup menu, drawn with Xlib / Xft |
| `twlog.pas` | the log file |

## How the theme engine works

Facts measured from real xfwm4 (Daloa and the other themes, GTK theme Adwaita-dark, 2026-11-20); every one is implemented and
checked by `themecheck.sh`.

- **Parts**: an XPM (symbolic colours filled from the palette) with the PNG alpha-blended on top from the top-left; where the
  XPM is transparent the PNG is not drawn. A part is sized by its XPM (Daloa's menu button is the top 16 rows of a 19-row PNG).
  Corner parts that have only a PNG (Nordic) have every not-fully-opaque pixel cut out.
- **Palette**: `*_hilight_N` = base shaded 1.3, `*_shadow_N` = base shaded 0.7 (GTK2 HLS shade), `*_mid_N` = their average, all
  *truncated*, not rounded. Active `color_1` is #15539E, inactive #323232, `color_2` #353535. The left, right and bottom borders
  use `color_2`. `active_text_color`, `*_text_shadow_color` and `*_border_color` exist as symbols too. A theme's own `themerc`
  value for a symbol wins over the palette's.
- **Layout**: frame extents come from the parts (left, right, bottom = part sizes, top = title tile height; Daloa is 5, 5, 19, 5).
  `themerc` beats xfconf for `button_offset` and `button_spacing`. Buttons start at the left border plus `button_offset` and
  overlap by `-button_spacing`; the right group is placed right to left but drawn left to right. Buttons are centred vertically
  in the title: y = (title height - button height + 1) / 2.
- **Title strip** (found with probe themes whose title tiles were painted in distinct colours): `title-1` tiled up to a
  `title-2` tile, `title-3` tiled under the "text zone", one `title-4` tile, then `title-5` tiled to the right corner. The
  tiles `title-2` / `title-4` are one tile wide (by their XPM) and sit against the zone. With `full_width_title` (the
  default) the zone is everything between the two button groups; otherwise it is the text plus two pixels. The corner
  width does not matter; `button_offset` shifts both groups' edges.
- **Title text**: left-aligned text starts at the end of the left button group + `title_horizontal_offset` + the width of the
  `title-2` tile (Daloa, Default, Kokodi: 4; Default-hdpi: 6; Default-xhdpi: 8); centred text is centred between the button
  groups and ignores the offset. Baseline = (title height - font height) / 2 + ascent + `title_vertical_offset_*`. A title
  that is too long is **not** shortened with an ellipsis: it is cut off one `title-4` tile before the right button group.
  Greyscale anti-aliasing with full hinting matches xfwm4 best (the user's fontconfig forces `rgba=rgb` after name parsing, so
  hinting is set on the matched pattern). `title_shadow_*=frame` is an outline in the shadow colour at the four neighbouring
  offsets. Inactive text is #919190.
- **App icon**: scaled to the smaller side of the menu button (22 px in Default, 44 in Default-xhdpi), centred with the vertical
  offset rounded up; the menu button is drawn only over the icon's rows when it is taller than the icon.

Result of `themecheck.sh` (pixels that differ by more than 3 levels, client area excluded): **0 for every installed theme, both
active and inactive windows**, and the frame extents match xfwm4 for all seven. With `THEMECHECK_TITLE="some long title"` the
same script compares title text too (both sides left-aligned): inactive windows are exact for all seven themes; active ones
differ only by anti-aliasing of the glyphs (a few dozen pixels, at most 6 levels). To make the reference frames by hand:

    Xvfb :99 -screen 0 1024x768x24 &
    DISPLAY=:99 xfwm4 --compositor=off &
    DISPLAY=:99 tools/testwin -t "Active window" &
    DISPLAY=:99 import -window root ref/daloa-full.png

## Not done

Skipped on purpose, because xfwm4 here has them off or they are not needed: edge snapping and tiling, window resistance,
session save / restore (XSMP), focus-stealing prevention, zoom. Not implemented: `_NET_WM_USER_TIME`, a per-monitor
`_NET_WORKAREA`, `_NET_WM_FULLSCREEN_MONITORS`, an icon-theme lookup for apps that set no `_NET_WM_ICON`, thumbnails in the
Alt+Tab list. Fullscreen, maximized, shaded and hidden requested in an app's initial `_NET_WM_STATE` are not applied at map
time (apps ask for those by client message after mapping).

## License

The source code is MIT licensed, see [LICENSE](LICENSE). The exception is the Daloa renders described below.

### Third-party material

The images `ref/daloa-full.png`, `ref/frame-active-310x224.png`, `ref/frame-inactive-410x324.png` and
`out/tiewm-demo.png` are renders of the **Daloa** xfwm4 theme (made by real xfwm4 and by tiewm). Daloa is GPL-licensed
("Created May 2006 by Mike Massonnet, modified by Olivier Fourdan, released under the GNU GPL", per its README), so these
images are covered by the GPL of that theme, **not** by the license of tiewm's source code. They are test fixtures and a demo
screenshot only.

No theme files are included in this repository: themes are read at runtime from `/usr/share/themes/<name>/xfwm4` or
`~/.themes/<name>/xfwm4`, and each theme keeps its own license.
