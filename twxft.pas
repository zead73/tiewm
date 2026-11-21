unit twxft;

{ Own small binding to Xft, declared with the C struct layouts. The Xft unit
  shipped with FPC lacks XftColorAllocValue and its records are awkward, so
  this unit declares only what title drawing needs. Also the Pango ->
  fontconfig font-name translation used for xfwm4's title_font setting. }

{$mode objfpc}{$H+}

interface

uses
  ctypes, SysUtils, Classes, x, xlib;

type
  TXRenderColor = record
    Red, Green, Blue, Alpha: cushort;
  end;
  PXftColor = ^TXftColor;
  TXftColor = record
    Pixel: culong;
    Color: TXRenderColor;
  end;
  TGlyphInfo = record
    Width, Height: cushort;
    X, Y: cshort;
    XOff, YOff: cshort;
  end;
  PGlyphInfo = ^TGlyphInfo;
  PXftFontRec = ^TXftFontRec;
  TXftFontRec = record
    Ascent, Descent, Height, MaxAdvanceWidth: cint;
    { remaining fields are not needed }
  end;

function XftFontOpenName(dpy: PDisplay; Screen: cint; Name: PChar): PXftFontRec; cdecl;
  external 'Xft' name 'XftFontOpenName';
procedure XftFontClose(dpy: PDisplay; Font: PXftFontRec); cdecl;
  external 'Xft' name 'XftFontClose';
function XftDrawCreate(dpy: PDisplay; Drawable: TDrawable; Visual: PVisual;
  Colormap: TColormap): Pointer; cdecl; external 'Xft' name 'XftDrawCreate';
procedure XftDrawDestroy(Draw: Pointer); cdecl; external 'Xft' name 'XftDrawDestroy';
procedure XftDrawStringUtf8(Draw: Pointer; Color: PXftColor; Font: PXftFontRec;
  X, Y: cint; Str: PChar; Len: cint); cdecl; external 'Xft' name 'XftDrawStringUtf8';
function XftDrawSetClipRectangles(Draw: Pointer; XOrigin, YOrigin: cint; Rects: PXRectangle; N: cint): cint; cdecl;
  external 'Xft' name 'XftDrawSetClipRectangles';
procedure XftTextExtentsUtf8(dpy: PDisplay; Font: PXftFontRec; Str: PChar; Len: cint;
  Extents: PGlyphInfo); cdecl; external 'Xft' name 'XftTextExtentsUtf8';

function FcNameParse(Name: PChar): Pointer; cdecl; external 'fontconfig' name 'FcNameParse';
function FcConfigSubstitute(Config: Pointer; Pat: Pointer; Kind: cint): cint; cdecl;
  external 'fontconfig' name 'FcConfigSubstitute';
function FcPatternDel(Pat: Pointer; Obj: PChar): cint; cdecl; external 'fontconfig' name 'FcPatternDel';
function FcPatternAddInteger(Pat: Pointer; Obj: PChar; I: cint): cint; cdecl;
  external 'fontconfig' name 'FcPatternAddInteger';
procedure FcPatternDestroy(Pat: Pointer); cdecl; external 'fontconfig' name 'FcPatternDestroy';
procedure XftDefaultSubstitute(dpy: PDisplay; Screen: cint; Pat: Pointer); cdecl;
  external 'Xft' name 'XftDefaultSubstitute';
function XftFontMatch(dpy: PDisplay; Screen: cint; Pat: Pointer; Res: pcint): Pointer; cdecl;
  external 'Xft' name 'XftFontMatch';
function XftFontOpenPattern(dpy: PDisplay; Pat: Pointer): PXftFontRec; cdecl;
  external 'Xft' name 'XftFontOpenPattern';

{ Opens a font by fontconfig name. Grey forces greyscale antialiasing even when
  the user's fontconfig asks for subpixel rendering; HintStyle 0..3 (none, slight,
  medium, full) overrides the configured hinting, -1 leaves it alone. }
function OpenXftFont(dpy: PDisplay; Screen: Integer; const FcName: string; Grey: Boolean; HintStyle: Integer): PXftFontRec;

{ "Sans Bold 11" -> "Sans:bold:size=11" }
function PangoToFontconfig(const Pango: string): string;
function MakeXftColor(RGB: LongWord): TXftColor;

implementation

function OpenXftFont(dpy: PDisplay; Screen: Integer; const FcName: string; Grey: Boolean; HintStyle: Integer): PXftFontRec;
const
  FcRgbaNone = 5;
var
  Pat, Match: Pointer;
  Res: cint;
begin
  Result := nil;
  Pat := FcNameParse(PChar(FcName));
  if Pat = nil then Exit;
  FcConfigSubstitute(nil, Pat, 0);
  XftDefaultSubstitute(dpy, Screen, Pat);
  Res := 0;
  Match := XftFontMatch(dpy, Screen, Pat, @Res);
  FcPatternDestroy(Pat);
  if Match = nil then Exit;
  if Grey then
  begin
    FcPatternDel(Match, 'rgba');
    FcPatternAddInteger(Match, 'rgba', FcRgbaNone);
  end;
  if HintStyle >= 0 then
  begin
    FcPatternDel(Match, 'hintstyle');
    FcPatternAddInteger(Match, 'hintstyle', HintStyle);
  end;
  Result := XftFontOpenPattern(dpy, Match);   { takes ownership of Match }
end;

function MakeXftColor(RGB: LongWord): TXftColor;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Pixel := RGB and $FFFFFF;
  Result.Color.Red := ((RGB shr 16) and 255) * 257;
  Result.Color.Green := ((RGB shr 8) and 255) * 257;
  Result.Color.Blue := (RGB and 255) * 257;
  Result.Color.Alpha := $FFFF;
end;

function PangoToFontconfig(const Pango: string): string;
var
  Toks: TStringList;
  I: Integer;
  Fam, T, L, Size, Props: string;
  Sz: Double;
begin
  Toks := TStringList.Create;
  try
    Toks.Delimiter := ' ';
    Toks.StrictDelimiter := True;
    Toks.DelimitedText := Trim(Pango);
    Size := '';
    { trailing number is the size in points }
    if (Toks.Count > 0) and TryStrToFloat(Toks[Toks.Count - 1], Sz, DefaultFormatSettings) then
    begin
      Size := Toks[Toks.Count - 1];
      Toks.Delete(Toks.Count - 1);
    end;
    Fam := '';
    Props := '';
    for I := 0 to Toks.Count - 1 do
    begin
      T := Toks[I];
      L := LowerCase(T);
      if T = '' then Continue;
      if (L = 'bold') or (L = 'ultra-bold') or (L = 'heavy') then Props := Props + ':bold'
      else if (L = 'semi-bold') or (L = 'semibold') then Props := Props + ':demibold'
      else if (L = 'light') or (L = 'ultra-light') then Props := Props + ':light'
      else if L = 'italic' then Props := Props + ':italic'
      else if L = 'oblique' then Props := Props + ':oblique'
      else if (L = 'normal') or (L = 'regular') or (L = 'medium') then { default }
      else
      begin
        if Fam <> '' then Fam := Fam + ' ';
        Fam := Fam + T;
      end;
    end;
    if Fam = '' then Fam := 'Sans';
    Result := Fam + Props;
    if Size <> '' then Result := Result + ':size=' + Size;
  finally
    Toks.Free;
  end;
end;

end.
