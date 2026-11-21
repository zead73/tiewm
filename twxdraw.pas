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
      const S: string; RGB: LongWord; Mode: TShadowMode; ShadowRGB: LongWord);
    { Shortens S with an ellipsis so it fits in MaxW pixels }
    function Fit(const S: string; MaxW: Integer): string;
    property Ascent: Integer read GetAscent;
    property Descent: Integer read GetDescent;
    property FontName: string read FName;
  end;

function DestroyImg(Im: PXImage): cint; cdecl; external 'X11' name 'XDestroyImage';

type
  TTitleAlign = (taLeft, taCenter, taRight);

const
  { measured from xfwm4: gap between the last left button and the text }
  TitleTextGap = 5;
  { inactive_text_color is not in Daloa's themerc; this is what xfwm4 showed }
  DefaultInactiveText = $919190;

var
  { set from the config file by the window manager }
  TitleFontGrey: Boolean = True;
  TitleFontHint: Integer = 3;
  InactiveTextColor: LongWord = DefaultInactiveText;

{ Draws the whole frame (graphics + title) into a new pixmap and builds the
  shape mask for it. FrameW/FrameH are the outer size, the client sits in
  the hole. Caller frees both pixmaps. }
function PaintFrame(Dpy: PDisplay; Scr: Integer; Theme: TXfwmTheme; Font: TTitleFont;
  St: TWinState; FrameW, FrameH: Integer; const Title: string; Align: TTitleAlign;
  out Mask: TPixmap; out TextX, BaseY: Integer): TPixmap;
{ same, with the frame rolled up to its titlebar when Shaded }
function PaintFrameEx(Dpy: PDisplay; Scr: Integer; Theme: TXfwmTheme; Font: TTitleFont;
  St: TWinState; FrameW, FrameH: Integer; const Title: string; Align: TTitleAlign; Shaded: Boolean;
  Hover, Press: Char; Icon: TImg; out Mask: TPixmap; out TextX, BaseY: Integer): TPixmap;

{ Flattens Img over black into a pixmap of the given depth. }
function ImgToPixmap(Dpy: PDisplay; Drawable: TDrawable; AVisual: PVisual; Depth: Integer;
  Img: TImg): TPixmap;
{ 1-bit shape mask: set where the image is not transparent, or inside the
  client rectangle (the client window must stay visible). }
function MaskFromImg(Dpy: PDisplay; Drawable: TDrawable; Img: TImg;
  CX, CY, CW, CH: Integer): TPixmap;

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
  Hover, Press: Char; Icon: TImg; out Mask: TPixmap; out TextX, BaseY: Integer): TPixmap;
var
  Img: TImg;
  O: TFrameOpts;
  M: TThemeMetrics;
  L, R, TW, Avail, VOff: Integer;
  Shown, ShadowKey, ColorKey: string;
  Mode: TShadowMode;
  TextRGB, ShadowRGB: LongWord;
  Root: TWindow;
  Vis: PVisual;
begin
  M := Theme.Metrics;
  Root := DefaultRootWindow(Dpy);
  Vis := DefaultVisual(Dpy, Scr);
  O := DefaultFrameOpts(Theme);
  O.Shaded := Shaded;
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
  Avail := R - (L + TitleTextGap) - 2;
  Shown := Font.Fit(Title, Avail);
  TW := Font.Width(Shown);
  case Align of
    taCenter: TextX := L + TitleTextGap + (Avail - TW) div 2;
    taRight: TextX := R - 2 - TW;
  else
    TextX := L + TitleTextGap;
  end;
  Inc(TextX, Theme.RCInt('title_horizontal_offset', 0));
  BaseY := (M.TitleH - (Font.Ascent + Font.Descent)) div 2 + Font.Ascent + VOff;
  O.TextX := TextX;
  O.TextW := TW;
  Img := TImg.Create(FrameW, FrameH);
  try
    Theme.Compose(Img, St, O);
    Result := ImgToPixmap(Dpy, Root, Vis, DefaultDepth(Dpy, Scr), Img);
    Mask := MaskFromImg(Dpy, Root, Img, M.LeftW, M.TitleH, FrameW - M.LeftW - M.RightW,
      FrameH - M.TitleH - M.BottomH);
  finally
    Img.Free;
  end;
  if St = wsActive then
    TextRGB := ParseColorSpec(Theme, Theme.RC(ColorKey, ''), $FFFFFF)
  else
    TextRGB := ParseColorSpec(Theme, Theme.RC(ColorKey, ''), InactiveTextColor);
  if LowerCase(Theme.RC(ShadowKey, 'false')) = 'frame' then Mode := smFrame4
  else if LowerCase(Theme.RC(ShadowKey, 'false')) = 'true' then Mode := smUnder
  else Mode := smNone;
  if St = wsActive then
    ShadowRGB := ParseColorSpec(Theme, 'active_shadow_1', $000000)
  else
    ShadowRGB := ParseColorSpec(Theme, 'inactive_shadow_1', $000000);
  Font.Draw(Result, Vis, DefaultColormap(Dpy, Scr), TextX, BaseY, Shown, TextRGB, Mode, ShadowRGB);
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
  const S: string; RGB: LongWord; Mode: TShadowMode; ShadowRGB: LongWord);
var
  D: Pointer;
  C, SC: TXftColor;
  DX, DY: Integer;
begin
  if S = '' then Exit;
  D := XftDrawCreate(FDpy, Pm, AVisual, ACmap);
  try
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
  Result := PaintFrameEx(Dpy, Scr, Theme, Font, St, FrameW, FrameH, Title, Align, False, #0, #0, nil, Mask, TextX, BaseY);
end;

function ImgToPixmap(Dpy: PDisplay; Drawable: TDrawable; AVisual: PVisual; Depth: Integer;
  Img: TImg): TPixmap;
var
  Buf: array of LongWord;
  I: Integer;
  Src: PLongWord;
  P: LongWord;
  A, R, G, B: LongWord;
  Im: PXImage;
  GC: TGC;
begin
  if (AVisual^.red_mask <> $FF0000) or (AVisual^.green_mask <> $FF00) or (AVisual^.blue_mask <> $FF) then
    raise Exception.Create('unsupported visual pixel layout');
  SetLength(Buf, Img.W * Img.H);
  Src := Img.Raw;
  for I := 0 to Img.W * Img.H - 1 do
  begin
    P := Src[I];
    A := P shr 24;
    if A = 255 then Buf[I] := P and $FFFFFF
    else if A = 0 then Buf[I] := 0
    else
    begin
      R := (((P shr 16) and 255) * A + 127) div 255;
      G := (((P shr 8) and 255) * A + 127) div 255;
      B := ((P and 255) * A + 127) div 255;
      Buf[I] := (R shl 16) or (G shl 8) or B;
    end;
  end;
  Result := XCreatePixmap(Dpy, Drawable, Img.W, Img.H, Depth);
  GC := XCreateGC(Dpy, Result, 0, nil);
  Im := XCreateImage(Dpy, AVisual, Depth, ZPixmap, 0, PChar(@Buf[0]), Img.W, Img.H, 32, 0);
  XPutImage(Dpy, Result, GC, Im, 0, 0, 0, 0, Img.W, Img.H);
  Im^.data := nil;   { the buffer is ours, not malloc'd }
  DestroyImg(Im);
  XFreeGC(Dpy, GC);
end;

function MaskFromImg(Dpy: PDisplay; Drawable: TDrawable; Img: TImg;
  CX, CY, CW, CH: Integer): TPixmap;
var
  Stride, X, Y: Integer;
  Bits: array of Byte;
  On: Boolean;
begin
  Stride := (Img.W + 7) div 8;
  SetLength(Bits, Stride * Img.H);
  FillChar(Bits[0], Length(Bits), 0);
  for Y := 0 to Img.H - 1 do
    for X := 0 to Img.W - 1 do
    begin
      On := ((Img.Get(X, Y) shr 24) <> 0) or
            ((X >= CX) and (X < CX + CW) and (Y >= CY) and (Y < CY + CH));
      if On then Bits[Y * Stride + X div 8] := Bits[Y * Stride + X div 8] or (1 shl (X mod 8));
    end;
  Result := XCreateBitmapFromData(Dpy, Drawable, PChar(@Bits[0]), Img.W, Img.H);
end;

end.
