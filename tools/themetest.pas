program themetest;

{ Compose a theme frame and diff it against a screenshot of real xfwm4.
  Usage: themetest <theme> <ref.png> <state: active|inactive> [search] }

{$mode objfpc}{$H+}

uses
  SysUtils, twimage, twtheme;

var
  Theme: TXfwmTheme;
  Ref, Dst: TImg;
  St: TWinState;
  O, BestO: TFrameOpts;
  Mismatch, BestMis: Integer;

function Chan(C: LongWord; Sh: Integer): Integer;
begin
  Result := (C shr Sh) and 255;
end;

function Masked(X, Y: Integer): Boolean;
begin
  { client area, and the title text }
  Result := ((X >= Theme.Metrics.LeftW) and (X < Ref.W - Theme.Metrics.RightW) and
             (Y >= Theme.Metrics.TitleH) and (Y < Ref.H - Theme.Metrics.BottomH)) or
            ((X >= 28) and (X < 170) and (Y >= 0) and (Y < Theme.Metrics.TitleH)) or
            ((X >= 7) and (X < 29) and (Y < Theme.Metrics.TitleH));
end;

function Score(const Opt: TFrameOpts; Report: Boolean): Integer;
var
  X, Y, N, Dm, D1, D2, D3: Integer;
  Bad: array of string;
  ByRow: array[0..1023] of Integer;
  ByCol: array[0..1023] of Integer;
  Cmp: LongWord;
begin
  Dst.Clear($FF000000);
  Theme.Compose(Dst, St, Opt);
  N := 0;
  FillChar(ByRow, SizeOf(ByRow), 0);
  FillChar(ByCol, SizeOf(ByCol), 0);
  for Y := 0 to Ref.H - 1 do
    for X := 0 to Ref.W - 1 do
    begin
      if Masked(X, Y) then Continue;
      Cmp := Dst.Get(X, Y);
      D1 := Abs(Chan(Cmp, 16) - Chan(Ref.Get(X, Y), 16));
      D2 := Abs(Chan(Cmp, 8) - Chan(Ref.Get(X, Y), 8));
      D3 := Abs(Chan(Cmp, 0) - Chan(Ref.Get(X, Y), 0));
      Dm := D1;
      if D2 > Dm then Dm := D2;
      if D3 > Dm then Dm := D3;
      if Dm > 3 then
      begin
        Inc(N);
        Inc(ByRow[Y]);
        Inc(ByCol[X]);
        if Report and (Length(Bad) < 0) then
        begin
          SetLength(Bad, Length(Bad) + 1);
          Bad[High(Bad)] := Format('(%d,%d) ours=%.8x ref=%.8x', [X, Y, Cmp, Ref.Get(X, Y)]);
        end;
      end;
    end;
  if Report then
  begin
    for X := 0 to High(Bad) do WriteLn('  ', Bad[X]);
    Write('  rows:');
    for Y := 0 to Ref.H - 1 do if ByRow[Y] > 0 then Write(' ', Y, ':', ByRow[Y]);
    WriteLn;
    Write('  cols:');
    for X := 0 to Ref.W - 1 do if ByCol[X] > 0 then Write(' ', X, ':', ByCol[X]);
    WriteLn;
  end;
  Result := N;
end;

var
  ThemeName, RefFile, StName: string;
  Search: Boolean;
  Off, Sp, Ls, Re, By, Tot: Integer;
  LsOpts, ReOpts: array[0..2] of Integer;
begin
  if ParamCount < 3 then
  begin
    WriteLn('usage: themetest <theme> <ref.png> <active|inactive> [search]');
    Halt(2);
  end;
  ThemeName := ParamStr(1);
  RefFile := ParamStr(2);
  StName := ParamStr(3);
  Search := ParamStr(4) = 'search';
  if StName = 'active' then St := wsActive else St := wsInactive;
  Ref := LoadPNGImg(RefFile);
  if Ref = nil then begin WriteLn('cannot load ', RefFile); Halt(1); end;
  Theme := TXfwmTheme.Create;
  if not Theme.Load(ThemeName, DefaultPalette) then
  begin
    WriteLn('theme not found: ', ThemeName);
    Halt(1);
  end;
  with Theme.Metrics do
    WriteLn(Format('metrics: title=%d left=%d right=%d bottom=%d  TL=%d TR=%d BL=%dx%d BR=%dx%d',
      [TitleH, LeftW, RightW, BottomH, TLW, TRW, BLW, BLH, BRW, BRH]));
  Dst := TImg.Create(Ref.W, Ref.H);
  O := DefaultFrameOpts(Theme);
  WriteLn('themerc button_offset=', O.ButtonOffset, ' spacing=', O.ButtonSpacing);
  Tot := 0;
  for Off := 0 to Ref.H * Ref.W - 1 do
    if not Masked(Off mod Ref.W, Off div Ref.W) then Inc(Tot);
  WriteLn('pixels compared: ', Tot);
  BestMis := MaxInt;
  if Search then
  begin
    LsOpts[0] := Theme.Metrics.LeftW; LsOpts[1] := 0; LsOpts[2] := Theme.Metrics.TLW;
    ReOpts[0] := Theme.Metrics.RightW; ReOpts[1] := 0; ReOpts[2] := Theme.Metrics.TRW;
    for Off := -2 to 3 do
      for Sp := -2 to 2 do
        for Ls := 0 to 2 do
          for Re := 0 to 2 do
           for By := 0 to 1 do
          begin
            O := DefaultFrameOpts(Theme);
            O.ButtonY := By;
            O.ButtonOffset := Off;
            O.ButtonSpacing := Sp;
            O.LeftStart := LsOpts[Ls];
            O.RightEnd := ReOpts[Re];
            Mismatch := Score(O, False);
            if Mismatch < BestMis then begin BestMis := Mismatch; BestO := O; end;
          end;
    WriteLn(Format('best: offset=%d spacing=%d leftstart=%d rightend=%d y=%d  mismatches=%d',
      [BestO.ButtonOffset, BestO.ButtonSpacing, BestO.LeftStart, BestO.RightEnd, BestO.ButtonY, BestMis]));
    O := BestO;
  end;
  Mismatch := Score(O, True);
  WriteLn('mismatching pixels (>3 per channel): ', Mismatch, ' of ', Tot);
  ForceDirectories('../out');
  Dst.Clear($FF000000);
  Theme.Compose(Dst, St, O);
  Dst.SavePNG('../out/composed-' + StName + '.png');
end.
