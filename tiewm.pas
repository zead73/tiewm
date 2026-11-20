program tiewm;

{ tiewm - a floating window manager in Free Pascal that draws xfwm4 themes.
  Run it only on a display you mean to manage; it refuses to start if
  another window manager already owns the root window.

    DISPLAY=:99 tiewm            theme from TIEWM_THEME (default Daloa),
                                 title font from TIEWM_FONT (default "Sans Bold 11")
    TIEWM_DEBUG=1                log to stderr
  SIGTERM/SIGINT shut it down cleanly and hand all windows back to the root. }

{$mode objfpc}{$H+}

uses
  SysUtils, BaseUnix, ctypes, x, xlib, twwm;

var
  GWm: TWM;

procedure OnSignal(Sig: cint); cdecl;
begin
  if GWm <> nil then GWm.Quit := True;
end;

var
  Dpy: PDisplay;
  ThemeName, FontName: string;
begin
  if GetEnvironmentVariable('DISPLAY') = '' then
  begin
    WriteLn(StdErr, 'tiewm: DISPLAY is not set');
    Halt(1);
  end;
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then
  begin
    WriteLn(StdErr, 'tiewm: cannot open display ', GetEnvironmentVariable('DISPLAY'));
    Halt(1);
  end;
  ThemeName := GetEnvironmentVariable('TIEWM_THEME');
  if ThemeName = '' then ThemeName := 'Daloa';
  FontName := GetEnvironmentVariable('TIEWM_FONT');
  if FontName = '' then FontName := 'Sans Bold 11';
  try
    GWm := TWM.Create(Dpy, ThemeName, FontName);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'tiewm: ', E.Message);
      Halt(1);
    end;
  end;
  if not GWm.Claim then
  begin
    WriteLn(StdErr, 'tiewm: another window manager is already running on ',
      GetEnvironmentVariable('DISPLAY'));
    Halt(1);
  end;
  FpSignal(SIGTERM, @OnSignal);
  FpSignal(SIGINT, @OnSignal);
  GWm.Run;
  GWm.Shutdown;
  XCloseDisplay(Dpy);
end.
