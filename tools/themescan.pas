program themescan;

{ Load every installed xfwm4 theme, compose a frame, write a PNG per theme
  to ../out/scan and print one line of metrics each. Catches crashes and
  missing parts across the theme corpus. Usage: themescan [themes-dir] }

{$mode objfpc}{$H+}

uses
  SysUtils, twimage, twtheme;

var
  Root: string;
  SR: TSearchRec;
  Theme: TXfwmTheme;
  Dst: TImg;
  O: TFrameOpts;
  Req: array[0..9] of string = ('top-left-active', 'top-right-active', 'left-active',
    'right-active', 'bottom-active', 'bottom-left-active', 'bottom-right-active',
    'title-3-active', 'close-active', 'maximize-active');
  Missing: string;
  I, Ok, Bad: Integer;
begin
  if ParamCount >= 1 then Root := ParamStr(1) else Root := '/usr/share/themes';
  ForceDirectories('../out/scan');
  Ok := 0;
  Bad := 0;
  if FindFirst(IncludeTrailingPathDelimiter(Root) + '*', faDirectory, SR) = 0 then
  repeat
    if (SR.Name = '.') or (SR.Name = '..') then Continue;
    if not DirectoryExists(IncludeTrailingPathDelimiter(Root) + SR.Name + '/xfwm4') then Continue;
    Theme := TXfwmTheme.Create;
    try
      try
        if not Theme.Load(SR.Name, DefaultPalette) then
        begin
          WriteLn(Format('%-18s LOAD FAILED', [SR.Name]));
          Inc(Bad);
          Continue;
        end;
        Missing := '';
        for I := 0 to High(Req) do
          if not (FileExists(Theme.Dir + Req[I] + '.png') or FileExists(Theme.Dir + Req[I] + '.xpm')) then
            Missing := Missing + ' ' + Req[I];
        with Theme.Metrics do
        begin
          if (TitleH <= 0) or (LeftW <= 0) then
          begin
            WriteLn(Format('%-18s UNUSABLE metrics (title=%d left=%d)  missing:%s', [SR.Name, TitleH, LeftW, Missing]));
            Inc(Bad);
            Continue;
          end;
          Dst := TImg.Create(400, TitleH + 200 + BottomH);
          O := DefaultFrameOpts(Theme);
          Theme.Compose(Dst, wsActive, O);
          Dst.SavePNG('../out/scan/' + SR.Name + '.png');
          WriteLn(Format('%-18s ok  title=%2d L=%d R=%d B=%d  img=%s%s',
            [SR.Name, TitleH, LeftW, RightW, BottomH,
             BoolToStr(FileExists(Theme.Dir + 'title-3-active.png'), 'png', 'xpm-only'),
             Missing]));
          Dst.Free;
          Inc(Ok);
        end;
      except
        on E: Exception do
        begin
          WriteLn(Format('%-18s EXCEPTION %s', [SR.Name, E.Message]));
          Inc(Bad);
        end;
      end;
    finally
      Theme.Free;
    end;
  until FindNext(SR) <> 0;
  FindClose(SR);
  WriteLn('ok=', Ok, ' bad=', Bad);
end.
