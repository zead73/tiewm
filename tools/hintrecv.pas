program hintrecv;

{ Plays the compositor for tiewm's tests: owns _TIECOMP_S0 and prints every
  _TIECOMP_MOVE message it is sent. With -k it also asks, as for a desktop
  cube, that windows on other workspaces stay mapped. Runs until killed. }

{$mode objfpc}{$H+}

uses
  SysUtils, ctypes, x, xlib, xatom;

var
  Dpy: PDisplay;
  Win: TWindow;
  Move: TAtom;
  Ev: TXEvent;
  Want: culong = 1;
begin
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then Halt(1);
  Win := XCreateSimpleWindow(Dpy, DefaultRootWindow(Dpy), -10, -10, 1, 1, 0, 0, 0);
  Move := XInternAtom(Dpy, '_TIECOMP_MOVE', False);
  XSetSelectionOwner(Dpy, XInternAtom(Dpy, '_TIECOMP_S0', False), Win, CurrentTime);
  if ParamStr(1) = '-k' then
  begin
    XChangeProperty(Dpy, Win, XInternAtom(Dpy, '_TIECOMP_CUBE', False), XA_CARDINAL, 32,
      PropModeReplace, @Want, 1);
    FillChar(Ev, SizeOf(Ev), 0);
    Ev.xclient._type := ClientMessage;
    Ev.xclient.window := DefaultRootWindow(Dpy);
    Ev.xclient.message_type := XInternAtom(Dpy, '_TIECOMP_CUBE', False);
    Ev.xclient.format := 32;
    XSendEvent(Dpy, DefaultRootWindow(Dpy), False, SubstructureRedirectMask or SubstructureNotifyMask, @Ev);
  end;
  XSync(Dpy, False);
  WriteLn('ready');
  Flush(Output);
  while True do
  begin
    XNextEvent(Dpy, @Ev);
    if (Ev._type <> ClientMessage) or (Ev.xclient.message_type <> Move) then Continue;
    WriteLn(Format('move frame=0x%x start=%d grab=%d,%d',
      [Ev.xclient.data.l[0], Ev.xclient.data.l[1], Ev.xclient.data.l[2], Ev.xclient.data.l[3]]));
    Flush(Output);
  end;
end.
