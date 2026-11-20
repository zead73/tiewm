program paintbench;

{ Times PaintFrame for a few frame sizes. Usage: paintbench [theme] }

{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, ctypes, x, xlib, twtheme, twxdraw;

const
  Sizes: array[0..3, 0..1] of Integer = ((400, 300), (1280, 800), (1920, 1080), (2560, 1440));
var
  Dpy: PDisplay;
  Scr, I, K: Integer;
  Theme: TXfwmTheme;
  Font: TTitleFont;
  Pm, Mask: TPixmap;
  Tx, By: Integer;
  T0: TDateTime;
  TN: string;
begin
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then Halt(1);
  Scr := DefaultScreen(Dpy);
  if ParamCount >= 1 then TN := ParamStr(1) else TN := 'Daloa';
  Theme := TXfwmTheme.Create;
  if not Theme.Load(TN, DefaultPalette) then Halt(1);
  Font := TTitleFont.Create(Dpy, Scr, 'Sans Bold 11');
  for I := 0 to High(Sizes) do
  begin
    { first call loads parts; time the later ones }
    Pm := PaintFrame(Dpy, Scr, Theme, Font, wsActive, Sizes[I, 0], Sizes[I, 1], 'bench', taLeft, Mask, Tx, By);
    XFreePixmap(Dpy, Pm); XFreePixmap(Dpy, Mask);
    T0 := Now;
    for K := 1 to 5 do
    begin
      Pm := PaintFrame(Dpy, Scr, Theme, Font, wsActive, Sizes[I, 0], Sizes[I, 1], 'bench', taLeft, Mask, Tx, By);
      XFreePixmap(Dpy, Pm); XFreePixmap(Dpy, Mask);
    end;
    XSync(Dpy, 0);
    WriteLn(Format('%4dx%-4d  %6.1f ms per paint', [Sizes[I, 0], Sizes[I, 1], MilliSecondSpan(Now, T0) / 5]));
  end;
  XCloseDisplay(Dpy);
end.
