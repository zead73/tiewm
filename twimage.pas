unit twimage;

{ Plain ARGB pixel buffers for theme drawing. No X dependency, so the
  theme engine can be tested by writing PNGs. Pixels are $AARRGGBB,
  non-premultiplied. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpimage, fpreadpng, fpwritepng;

type
  TPalLookup = function(const Name: string; out C: LongWord): Boolean of object;

  { TImg }

  TImg = class
  private
    FW, FH: Integer;
    FPix: array of LongWord;
  public
    constructor Create(AW, AH: Integer);
    function InBounds(X, Y: Integer): Boolean;
    function Get(X, Y: Integer): LongWord;
    procedure SetPx(X, Y: Integer; C: LongWord);
    procedure Clear(C: LongWord);
    { src-over blend of Src (with its alpha) at DX,DY, clipped }
    procedure Blend(Src: TImg; DX, DY: Integer);
    { same, but repeat Src to cover the rectangle X,Y,W,H }
    procedure BlendTiled(Src: TImg; X, Y, W, H: Integer);
    { blends only the rectangle SX,SY,W,H of Src, placing its top-left corner at DX,DY }
    procedure BlendRect(Src: TImg; DX, DY, SX, SY, W, H: Integer);
    procedure SavePNG(const FileName: string);
    { raw pixel array (row-major, W*H), for fast loops }
    function Raw: PLongWord;
    property W: Integer read FW;
    property H: Integer read FH;
  end;

function LoadPNGImg(const FileName: string): TImg;
{ Parses an XPM. A symbolic colour ("s name") is looked up through Lookup
  first; otherwise the "c" colour is used. None becomes transparent. }
function LoadXPMImg(const FileName: string; Lookup: TPalLookup): TImg;
function BlendPx(Dst, Src: LongWord): LongWord;

implementation

function BlendPx(Dst, Src: LongWord): LongWord;
var
  sa, da, oa, sr, sg, sb, dr, dg, db, r, g, b: Integer;
begin
  sa := Src shr 24;
  if sa = 255 then Exit(Src);
  if sa = 0 then Exit(Dst);
  da := Dst shr 24;
  { src-over, non-premultiplied }
  oa := sa + (da * (255 - sa) + 127) div 255;
  sr := (Src shr 16) and 255; sg := (Src shr 8) and 255; sb := Src and 255;
  dr := (Dst shr 16) and 255; dg := (Dst shr 8) and 255; db := Dst and 255;
  if oa = 0 then Exit(0);
  r := (sr * sa * 255 + dr * da * (255 - sa) + (oa * 255) div 2) div (oa * 255);
  g := (sg * sa * 255 + dg * da * (255 - sa) + (oa * 255) div 2) div (oa * 255);
  b := (sb * sa * 255 + db * da * (255 - sa) + (oa * 255) div 2) div (oa * 255);
  Result := (LongWord(oa) shl 24) or (LongWord(r) shl 16) or (LongWord(g) shl 8) or LongWord(b);
end;

{ TImg }

constructor TImg.Create(AW, AH: Integer);
begin
  inherited Create;
  FW := AW;
  FH := AH;
  SetLength(FPix, AW * AH);
end;

function TImg.Raw: PLongWord;
begin
  if Length(FPix) = 0 then Result := nil else Result := @FPix[0];
end;

function TImg.InBounds(X, Y: Integer): Boolean;
begin
  Result := (X >= 0) and (Y >= 0) and (X < FW) and (Y < FH);
end;

function TImg.Get(X, Y: Integer): LongWord;
begin
  if InBounds(X, Y) then Result := FPix[Y * FW + X] else Result := 0;
end;

procedure TImg.SetPx(X, Y: Integer; C: LongWord);
begin
  if InBounds(X, Y) then FPix[Y * FW + X] := C;
end;

procedure TImg.Clear(C: LongWord);
var
  I: Integer;
begin
  for I := 0 to High(FPix) do FPix[I] := C;
end;

procedure TImg.Blend(Src: TImg; DX, DY: Integer);
var
  X, Y: Integer;
begin
  for Y := 0 to Src.H - 1 do
    for X := 0 to Src.W - 1 do
      if InBounds(DX + X, DY + Y) then
        FPix[(DY + Y) * FW + DX + X] := BlendPx(FPix[(DY + Y) * FW + DX + X], Src.Get(X, Y));
end;

procedure TImg.BlendTiled(Src: TImg; X, Y, W, H: Integer);
var
  PX, PY: Integer;
begin
  if (Src.W = 0) or (Src.H = 0) then Exit;
  for PY := 0 to H - 1 do
    for PX := 0 to W - 1 do
      if InBounds(X + PX, Y + PY) then
        FPix[(Y + PY) * FW + X + PX] :=
          BlendPx(FPix[(Y + PY) * FW + X + PX], Src.Get(PX mod Src.W, PY mod Src.H));
end;

procedure TImg.BlendRect(Src: TImg; DX, DY, SX, SY, W, H: Integer);
var
  X, Y: Integer;
begin
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
      if InBounds(DX + X, DY + Y) then
        FPix[(DY + Y) * FW + DX + X] := BlendPx(FPix[(DY + Y) * FW + DX + X], Src.Get(SX + X, SY + Y));
end;

procedure TImg.SavePNG(const FileName: string);
var
  M: TFPMemoryImage;
  Wr: TFPWriterPNG;
  X, Y: Integer;
  C: LongWord;
  Col: TFPColor;
begin
  M := TFPMemoryImage.Create(FW, FH);
  Wr := TFPWriterPNG.Create;
  try
    Wr.UseAlpha := True;
    M.UsePalette := False;
    for Y := 0 to FH - 1 do
      for X := 0 to FW - 1 do
      begin
        C := Get(X, Y);
        Col.alpha := ((C shr 24) and 255) * 257;
        Col.red := ((C shr 16) and 255) * 257;
        Col.green := ((C shr 8) and 255) * 257;
        Col.blue := (C and 255) * 257;
        M.Colors[X, Y] := Col;
      end;
    M.SaveToFile(FileName, Wr);
  finally
    Wr.Free;
    M.Free;
  end;
end;

function LoadPNGImg(const FileName: string): TImg;
var
  M: TFPMemoryImage;
  Rd: TFPReaderPNG;
  X, Y: Integer;
  Col: TFPColor;
begin
  Result := nil;
  if not FileExists(FileName) then Exit;
  M := TFPMemoryImage.Create(0, 0);
  Rd := TFPReaderPNG.Create;
  try
    M.LoadFromFile(FileName, Rd);
    Result := TImg.Create(M.Width, M.Height);
    for Y := 0 to M.Height - 1 do
      for X := 0 to M.Width - 1 do
      begin
        Col := M.Colors[X, Y];
        Result.SetPx(X, Y,
          (LongWord(Col.alpha shr 8) shl 24) or (LongWord(Col.red shr 8) shl 16) or
          (LongWord(Col.green shr 8) shl 8) or LongWord(Col.blue shr 8));
      end;
  finally
    Rd.Free;
    M.Free;
  end;
end;

function ParseHexColor(const S: string; out C: LongWord): Boolean;
var
  H: string;
  V: QWord;
  N: Integer;
begin
  Result := False;
  if (Length(S) < 2) or (S[1] <> '#') then Exit;
  H := Copy(S, 2, Length(S));
  N := Length(H) div 3;
  if not (Length(H) in [3, 6, 9, 12]) then Exit;
  V := StrToQWordDef('$' + H, QWord(-1));
  if V = QWord(-1) then Exit;
  case N of
    1: C := $FF000000 or (((V shr 8) and 15) * 17 shl 16) or (((V shr 4) and 15) * 17 shl 8) or ((V and 15) * 17);
    2: C := $FF000000 or LongWord(V);
    3: C := $FF000000 or (((V shr 32) and 255) shl 16) or (((V shr 16) and 255) shl 8) or (V and 255);
    4: C := $FF000000 or (((V shr 40) and 255) shl 16) or (((V shr 20) and 255) shl 8) or ((V shr 4) and 255);
  end;
  Result := True;
end;

function NamedColor(const S: string; out C: LongWord): Boolean;
var
  L: string;
begin
  L := LowerCase(S);
  Result := True;
  if (L = 'none') then C := 0
  else if L = 'white' then C := $FFFFFFFF
  else if L = 'black' then C := $FF000000
  else if L = 'gray' then C := $FFBEBEBE
  else if L = 'red' then C := $FFFF0000
  else if L = 'green' then C := $FF00FF00
  else if L = 'blue' then C := $FF0000FF
  else Result := False;
end;

function LoadXPMImg(const FileName: string; Lookup: TPalLookup): TImg;
type
  TKey = record
    Key: string;
    Col: LongWord;
  end;
var
  SL: TStringList;
  Strs: TStringList;
  I, P, Q, W, H, NC, CPP, Row, X: Integer;
  Keys: array of TKey;
  Line, Rest, Tok, SymName, CName: string;
  Toks: TStringList;
  C, Sym: LongWord;
  HaveSym, HaveC: Boolean;
  Ch: string;
  J, K: Integer;
begin
  Result := nil;
  if not FileExists(FileName) then Exit;
  SL := TStringList.Create;
  Strs := TStringList.Create;
  Toks := TStringList.Create;
  try
    SL.LoadFromFile(FileName);
    { collect every double-quoted string in the file }
    for I := 0 to SL.Count - 1 do
    begin
      Line := SL[I];
      P := Pos('"', Line);
      while P > 0 do
      begin
        Q := Pos('"', Copy(Line, P + 1, MaxInt));
        if Q = 0 then Break;
        Strs.Add(Copy(Line, P + 1, Q - 1));
        Line := Copy(Line, P + Q + 1, MaxInt);
        P := Pos('"', Line);
      end;
    end;
    if Strs.Count < 1 then Exit;
    Toks.Delimiter := ' ';
    Toks.StrictDelimiter := False;
    Toks.DelimitedText := Strs[0];
    if Toks.Count < 4 then Exit;
    W := StrToIntDef(Toks[0], 0);
    H := StrToIntDef(Toks[1], 0);
    NC := StrToIntDef(Toks[2], 0);
    CPP := StrToIntDef(Toks[3], 0);
    if (W <= 0) or (H <= 0) or (NC <= 0) or (CPP <= 0) or (Strs.Count < 1 + NC + H) then Exit;
    SetLength(Keys, NC);
    for I := 0 to NC - 1 do
    begin
      Line := Strs[1 + I];
      Keys[I].Key := Copy(Line, 1, CPP);
      Rest := StringReplace(Copy(Line, CPP + 1, MaxInt), #9, ' ', [rfReplaceAll]);
      Toks.DelimitedText := Rest;
      HaveSym := False;
      HaveC := False;
      Sym := 0;
      C := 0;
      J := 0;
      while J < Toks.Count - 1 do
      begin
        Tok := Toks[J];
        if (Tok = 'c') or (Tok = 's') or (Tok = 'm') or (Tok = 'g') then
        begin
          CName := Toks[J + 1];
          if Tok = 'c' then
          begin
            if not ParseHexColor(CName, C) then
              if not NamedColor(CName, C) then C := $FF000000;
            HaveC := True;
          end
          else if Tok = 's' then
          begin
            SymName := CName;
            if Assigned(Lookup) then HaveSym := Lookup(SymName, Sym) else HaveSym := False;
          end;
          Inc(J, 2);
        end
        else Inc(J);
      end;
      if HaveSym then Keys[I].Col := Sym
      else if HaveC then Keys[I].Col := C
      else Keys[I].Col := 0;
    end;
    Result := TImg.Create(W, H);
    for Row := 0 to H - 1 do
    begin
      Line := Strs[1 + NC + Row];
      for X := 0 to W - 1 do
      begin
        Ch := Copy(Line, X * CPP + 1, CPP);
        for K := 0 to NC - 1 do
          if Keys[K].Key = Ch then
          begin
            Result.SetPx(X, Row, Keys[K].Col);
            Break;
          end;
      end;
    end;
  finally
    Toks.Free;
    Strs.Free;
    SL.Free;
  end;
end;

end.
