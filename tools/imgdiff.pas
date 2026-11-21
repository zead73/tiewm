program imgdiff;

{ Counts the pixels of two same-sized PNGs that differ by more than a threshold on any colour
  channel (default 3, i.e. almost exact), and prints the bounding box of the differences.
  Usage: imgdiff a.png b.png [threshold]    Exit status 1 if the sizes differ. }

{$mode objfpc}{$H+}

uses
  SysUtils, twimage;

var
  A, B: TImg;
  Thr, X, Y, N, MinX, MinY, MaxX, MaxY, D, C: Integer;
  PA, PB: LongWord;
begin
  if ParamCount < 2 then begin WriteLn('usage: imgdiff a.png b.png [threshold]'); Halt(2); end;
  if ParamCount >= 3 then Thr := StrToInt(ParamStr(3)) else Thr := 3;
  A := LoadPNGImg(ParamStr(1));
  B := LoadPNGImg(ParamStr(2));
  if (A = nil) or (B = nil) then begin WriteLn('cannot load'); Halt(2); end;
  if (A.W <> B.W) or (A.H <> B.H) then begin WriteLn('size ', A.W, 'x', A.H, ' vs ', B.W, 'x', B.H); Halt(1); end;
  N := 0; MinX := MaxInt; MinY := MaxInt; MaxX := -1; MaxY := -1;
  for Y := 0 to A.H - 1 do
    for X := 0 to A.W - 1 do
    begin
      PA := A.Get(X, Y); PB := B.Get(X, Y);
      D := 0;
      for C := 0 to 2 do
        if Abs(Integer((PA shr (C * 8)) and 255) - Integer((PB shr (C * 8)) and 255)) > D then
          D := Abs(Integer((PA shr (C * 8)) and 255) - Integer((PB shr (C * 8)) and 255));
      if D > Thr then
      begin
        Inc(N);
        if X < MinX then MinX := X; if X > MaxX then MaxX := X;
        if Y < MinY then MinY := Y; if Y > MaxY then MaxY := Y;
      end;
    end;
  if N = 0 then WriteLn('0') else WriteLn(N, ' x', MinX, '-', MaxX, ' y', MinY, '-', MaxY);
end.
