program tiewm;

{ tiewm - a floating window manager in Free Pascal that draws xfwm4 themes.
  Run it only on a display you mean to manage; it refuses to start if
  another window manager already owns the root window.

    tiewm                        start (reads ~/.config/tiewm/tiewm.conf, see tiewm.conf.example)
    tiewm --check-config [FILE]  parse the config, print what it means and any warnings, exit
    tiewm --log                  print the path of the log file
    tiewm --version

  Environment: TIEWM_CONFIG=FILE, TIEWM_THEME, TIEWM_FONT, TIEWM_DESKTOPS override the config;
  TIEWM_DEBUG=1 logs to stderr.
  SIGTERM/SIGINT shut it down cleanly and hand all windows back to the root;
  SIGHUP re-reads the key bindings. }

{$mode objfpc}{$H+}

uses
  SysUtils, BaseUnix, ctypes, x, xlib, twlog, twconfig, twwm;

const
  Version = '0.6.2';

var
  GWm: TWM;

procedure OnSignal(Sig: cint); cdecl;
begin
  if GWm <> nil then GWm.Quit := True;
end;

procedure OnHup(Sig: cint); cdecl;
begin
  if GWm <> nil then GWm.RequestReload;
end;

var
  Dpy: PDisplay;
  Cfg: TConfig;
  Path: string;
  I: Integer;
begin
  if (ParamCount >= 1) and (ParamStr(1) = '--version') then
  begin
    WriteLn('tiewm ', Version);
    Halt(0);
  end;
  if (ParamCount >= 1) and (ParamStr(1) = '--log') then
  begin
    { print where the log is }
    WriteLn(LoadConfig(DefaultConfigPath).LogFile);
    Halt(0);
  end;
  if (ParamCount >= 1) and (ParamStr(1) = '--check-config') then
  begin
    if ParamCount >= 2 then Path := ParamStr(2) else Path := DefaultConfigPath;
    Cfg := LoadConfig(Path);
    Write(DescribeConfig(Cfg));
    if Length(Cfg.Warnings) > 0 then Halt(1);
    Halt(0);
  end;
  if ParamCount >= 1 then
  begin
    WriteLn(StdErr, 'tiewm: unknown option ', ParamStr(1));
    Halt(2);
  end;
  if GetEnvironmentVariable('DISPLAY') = '' then
  begin
    WriteLn(StdErr, 'tiewm: DISPLAY is not set');
    Halt(1);
  end;
  Cfg := LoadConfig(DefaultConfigPath);
  LogOpen(Cfg.LogFile, Cfg.LogLevel, GetEnvironmentVariable('TIEWM_DEBUG') <> '');
  LogInfo(Format('tiewm %s starting on %s (theme %s, %d desktops, font "%s")',
    [Version, GetEnvironmentVariable('DISPLAY'), Cfg.Theme, Cfg.NumDesktops, Cfg.TitleFont]));
  if Cfg.Loaded then LogInfo('config: ' + Cfg.Path) else LogInfo('config: none (' + Cfg.Path + ' not found), using defaults');
  for I := 0 to High(Cfg.Warnings) do
  begin
    LogInfo('config warning: ' + Cfg.Warnings[I]);
    WriteLn(StdErr, 'tiewm: ', Cfg.Path, ': ', Cfg.Warnings[I]);
    Flush(StdErr);
  end;
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then
  begin
    WriteLn(StdErr, 'tiewm: cannot open display ', GetEnvironmentVariable('DISPLAY'));
    Halt(1);
  end;
  try
    GWm := TWM.Create(Dpy, Cfg);
  except
    on E: Exception do
    begin
      LogInfo('FATAL: ' + E.Message);
      WriteLn(StdErr, 'tiewm: ', E.Message);
      Halt(1);
    end;
  end;
  if not GWm.Claim then
  begin
    LogInfo('another window manager is already running, exiting');
    WriteLn(StdErr, 'tiewm: another window manager is already running on ',
      GetEnvironmentVariable('DISPLAY'));
    Halt(1);
  end;
  FpSignal(SIGTERM, @OnSignal);
  FpSignal(SIGINT, @OnSignal);
  FpSignal(SIGHUP, @OnHup);
  LogInfo('managing the display');
  GWm.Run;
  LogInfo('shutting down: handing windows back to the root');
  GWm.Shutdown;
  XCloseDisplay(Dpy);
  LogInfo('bye');
  LogClose;
end.
