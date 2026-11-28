# Changelog

## Unreleased

- **Move hints for compositors.** While a window is being dragged tiewm tells a compositor that asks for it, by owning the
  `_TIECOMP_S<screen>` selection, when the move starts (and where the window is held) and when it ends. tiecomp uses this
  for wobbly windows. With no such compositor running, nothing changes. Keyboard moves send no hint.
- **Other workspaces can be kept mapped for a compositor.** A compositor that draws them (tiecomp's desktop cube) asks with
  `_TIECOMP_CUBE`; their frames then stay mapped but take no pointer input. If it goes away, even by crashing, they are
  unmapped again. Without such a request nothing changes.

## 0.5.1 (2026-11-22)

- **Fixed a crash on windows whose `_NET_WM_STATE` property exists but is empty** (seen with Terminator). The code that reads
  a list of atoms looped from 0 to N - 1 with an unsigned N, so an empty list became a huge loop bound and read past the buffer.
  The error happened while mapping the window, which left it unmapped and invisible. Such windows are now managed normally.
  A regression test (`tools/testwin -S empty`, scenario section 45) covers it; the 335 scenario checks pass.

## 0.5 (2026-11-21)

First tagged release: xfwm4 themes drawn exactly, several monitors, workspaces, Alt+Tab list, window menu and rules, focus
follows the mouse, `_NET_WM_MOVERESIZE`, ICCCM gravity, `_NET_WM_PING`, packages for Debian / Ubuntu, Fedora / RHEL and Arch.
