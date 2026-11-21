unit twxdraw;

{ X11 glue for the theme engine: frame pixmaps, shape masks and title text.
  Everything here needs an open display; the theme composing itself does not. }

{$mode objfpc}{$H+}

interface

uses
  ctypes, SysUtils, x, xlib, twimage, twtheme, twxft;

type
  TShadowMode = (smNone, smUnder, smFrame, smFrame4, smDiag);

  { TTitleFont }

  TTitleFont = class
  private
    FDpy: PDisplay;
    FFont: PXftFontRec;
    FName: string;
    function GetAscent: Integer;
    function GetDescent: Integer;
  public
    constructor Create(ADpy: PDisplay; AScreen: Integer; const PangoName: string);
    destructor Destroy; override;
    function Width(const S: string): Integer;
    { Draws S with its baseline at BaseY. Shadow, if any, is drawn first. }
    procedure Draw(Pm: TPixmap; AVisual: PVisual; ACmap: TColormap; X, BaseY: Integer;
      const S: string; RGB: LongWord; Mode: TShadowMode; ShadowRGB: LongWord; ClipRight: Integer = -1);
    { Shortens S with an ellipsis so it fits in MaxW pixels }
    function Fit(const S: string; MaxW: Integer): string;
    property Ascent: Integer read GetAscent;
    property Descent: Integer read GetDescent;
    property FontName: string read FName;
  end;

function DestroyImg(Im: PXImage): cint; cdecl; external 'X11' name 'XDestroyImage';

type
  TTitleAlign = (taLeft, taCenter, taRight);

var
  { set from the config file by the window manager }
  TitleFontGrey: Boolean = True;
  TitleFontHint: Integer = 3;

{ Draws the whole frame (graphics + title) into a new pixmap and builds the
  shape mask for it. FrameW/FrameH are the outer size, the client sits in
  the hole. Caller frees both pixmaps. }
function PaintFrame(Dpy: PDisplay; Scr: Integer; Theme: TXfwmTheme; Font: TTitleFont;
  St: TWinState; FrameW, FrameH: Integer; const Title: string; Align: TTitleAlign;
  out Mask: TPixmap; out TextX, BaseY: Integer): TPixmap;
{ same, with the frame rolled up to its titlebar when Shaded }
function PaintFrameEx(Dpy: PDisplay; Scr: Integer; Theme: TXfwmTheme; Font: TTitleFont;
  St: TWinState; FrameW, FrameH: Integer; const Title: string; Align: TTitleAlign; Shaded: Boolean;
  Hover, Press: Char; Icon: TImg; const Toggled: string; out Mask: TPixmap; out TextX, BaseY: Integer): TPixmap;

{ Flattens Img over black into a pixmap of the given depth. }
function ImgToPixmap(Dpy: PDisplay; Drawable: TDrawable; AVisual: PVisual; Depth: Integer;
  Img: TImg): TPixmap;
{ 1-bit shape mask: set where the image is not transparent, or inside the
  client rectangle (the client window must stay visible). }
function MaskFromImg(Dpy: PDisplay; Drawable: TDrawable; Img: TImg;
  CX, CY, CW, CH: Integer): TPixmap;
{ ImgToPixmap, but the rectangle SX,SY,SW,SH (the client area, which the client
  window covers) is not converted or uploaded, only filled black. Large windows
  cost the length of their border instead of their area. }
function ImgToPixmapSkip(Dpy: PDisplay; Drawable: TDrawable; AVisual: PVisual; Depth: Integer;
  Img: TImg; SX, SY, SW, SH: Integer): TPixmap;

implementation

{ TTitleFont }

function ParseColorSpec(Theme: TXfwmTheme; const S: string; Def: LongWord): LongWord;
var
  C: LongWord;
begin
  Result := Def;
  if (Length(S) = 7) and (S[1] = '#') then
    Result := LongWord(StrToIntDef('$' + Copy(S, 2, 6), Def))
  else if Theme.Symbol(S, C) then
    Result := C and $FFFFFF;
end;

function PaintFrameEx(Dpy: PDisplay; Scr: Integer; Theme: TXfwmTheme; Font: TTitleFont;
  St: TWinState; FrameW, FrameH: Integer; const Title: string; Align: TTitleAlign; Shaded: Boolean;
  Hover, Press: Char; Icon: TImg; const Toggled: string; out Mask: TPixmap; out TextX, BaseY: Integer): TPixmap;
var
  Img: TImg;
  O: TFrameOpts;
  M: TThemeMetrics;
  L, R, TW, Avail, VOff, W2: Integer;
  Shown, ShadowKey, ColorKey: string;
  Mode: TShadowMode;
  TextRGB, ShadowRGB, DefTextColor: LongWord;
  Root: TWindow;
  Vis: PVisual;
begin
  M := Theme.Metrics;
  Root := DefaultRootWindow(Dpy);
  Vis := DefaultVisual(Dpy, Scr);
  O := DefaultFrameOpts(Theme);
  O.Shaded := Shaded;
  O.Toggled := Toggled;
  O.Prelight := Hover;
  O.Pressed := Press;
  O.Icon := Icon;
  Theme.TitleSpan(O, FrameW, L, R);
  if St = wsActive then
  begin
    ShadowKey := 'title_shadow_active';
    ColorKey := 'active_text_color';
    VOff := Theme.RCInt('title_vertical_offset_active', 0);
  end
  else
  begin
    ShadowKey := 'title_shadow_inactive';
    ColorKey := 'inactive_text_color';
    VOff := Theme.RCInt('title_vertical_offset_inactive', 0);
  end;
  { measured from real xfwm4: left-aligned text starts at the end of the left buttons + title_horizontal_offset + the
    width of the title-2 tile; centred text sits in the middle between the button groups (the zone it is drawn in is
    two pixels wider than the text) and ignores the offset }
  W2 := Theme.Title2Width;
  Avail := R - (L + W2) - 2;
  { xfwm4 does not shorten a long title with an ellipsis: it is cut off one title-4 tile before the right button group }
  Shown := Title;
  TW := Font.Width(Shown);
  case Align of
    taCenter: TextX := (L + R) div 2 - (TW + 2) div 2;
    taRight: TextX := R - 2 - TW + Theme.RCInt('title_horizontal_offset', 0);
  else
    TextX := L + W2 + Theme.RCInt('title_horizontal_offset', 0);
  end;
  BaseY := (M.TitleH - (Font.Ascent + Font.Descent)) div 2 + Font.Ascent + VOff;
  O.TextX := TextX;
  O.TextW := TW;
  Img := TImg.CreateBorder(FrameW, FrameH, M.LeftW, M.TitleH, FrameW - M.LeftW - M.RightW,
    FrameH - M.TitleH - M.BottomH);
  try
    Theme.Compose(Img, St, O);
    Result := ImgToPixmapSkip(Dpy, Root, Vis, DefaultDepth(Dpy, Scr), Img, M.LeftW, M.TitleH,
      FrameW - M.LeftW - M.RightW, FrameH - M.TitleH - M.BottomH);
    Mask := MaskFromImg(Dpy, Root, Img, M.LeftW, M.TitleH, FrameW - M.LeftW - M.RightW,
      FrameH - M.TitleH - M.BottomH);
  finally
    Img.Free;
  end;
  { text colour: the theme's own setting (literal or a palette name such as active_text_color_2),
    else the palette's text colour for that state }
  if St = wsActive then
  begin
    if not Theme.Symbol('active_text_color', DefTextColor) then DefTextColor := $FFFFFF;
  end
  else
  begin
    if not Theme.Symbol('inactive_text_color', DefTextColor) then DefTextColor := $919190;
  end;
  TextRGB := ParseColorSpec(Theme, Theme.RC(ColorKey, ''), DefTextColor and $FFFFFF);
  if LowerCase(Theme.RC(ShadowKey, 'false')) = 'frame' then Mode := smFrame4
  else if LowerCase(Theme.RC(ShadowKey, 'false')) = 'true' then Mode := smUnder
  else Mode := smNone;
  if St = wsActive then
    ShadowRGB := ParseColorSpec(Theme, Theme.RC('active_text_shadow_color', 'active_text_shadow_color'), $000000)
  else
    ShadowRGB := ParseColorSpec(Theme, Theme.RC('inactive_text_shadow_color', 'inactive_text_shadow_color'), $000000);
  Font.Draw(Result, Vis, DefaultColormap(Dpy, Scr), TextX, BaseY, Shown, TextRGB, Mode, ShadowRGB, R - Theme.Title4Width);
end;

function TTitleFont.GetAscent: Integer;
begin
  Result := FFont^.Ascent;
end;

function TTitleFont.GetDescent: Integer;
begin
  Result := FFont^.Descent;
end;

constructor TTitleFont.Create(ADpy: PDisplay; AScreen: Integer; const PangoName: string);
begin
  inherited Create;
  FDpy := ADpy;
  FName := PangoToFontconfig(PangoName);
  { greyscale AA + full hinting: what xfwm4's titles matched best here (2026-11-20) }
  FFont := OpenXftFont(ADpy, AScreen, FName, TitleFontGrey, TitleFontHint);
  if FFont = nil then
    raise Exception.Create('cannot open font ' + FName);
end;

destructor TTitleFont.Destroy;
begin
  if FFont <> nil then XftFontClose(FDpy, FFont);
  inherited Destroy;
end;

function TTitleFont.Width(const S: string): Integer;
var
  E: TGlyphInfo;
begin
  if S = '' then Exit(0);
  XftTextExtentsUtf8(FDpy, FFont, PChar(S), Length(S), @E);
  Result := E.XOff;
end;

function TTitleFont.Fit(const S: string; MaxW: Integer): string;
var
  T: string;
  N: Integer;
begin
  Result := S;
  if Width(Result) <= MaxW then Exit;
  N := Length(S);
  while N > 0 do
  begin
    { drop whole UTF-8 characters }
    Dec(N);
    while (N > 0) and ((Ord(S[N + 1]) and $C0) = $80) do Dec(N);
    T := Copy(S, 1, N) + #$E2#$80#$A6;
    if Width(T) <= MaxW then Exit(T);
  end;
  Result := '';
end;

procedure TTitleFont.Draw(Pm: TPixmap; AVisual: PVisual; ACmap: TColormap; X, BaseY: Integer;
  const S: string; RGB: LongWord; Mode: TShadowMode; ShadowRGB: LongWord; ClipRight: Integer);
var
  D: Pointer;
  C, SC: TXftColor;
  DX, DY: Integer;
  Clip: TXRectangle;
begin
  if S = '' then Exit;
  D := XftDrawCreate(FDpy, Pm, AVisual, ACmap);
  try
    if ClipRight >= 0 then
    begin
      { cut the text off at ClipRight (exclusive) instead of drawing past it }
      Clip.x := 0; Clip.y := 0; Clip.width := ClipRight; Clip.height := 4096;
      XftDrawSetClipRectangles(D, 0, 0, @Clip, 1);
    end;
    C := MakeXftColor(RGB);
    SC := MakeXftColor(ShadowRGB);
    case Mode of
      smUnder:
        XftDrawStringUtf8(D, @SC, FFont, X + 1, BaseY + 1, PChar(S), Length(S));
      smFrame:
        for DY := -1 to 1 do
          for DX := -1 to 1 do
            if (DX <> 0) or (DY <> 0) then
              XftDrawStringUtf8(D, @SC, FFont, X + DX, BaseY + DY, PChar(S), Length(S));
      smFrame4:
        for DY := -1 to 1 do
          for DX := -1 to 1 do
            if (Abs(DX) + Abs(DY)) = 1 then
              XftDrawStringUtf8(D, @SC, FFont, X + DX, BaseY + DY, PChar(S), Length(S));
      smDiag:
        for DY := -1 to 1 do
          for DX := -1 to 1 do
            if (Abs(DX) + Abs(DY)) = 2 then
              XftDrawStringUtf8(D, @SC, FFont, X + DX, BaseY + DY, PChar(S), Length(S));
    end;
    XftDrawStringUtf8(D, @C, FFont, X, BaseY, PChar(S), Length(S));
  finally
    XftDrawDestroy(D);
  end;
end;

function PaintFrame(Dpy: PDisplay; Scr: Integer; Theme: TXfwmTheme; Font: TTitleFont;
  St: TWinState; FrameW, FrameH: Integer; const Title: string; Align: TTitleAlign;
  out Mask: TPixmap; out TextX, BaseY: Integer): TPixmap;
begin
  Result := PaintFrameEx(Dpy, Scr, Theme, Font, St, FrameW, FrameH, Title, Align, False, #0, #0, nil, '', Mask, TextX, BaseY);
end;

function ImgToPixmap(Dpy: PDisplay; Drawable: TDrawable; AVisual: PVisual; Depth: Integer;
  Img: TImg): TPixmap;
begin
  Result := ImgToPixmapSkip(Dpy, Drawable, AVisual, Depth, Img, 0, 0, 0, 0);
end;

function ImgToPixmapSkip(Dpy: PDisplay; Drawable: TDrawable; AVisual: PVisual; Depth: Integer;
  Img: TImg; SX, SY, SW, SH: Integer): TPixmap;
var
  Buf: array of LongWord;
  Src: PLongWord;
  GC: TGC;

  { converts and uploads the rectangle RX,RY,RW,RH of Img (premultiplied over black) }
  procedure PutRect(RX, RY, RW, RH: Integer);
  var
    X, Y, N: Integer;
    P, A, R, G, B: LongWord;
    Im: PXImage;
    Row: PLongWord;
  begin
    if (RW <= 0) or (RH <= 0) then Exit;
    if Length(Buf) < RW * RH then SetLength(Buf, RW * RH);
    N := 0;
    for Y := RY to RY + RH - 1 do
    begin
      Row := Src + Y * Img.W;
      for X := RX to RX + RW - 1 do
      begin
        P := Row[X];
        A := P shr 24;
        if A = 255 then Buf[N] := P and $FFFFFF
        else if A = 0 then Buf[N] := 0
        else
        begin
          R := (((P shr 16) and 255) * A + 127) div 255;
          G := (((P shr 8) and 255) * A + 127) div 255;
          B := ((P and 255) * A + 127) div 255;
          Buf[N] := (R shl 16) or (G shl 8) or B;
        end;
        Inc(N);
      end;
    end;
    Im := XCreateImage(Dpy, AVisual, Depth, ZPixmap, 0, PChar(@Buf[0]), RW, RH, 32, 0);
    XPutImage(Dpy, Result, GC, Im, 0, 0, RX, RY, RW, RH);
    Im^.data := nil;   { the buffer is ours, not malloc'd }
    DestroyImg(Im);
  end;

var
  Y0, Y1: Integer;
begin
  if (AVisual^.red_mask <> $FF0000) or (AVisual^.green_mask <> $FF00) or (AVisual^.blue_mask <> $FF) then
    raise Exception.Create('unsupported visual pixel layout');
  Src := Img.Raw;
  Result := XCreatePixmap(Dpy, Drawable, Img.W, Img.H, Depth);
  GC := XCreateGC(Dpy, Result, 0, nil);
  if (SW <= 0) or (SH <= 0) then
    PutRect(0, 0, Img.W, Img.H)
  else
  begin
    Y0 := SY; if Y0 < 0 then Y0 := 0;
    Y1 := SY + SH; if Y1 > Img.H then Y1 := Img.H;
    XSetForeground(Dpy, GC, 0);
    XFillRectangle(Dpy, Result, GC, SX, SY, SW, SH);
    PutRect(0, 0, Img.W, Y0);                       { top: corners and titlebar }
    PutRect(0, Y0, SX, Y1 - Y0);                    { left border }
    PutRect(SX + SW, Y0, Img.W - SX - SW, Y1 - Y0); { right border }
    PutRect(0, Y1, Img.W, Img.H - Y1);              { bottom }
  end;
  XFreeGC(Dpy, GC);
end;

function MaskFromImg(Dpy: PDisplay; Drawable: TDrawable; Img: TImg;
  CX, CY, CW, CH: Integer): TPixmap;
var
  Stride, X, Y, X1: Integer;
  Bits: array of Byte;
  Px: PLongWord;
  Row: PLongWord;
  InRow: Boolean;
begin
  Stride := (Img.W + 7) div 8;
  SetLength(Bits, Stride * Img.H);
  FillChar(Bits[0], Length(Bits), 0);
  Px := Img.Raw;
  for Y := 0 to Img.H - 1 do
  begin
    Row := Px + Y * Img.W;
    InRow := (Y >= CY) and (Y < CY + CH) and (CW > 0);
    if InRow then
    begin
      { the client area is always on: set its bits a byte at a time, scan only the borders }
      X := CX; if X < 0 then X := 0;
      X1 := CX + CW; if X1 > Img.W then X1 := Img.W;
      while (X < X1) and ((X and 7) <> 0) do
      begin
        Bits[Y * Stride + X div 8] := Bits[Y * Stride + X div 8] or (1 shl (X mod 8));
        Inc(X);
      end;
      if X1 - X >= 8 then
      begin
        FillChar(Bits[Y * Stride + X div 8], (X1 - X) div 8, $FF);
        Inc(X, ((X1 - X) div 8) * 8);
      end;
      while X < X1 do
      begin
        Bits[Y * Stride + X div 8] := Bits[Y * Stride + X div 8] or (1 shl (X mod 8));
        Inc(X);
      end;
      for X := 0 to CX - 1 do
        if (Row[X] shr 24) <> 0 then Bits[Y * Stride + X div 8] := Bits[Y * Stride + X div 8] or (1 shl (X mod 8));
      for X := CX + CW to Img.W - 1 do
        if (Row[X] shr 24) <> 0 then Bits[Y * Stride + X div 8] := Bits[Y * Stride + X div 8] or (1 shl (X mod 8));
    end
    else
      for X := 0 to Img.W - 1 do
        if (Row[X] shr 24) <> 0 then Bits[Y * Stride + X div 8] := Bits[Y * Stride + X div 8] or (1 shl (X mod 8));
  end;
  Result := XCreateBitmapFromData(Dpy, Drawable, PChar(@Bits[0]), Img.W, Img.H);
end;

end.
