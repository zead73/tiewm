program framecheck;

{ Paints a themed frame with title text and shape mask via the same code the
  WM will use, and diffs it against a screenshot of real xfwm4 (client area
  ignored). Needs a display, e.g. Xvfb.
  Usage: framecheck <theme> <ref.png> <active|inactive> "<title>" "<font>" }

{$mode objfpc}{$H+}

uses
  SysUtils, ctypes, x, xlib, twimage, twtheme, twxft, twxdraw, twxshape;

var
  Dpy: PDisplay;
  Scr: Integer;
  Theme: TXfwmTheme;
  Ref, Out_: TImg;
  St: TWinState;
  StName: string;
  Font: TTitleFont;
  Pm, Mask: TPixmap;
  Im: PXImage;
  M: TThemeMetrics;
  TextX, BaseY, Xp, Yp, NTitle, NOther, TitleTot, OtherTot, Holes, BadShape, Stride: Integer;
  P: PLongWord;
  Bit: Boolean;

function Chan(C: LongWord; Sh: Integer): Integer;
begin
  Result := (C shr Sh) and 255;
end;

function PxDiff(A, B: LongWord): Integer;
var
  D, Mx: Integer;
begin
  Mx := Abs(Chan(A, 16) - Chan(B, 16));
  D := Abs(Chan(A, 8) - Chan(B, 8)); if D > Mx then Mx := D;
  D := Abs(Chan(A, 0) - Chan(B, 0)); if D > Mx then Mx := D;
  Result := Mx;
end;

begin
  if ParamCount < 5 then
  begin
    WriteLn('usage: framecheck <theme> <ref.png> <active|inactive> "<title>" "<font>"');
    Halt(2);
  end;
  StName := ParamStr(3);
  if StName = 'active' then St := wsActive else St := wsInactive;
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then begin WriteLn('no display'); Halt(1); end;
  Scr := DefaultScreen(Dpy);
  Ref := LoadPNGImg(ParamStr(2));
  if Ref = nil then begin WriteLn('cannot load ref'); Halt(1); end;
  Theme := TXfwmTheme.Create;
  if not Theme.Load(ParamStr(1), DefaultPalette) then begin WriteLn('theme not found'); Halt(1); end;
  M := Theme.Metrics;
  Font := TTitleFont.Create(Dpy, Scr, ParamStr(5));
  Pm := PaintFrame(Dpy, Scr, Theme, Font, St, Ref.W, Ref.H, ParamStr(4), taLeft, Mask, TextX, BaseY);
  WriteLn(Format('layout: text x=%d baseline=%d (font %s)', [TextX, BaseY, Font.FontName]));
  Im := XGetImage(Dpy, Pm, 0, 0, Ref.W, Ref.H, $FFFFFFFF, ZPixmap);
  Out_ := TImg.Create(Ref.W, Ref.H);
  for Yp := 0 to Ref.H - 1 do
  begin
    P := PLongWord(PByte(Im^.data) + Yp * Im^.bytes_per_line);
    for Xp := 0 to Ref.W - 1 do Out_.SetPx(Xp, Yp, $FF000000 or P[Xp]);
  end;
  DestroyImg(Im);
  NTitle := 0; NOther := 0; TitleTot := 0; OtherTot := 0;
  for Yp := 0 to Ref.H - 1 do
    for Xp := 0 to Ref.W - 1 do
    begin
      if (Xp >= M.LeftW) and (Xp < Ref.W - M.RightW) and (Yp >= M.TitleH) and (Yp < Ref.H - M.BottomH) then Continue;
      if (Xp >= 7) and (Xp < 29) and (Yp < M.TitleH) then Continue;   { app icon in the menu button }
      if Yp < M.TitleH then
      begin
        Inc(TitleTot);
        if PxDiff(Out_.Get(Xp, Yp), Ref.Get(Xp, Yp)) > 3 then Inc(NTitle);
      end
      else
      begin
        Inc(OtherTot);
        if PxDiff(Out_.Get(Xp, Yp), Ref.Get(Xp, Yp)) > 3 then Inc(NOther);
      end;
    end;
  WriteLn(Format('title row (incl. text): %d of %d pixels differ', [NTitle, TitleTot]));
  WriteLn(Format('borders + bottom:       %d of %d pixels differ', [NOther, OtherTot]));
  Im := XGetImage(Dpy, Mask, 0, 0, Ref.W, Ref.H, 1, XYPixmap);
  Holes := 0; BadShape := 0;
  Stride := Im^.bytes_per_line;
  for Yp := 0 to Ref.H - 1 do
    for Xp := 0 to Ref.W - 1 do
    begin
      Bit := (PByte(Im^.data)[Yp * Stride + Xp div 8] shr (Xp mod 8)) and 1 = 1;
      if not Bit then
      begin
        Inc(Holes);
        if (Ref.Get(Xp, Yp) and $FFFFFF) <> 0 then Inc(BadShape);
      end;
    end;
  WriteLn(Format('shape: %d pixels cut, %d not background in reference', [Holes, BadShape]));
  ForceDirectories('../out');
  Out_.SavePNG('../out/frame-' + StName + '.png');
  XCloseDisplay(Dpy);
end.
