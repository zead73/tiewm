program hintrecv;

{ Plays the compositor for tiewm's hint tests: owns _TIECOMP_S0 and prints
  every _TIECOMP_MOVE message it is sent. Runs until killed. }

{$mode objfpc}{$H+}

uses
  SysUtils, x, xlib;

var
  Dpy: PDisplay;
  Win: TWindow;
  Move: TAtom;
  Ev: TXEvent;
begin
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then Halt(1);
  Win := XCreateSimpleWindow(Dpy, DefaultRootWindow(Dpy), -10, -10, 1, 1, 0, 0, 0);
  Move := XInternAtom(Dpy, '_TIECOMP_MOVE', False);
  XSetSelectionOwner(Dpy, XInternAtom(Dpy, '_TIECOMP_S0', False), Win, CurrentTime);
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
