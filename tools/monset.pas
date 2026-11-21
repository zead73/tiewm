program monset;

{ Test helper: defines virtual RandR monitors on the current display and stays
  alive (they vanish when the creating client exits on some servers).
    monset SECONDS name=x,y,w,h [name=x,y,w,h ...]
    monset 0 ...     define them and exit at once
    monset 0 del=name  delete a monitor (also one another monset still holds)
  Used by wmtest.sh to emulate several monitors inside one Xvfb screen. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, ctypes, x, xlib, twxrandr;

var
  Dpy: PDisplay;
  Root: TWindow;
  I, P, Secs: Integer;
  Spec, Nm: string;
  Parts: TStringList;
  M: PXRRMonitorInfo;
begin
  if ParamCount < 2 then begin WriteLn('usage: monset SECONDS name=x,y,w,h ...'); Halt(2); end;
  Secs := StrToInt(ParamStr(1));
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then begin WriteLn('cannot open display'); Halt(1); end;
  Root := DefaultRootWindow(Dpy);
  Parts := TStringList.Create;
  Parts.Delimiter := ',';
  Parts.StrictDelimiter := True;
  for I := 2 to ParamCount do
  begin
    Spec := ParamStr(I);
    P := Pos('=', Spec);
    Nm := Copy(Spec, 1, P - 1);
    if Nm = 'del' then
    begin
      XRRDeleteMonitor(Dpy, Root, XInternAtom(Dpy, PChar(Copy(Spec, P + 1, 99)), 0));
      Continue;
    end;
    Parts.DelimitedText := Copy(Spec, P + 1, 99);
    M := XRRAllocateMonitor(Dpy, 0);
    M^.name := XInternAtom(Dpy, PChar(Nm), 0);
    M^.primary := Ord(I = 2);
    M^.automatic := 0;
    M^.x := StrToInt(Parts[0]); M^.y := StrToInt(Parts[1]);
    M^.width := StrToInt(Parts[2]); M^.height := StrToInt(Parts[3]);
    M^.mwidth := M^.width * 264 div 1000; M^.mheight := M^.height * 264 div 1000;
    XRRSetMonitor(Dpy, Root, M);
    XRRFreeMonitors(M);
  end;
  XSync(Dpy, 0);
  if Secs > 0 then Sleep(Secs * 1000);
  XCloseDisplay(Dpy);
end.
