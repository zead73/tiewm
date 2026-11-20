unit twtheme;

{ xfwm4 theme loader and frame composer. Reads /usr/share/themes/<Name>/xfwm4
  (themerc + XPM/PNG parts) and draws a frame into a TImg. No X dependency.

  How a part is built (checked against a live xfwm4 render of Daloa): the XPM,
  if present, is drawn first with its symbolic colours (active_color_1 ...)
  filled in from the palette; the PNG, if present, is then alpha-blended over
  it. The PNG decides the size. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, twimage;

type
  TWinState = (wsActive, wsInactive);

  { Base colours the GTK theme would supply; the rest is derived GTK2-style. }
  TThemePalette = record
    Color1: array[TWinState] of LongWord;
    Color2: array[TWinState] of LongWord;
  end;

  TThemeMetrics = record
    TitleH, LeftW, RightW, BottomH: Integer;
    TLW, TRW, BLW, BLH, BRW, BRH: Integer;
  end;

  TButtonRect = record
    Letter: Char;
    X, Y, W, H: Integer;
  end;
  TButtonRects = array of TButtonRect;

  THitKind = (hkNone, hkTitle, hkButton, hkN, hkS, hkE, hkW, hkNW, hkNE, hkSW, hkSE);
  THit = record
    Kind: THitKind;
    Letter: Char;   { for hkButton }
  end;

  TFrameOpts = record
    Layout: string;          { e.g. 'O|SHMC'; O menu T stick S shade H hide M max C close }
    ButtonOffset: Integer;   { gap between frame edge and the first button }
    ButtonSpacing: Integer;  { gap between buttons }
    ButtonY: Integer;        { y of the buttons inside the title row }
    LeftStart: Integer;      { x where left buttons begin, before ButtonOffset }
    RightEnd: Integer;       { distance from right edge where right buttons end }
    TextX, TextW: Integer;   { title text rectangle (x within frame); TextW 0 = none }
    Pressed, Prelight: Char; { button letter drawn in that state, or #0 }
    Toggled: string;         { button letters drawn in their toggled form }
    Shaded: Boolean;         { title row only: no sides/bottom drawn, no resize edges }
  end;

  { TXfwmTheme }

  TXfwmTheme = class
  private
    FDir: string;
    FName: string;
    FRC: TStringList;
    FPal: TThemePalette;
    FParts: TStringList;      { name -> TImg (nil = known missing) }
    FMetrics: TThemeMetrics;
    function PalLookup(const Name: string; out C: LongWord): Boolean;
    function LoadPart(const PartName: string): TImg;
    function Part(const PartName: string): TImg;
    function StatePart(const Base: string; St: TWinState): TImg;
    function ButtonImg(Letter: Char; St: TWinState; const O: TFrameOpts): TImg;
  public
    constructor Create;
    destructor Destroy; override;
    function Load(const ThemeName: string; const Pal: TThemePalette): Boolean;
    { palette symbol such as active_shadow_1 -> colour }
    function Symbol(const Name: string; out C: LongWord): Boolean;
    { x range left over for the title between the button groups }
    procedure TitleSpan(const O: TFrameOpts; W: Integer; out LeftEnd, RightStart: Integer);
    { where each button of the layout sits in a frame W wide }
    function ButtonRects(const O: TFrameOpts; W: Integer; St: TWinState): TButtonRects;
    { what is under frame-relative point X,Y of a frame W x H (client hole = hkNone) }
    function HitTest(const O: TFrameOpts; W, H, X, Y: Integer): THit;
    function RC(const Key, Def: string): string;
    function RCInt(const Key: string; Def: Integer): Integer;
    function RCBool(const Key: string; Def: Boolean): Boolean;
    procedure Compose(Dst: TImg; St: TWinState; const O: TFrameOpts);
    property Metrics: TThemeMetrics read FMetrics;
    property Name: string read FName;
    property Dir: string read FDir;
  end;

function ShadeColor(C: LongWord; K: Double): LongWord;
function MidColor(A, B: LongWord): LongWord;
function DefaultPalette: TThemePalette;
function DefaultFrameOpts(Theme: TXfwmTheme): TFrameOpts;

implementation

const
  ThemeRoots: array[0..2] of string = ('~/.themes', '/usr/share/themes', '/usr/local/share/themes');
  ButtonNames: array[0..5] of record Letter: Char; Name: string; end = (
    (Letter: 'O'; Name: 'menu'), (Letter: 'T'; Name: 'stick'), (Letter: 'S'; Name: 'shade'),
    (Letter: 'H'; Name: 'hide'), (Letter: 'M'; Name: 'maximize'), (Letter: 'C'; Name: 'close'));

{ ---- GTK2-style shading ---- }

procedure RgbToHls(R, G, B: Double; out H, L, S: Double);
var
  Mx, Mn, D: Double;
begin
  if R > G then begin Mx := R; Mn := G; end else begin Mx := G; Mn := R; end;
  if B > Mx then Mx := B;
  if B < Mn then Mn := B;
  L := (Mx + Mn) / 2;
  S := 0;
  H := 0;
  if Mx <> Mn then
  begin
    D := Mx - Mn;
    if L <= 0.5 then S := D / (Mx + Mn) else S := D / (2 - Mx - Mn);
    if R = Mx then H := (G - B) / D
    else if G = Mx then H := 2 + (B - R) / D
    else H := 4 + (R - G) / D;
    H := H * 60;
    if H < 0 then H := H + 360;
  end;
end;

function HlsChan(M1, M2, H: Double): Double;
begin
  while H > 360 do H := H - 360;
  while H < 0 do H := H + 360;
  if H < 60 then Result := M1 + (M2 - M1) * H / 60
  else if H < 180 then Result := M2
  else if H < 240 then Result := M1 + (M2 - M1) * (240 - H) / 60
  else Result := M1;
end;

procedure HlsToRgb(H, L, S: Double; out R, G, B: Double);
var
  M1, M2: Double;
begin
  if L <= 0.5 then M2 := L * (1 + S) else M2 := L + S - L * S;
  M1 := 2 * L - M2;
  if S = 0 then begin R := L; G := L; B := L; end
  else begin
    R := HlsChan(M1, M2, H + 120);
    G := HlsChan(M1, M2, H);
    B := HlsChan(M1, M2, H - 120);
  end;
end;

function ClampByte(V: Double): LongWord;
begin
  if V < 0 then V := 0;
  if V > 1 then V := 1;
  Result := Round(V * 255);
end;

function ShadeColor(C: LongWord; K: Double): LongWord;
var
  R, G, B, H, L, S: Double;
begin
  R := ((C shr 16) and 255) / 255;
  G := ((C shr 8) and 255) / 255;
  B := (C and 255) / 255;
  RgbToHls(R, G, B, H, L, S);
  L := L * K;
  if L > 1 then L := 1;
  S := S * K;
  if S > 1 then S := 1;
  HlsToRgb(H, L, S, R, G, B);
  Result := (C and $FF000000) or (ClampByte(R) shl 16) or (ClampByte(G) shl 8) or ClampByte(B);
end;

function MidColor(A, B: LongWord): LongWord;
var
  R, G, Bl: LongWord;
begin
  R := (((A shr 16) and 255) + ((B shr 16) and 255)) div 2;
  G := (((A shr 8) and 255) + ((B shr 8) and 255)) div 2;
  Bl := ((A and 255) + (B and 255)) div 2;
  Result := (A and $FF000000) or (R shl 16) or (G shl 8) or Bl;
end;

function DefaultPalette: TThemePalette;
begin
  { measured from live xfwm4 + Adwaita-dark on this machine (2026-11-20) }
  Result.Color1[wsActive] := $FF14529E;
  Result.Color1[wsInactive] := $FF323232;
  Result.Color2[wsActive] := $FF353535;
  Result.Color2[wsInactive] := $FF353535;
end;

function DefaultFrameOpts(Theme: TXfwmTheme): TFrameOpts;
begin
  Result.Layout := 'O|SHMC';
  Result.ButtonOffset := Theme.RCInt('button_offset', 0);
  Result.ButtonSpacing := Theme.RCInt('button_spacing', 0);
  Result.ButtonY := 0;
  Result.LeftStart := Theme.Metrics.LeftW;
  Result.RightEnd := Theme.Metrics.RightW;
  Result.TextX := 0;
  Result.TextW := 0;
  Result.Pressed := #0;
  Result.Prelight := #0;
  Result.Toggled := '';
  Result.Shaded := False;
end;

{ TXfwmTheme }

constructor TXfwmTheme.Create;
begin
  inherited Create;
  FRC := TStringList.Create;
  FParts := TStringList.Create;
  FParts.CaseSensitive := True;
  FParts.Sorted := True;
  FParts.Duplicates := dupIgnore;
end;

destructor TXfwmTheme.Destroy;
var
  I: Integer;
begin
  for I := 0 to FParts.Count - 1 do
    FParts.Objects[I].Free;
  FParts.Free;
  FRC.Free;
  inherited Destroy;
end;

function TXfwmTheme.RC(const Key, Def: string): string;
var
  I: Integer;
begin
  I := FRC.IndexOfName(Key);
  if I >= 0 then Result := Trim(FRC.ValueFromIndex[I]) else Result := Def;
end;

function TXfwmTheme.RCInt(const Key: string; Def: Integer): Integer;
begin
  Result := StrToIntDef(RC(Key, ''), Def);
end;

function TXfwmTheme.RCBool(const Key: string; Def: Boolean): Boolean;
var
  S: string;
begin
  S := LowerCase(RC(Key, ''));
  if S = '' then Exit(Def);
  Result := (S = 'true') or (S = '1') or (S = 'yes');
end;

function TXfwmTheme.PalLookup(const Name: string; out C: LongWord): Boolean;
var
  St: TWinState;
  Rest, Kind: string;
  Idx: Integer;
  Base: LongWord;
begin
  Result := False;
  if Pos('active_', Name) = 1 then begin St := wsActive; Rest := Copy(Name, 8, MaxInt); end
  else if Pos('inactive_', Name) = 1 then begin St := wsInactive; Rest := Copy(Name, 10, MaxInt); end
  else Exit;
  if (Length(Rest) < 2) or not (Rest[Length(Rest)] in ['1', '2']) then Exit;
  Idx := Ord(Rest[Length(Rest)]) - Ord('0');
  Kind := Copy(Rest, 1, Length(Rest) - 2);
  if Idx = 1 then Base := FPal.Color1[St] else Base := FPal.Color2[St];
  if Kind = 'color' then C := Base
  else if Kind = 'hilight' then C := ShadeColor(Base, 1.3)
  else if Kind = 'shadow' then C := ShadeColor(Base, 0.7)
  else if Kind = 'mid' then C := MidColor(ShadeColor(Base, 1.3), ShadeColor(Base, 0.7))
  else Exit;
  Result := True;
end;

function TXfwmTheme.LoadPart(const PartName: string): TImg;
var
  X, P, Res: TImg;
  Y, XX: Integer;
  Cmp: LongWord;
begin
  X := LoadXPMImg(FDir + PartName + '.xpm', @PalLookup);
  P := LoadPNGImg(FDir + PartName + '.png');
  if (X = nil) and (P = nil) then Exit(nil);
  if P = nil then Exit(X);
  if X = nil then Exit(P);
  Res := TImg.Create(P.W, P.H);
  for Y := 0 to P.H - 1 do
    for XX := 0 to P.W - 1 do
    begin
      { the XPM is the shape: where it is transparent the PNG is not drawn }
      Cmp := X.Get(XX mod X.W, Y mod X.H);
      if (Cmp shr 24) <> 0 then Cmp := BlendPx(Cmp, P.Get(XX, Y));
      Res.SetPx(XX, Y, Cmp);
    end;
  X.Free;
  P.Free;
  Result := Res;
end;

function TXfwmTheme.Part(const PartName: string): TImg;
var
  I: Integer;
begin
  I := FParts.IndexOf(PartName);
  if I >= 0 then Exit(TImg(FParts.Objects[I]));
  Result := LoadPart(PartName);
  FParts.AddObject(PartName, Result);
end;

function TXfwmTheme.StatePart(const Base: string; St: TWinState): TImg;
begin
  if St = wsActive then Result := Part(Base + '-active')
  else begin
    Result := Part(Base + '-inactive');
    if Result = nil then Result := Part(Base + '-active');
  end;
end;

function TXfwmTheme.ButtonImg(Letter: Char; St: TWinState; const O: TFrameOpts): TImg;
var
  I: Integer;
  Nm, Tg, Variant: string;
begin
  Result := nil;
  Nm := '';
  for I := 0 to High(ButtonNames) do
    if ButtonNames[I].Letter = Letter then Nm := ButtonNames[I].Name;
  if Nm = '' then Exit;
  if Pos(Letter, O.Toggled) > 0 then Tg := '-toggled' else Tg := '';
  if O.Pressed = Letter then Variant := 'pressed'
  else if O.Prelight = Letter then Variant := 'prelight'
  else if St = wsActive then Variant := 'active' else Variant := 'inactive';
  Result := Part(Nm + Tg + '-' + Variant);
  if (Result = nil) and (Variant <> 'active') and (Variant <> 'inactive') then
    Result := StatePart(Nm + Tg, St);
  if (Result = nil) and (Tg <> '') then
    Result := StatePart(Nm, St);
  if Result = nil then
    Result := StatePart(Nm, St);
end;

function TXfwmTheme.Load(const ThemeName: string; const Pal: TThemePalette): Boolean;
var
  I: Integer;
  Root, D: string;
  Img: TImg;
begin
  Result := False;
  FPal := Pal;
  FName := ThemeName;
  FDir := '';
  for I := 0 to High(ThemeRoots) do
  begin
    Root := ThemeRoots[I];
    if (Length(Root) > 0) and (Root[1] = '~') then
      Root := GetEnvironmentVariable('HOME') + Copy(Root, 2, MaxInt);
    D := IncludeTrailingPathDelimiter(Root) + ThemeName + '/xfwm4/';
    if DirectoryExists(D) then begin FDir := D; Break; end;
  end;
  if FDir = '' then Exit;
  FRC.Clear;
  if FileExists(FDir + 'themerc') then
  begin
    FRC.LoadFromFile(FDir + 'themerc');
    for I := FRC.Count - 1 downto 0 do
      if (Trim(FRC[I]) = '') or (Trim(FRC[I])[1] = '#') or (Pos('=', FRC[I]) = 0) then
        FRC.Delete(I);
  end;
  FillChar(FMetrics, SizeOf(FMetrics), 0);
  Img := StatePart('title-3', wsActive);
  if Img <> nil then FMetrics.TitleH := Img.H;
  Img := StatePart('left', wsActive);
  if Img <> nil then FMetrics.LeftW := Img.W;
  Img := StatePart('right', wsActive);
  if Img <> nil then FMetrics.RightW := Img.W;
  Img := StatePart('bottom', wsActive);
  if Img <> nil then FMetrics.BottomH := Img.H;
  Img := StatePart('top-left', wsActive);
  if Img <> nil then FMetrics.TLW := Img.W;
  Img := StatePart('top-right', wsActive);
  if Img <> nil then FMetrics.TRW := Img.W;
  Img := StatePart('bottom-left', wsActive);
  if Img <> nil then begin FMetrics.BLW := Img.W; FMetrics.BLH := Img.H; end;
  Img := StatePart('bottom-right', wsActive);
  if Img <> nil then begin FMetrics.BRW := Img.W; FMetrics.BRH := Img.H; end;
  Result := True;
end;

function TXfwmTheme.Symbol(const Name: string; out C: LongWord): Boolean;
begin
  Result := PalLookup(Name, C);
end;

function TXfwmTheme.ButtonRects(const O: TFrameOpts; W: Integer; St: TWinState): TButtonRects;
var
  SepAt, I, X, N: Integer;
  Img: TImg;
  Right: array of TButtonRect;
begin
  SetLength(Result, 0);
  SepAt := Pos('|', O.Layout);
  { left group, left to right }
  X := O.LeftStart + O.ButtonOffset;
  for I := 1 to Length(O.Layout) do
  begin
    if O.Layout[I] = '|' then Break;
    Img := ButtonImg(O.Layout[I], St, O);
    if Img = nil then Continue;
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N].Letter := O.Layout[I];
    Result[N].X := X;
    Result[N].Y := O.ButtonY;
    Result[N].W := Img.W;
    Result[N].H := Img.H;
    Inc(X, Img.W + O.ButtonSpacing);
  end;
  if SepAt = 0 then Exit;
  { right group: placed right to left, listed left to right }
  X := W - O.RightEnd - O.ButtonOffset;
  SetLength(Right, 0);
  for I := Length(O.Layout) downto SepAt + 1 do
  begin
    Img := ButtonImg(O.Layout[I], St, O);
    if Img = nil then Continue;
    Dec(X, Img.W);
    N := Length(Right);
    SetLength(Right, N + 1);
    Right[N].Letter := O.Layout[I];
    Right[N].X := X;
    Right[N].Y := O.ButtonY;
    Right[N].W := Img.W;
    Right[N].H := Img.H;
    Dec(X, O.ButtonSpacing);
  end;
  for I := High(Right) downto 0 do
  begin
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N] := Right[I];
  end;
end;

procedure TXfwmTheme.TitleSpan(const O: TFrameOpts; W: Integer; out LeftEnd, RightStart: Integer);
var
  R: TButtonRects;
  I, SepAt, NLeft: Integer;
begin
  R := ButtonRects(O, W, wsActive);
  SepAt := Pos('|', O.Layout);
  LeftEnd := O.LeftStart + O.ButtonOffset;
  RightStart := W - O.RightEnd - O.ButtonOffset;
  { buttons before the separator are the left group }
  NLeft := 0;
  for I := 1 to SepAt - 1 do
    if ButtonImg(O.Layout[I], wsActive, O) <> nil then Inc(NLeft);
  if SepAt = 0 then NLeft := Length(R);
  for I := 0 to High(R) do
    if I < NLeft then LeftEnd := R[I].X + R[I].W + O.ButtonSpacing
    else if R[I].X < RightStart then RightStart := R[I].X;
  if NLeft = 0 then LeftEnd := O.LeftStart + O.ButtonOffset;
end;

function TXfwmTheme.HitTest(const O: TFrameOpts; W, H, X, Y: Integer): THit;
const
  TopGrip = 2;
var
  R: TButtonRects;
  I: Integer;
  M: TThemeMetrics;
  InL, InR, InT, InB: Boolean;
begin
  Result.Kind := hkNone;
  Result.Letter := #0;
  M := FMetrics;
  if (X < 0) or (Y < 0) or (X >= W) or (Y >= H) then Exit;
  R := ButtonRects(O, W, wsActive);
  for I := 0 to High(R) do
    if (X >= R[I].X) and (X < R[I].X + R[I].W) and (Y >= R[I].Y) and (Y < R[I].Y + R[I].H) then
    begin
      Result.Kind := hkButton;
      Result.Letter := R[I].Letter;
      Exit;
    end;
  if O.Shaded then
  begin
    if Y < M.TitleH then Result.Kind := hkTitle;
    Exit;
  end;
  { bottom corners overlap the side borders, so test them first }
  if (Y >= H - M.BLH) and (X < M.BLW) then begin Result.Kind := hkSW; Exit; end;
  if (Y >= H - M.BRH) and (X >= W - M.BRW) then begin Result.Kind := hkSE; Exit; end;
  InL := X < M.LeftW;
  InR := X >= W - M.RightW;
  InT := Y < TopGrip;
  InB := Y >= H - M.BottomH;
  if InT and (X < M.TLW) then begin Result.Kind := hkNW; Exit; end;
  if InT and (X >= W - M.TRW) then begin Result.Kind := hkNE; Exit; end;
  if InT then begin Result.Kind := hkN; Exit; end;
  if Y < M.TitleH then begin Result.Kind := hkTitle; Exit; end;
  if InB then begin Result.Kind := hkS; Exit; end;
  if InL then begin Result.Kind := hkW; Exit; end;
  if InR then begin Result.Kind := hkE; Exit; end;
end;

procedure TXfwmTheme.Compose(Dst: TImg; St: TWinState; const O: TFrameOpts);
var
  M: TThemeMetrics;
  W, H, X, I, MidA, MidB: Integer;
  T1, T2, T3, T4, T5, Img: TImg;
  Cx, Cy: TImg;
  Rects: TButtonRects;
begin
  M := FMetrics;
  W := Dst.W;
  H := Dst.H;
  { top row: corners, then the title strip between them }
  Img := StatePart('top-left', St);
  if Img <> nil then Dst.Blend(Img, 0, 0);
  Img := StatePart('top-right', St);
  if Img <> nil then Dst.Blend(Img, W - Img.W, 0);
  T1 := StatePart('title-1', St);
  T2 := StatePart('title-2', St);
  T3 := StatePart('title-3', St);
  T4 := StatePart('title-4', St);
  T5 := StatePart('title-5', St);
  MidA := M.TLW;
  MidB := W - M.TRW;
  if T1 <> nil then begin Dst.Blend(T1, MidA, 0); Inc(MidA, T1.W); end;
  if T5 <> nil then begin Dec(MidB, T5.W); Dst.Blend(T5, MidB, 0); end;
  if (O.TextW > 0) and (T2 <> nil) and (T3 <> nil) and (T4 <> nil) then
  begin
    X := O.TextX;
    if X < MidA then X := MidA;
    if X > MidB then X := MidB;
    Dst.BlendTiled(T2, MidA, 0, X - MidA, T2.H);
    I := X + O.TextW;
    if I > MidB then I := MidB;
    Dst.BlendTiled(T3, X, 0, I - X, T3.H);
    Dst.BlendTiled(T4, I, 0, MidB - I, T4.H);
  end
  else if T3 <> nil then
    Dst.BlendTiled(T3, MidA, 0, MidB - MidA, T3.H);
  { buttons: left to right, so each button's left edge wins where they overlap }
  Rects := ButtonRects(O, W, St);
  for I := 0 to High(Rects) do
  begin
    Img := ButtonImg(Rects[I].Letter, St, O);
    if Img <> nil then Dst.Blend(Img, Rects[I].X, Rects[I].Y);
  end;
  if O.Shaded then Exit;
  { sides and bottom }
  Img := StatePart('left', St);
  if Img <> nil then Dst.BlendTiled(Img, 0, M.TitleH, Img.W, H - M.TitleH - M.BLH);
  Img := StatePart('right', St);
  if Img <> nil then Dst.BlendTiled(Img, W - Img.W, M.TitleH, Img.W, H - M.TitleH - M.BRH);
  Img := StatePart('bottom', St);
  if Img <> nil then Dst.BlendTiled(Img, M.BLW, H - Img.H, W - M.BLW - M.BRW, Img.H);
  Cx := StatePart('bottom-left', St);
  if Cx <> nil then Dst.Blend(Cx, 0, H - Cx.H);
  Cy := StatePart('bottom-right', St);
  if Cy <> nil then Dst.Blend(Cy, W - Cy.W, H - Cy.H);
end;

end.
