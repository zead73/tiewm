program shapewin;

{ Puts one shaped, themed frame window on screen for a few seconds so the
  shape can be checked with a screenshot. Root is painted red so cut-away
  pixels are easy to see. Usage: shapewin <theme> [seconds] }

{$mode objfpc}{$H+}

uses
  SysUtils, BaseUnix, ctypes, x, xlib, twimage, twtheme, twxdraw, twxshape;

var
  Dpy: PDisplay;
  Scr: Integer;
  Root, Win: TWindow;
  Theme: TXfwmTheme;
  Font: TTitleFont;
  Pm, Mask: TPixmap;
  Attr: TXSetWindowAttributes;
  Tx, By, Secs: Integer;
  Red: culong;
  T0: Int64;
begin
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then Halt(1);
  Scr := DefaultScreen(Dpy);
  Root := DefaultRootWindow(Dpy);
  if not HaveShape(Dpy) then begin WriteLn('no SHAPE extension'); Halt(1); end;
  Theme := TXfwmTheme.Create;
  if not Theme.Load(ParamStr(1), DefaultPalette) then Halt(1);
  if ParamCount >= 2 then Secs := StrToInt(ParamStr(2)) else Secs := 4;
  Font := TTitleFont.Create(Dpy, Scr, 'Sans Bold 11');
  Red := $FF0000;
  XSetWindowBackground(Dpy, Root, Red);
  XClearWindow(Dpy, Root);
  Pm := PaintFrame(Dpy, Scr, Theme, Font, wsActive, 310, 224, 'Shape test', taLeft, Mask, Tx, By);
  Win := XCreateSimpleWindow(Dpy, Root, 100, 100, 310, 224, 0, 0, 0);
  Attr.override_redirect := 1;
  XChangeWindowAttributes(Dpy, Win, CWOverrideRedirect, @Attr);
  XSetWindowBackgroundPixmap(Dpy, Win, Pm);
  XShapeCombineMask(Dpy, Win, ShapeBounding, 0, 0, Mask, ShapeSet);
  XMapWindow(Dpy, Win);
  XSync(Dpy, 0);
  T0 := FpTime;
  while FpTime - T0 < Secs do Sleep(100);
  XCloseDisplay(Dpy);
end.
