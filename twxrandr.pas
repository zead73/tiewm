unit twxrandr;

{ Minimal binding to libXrandr: the monitor list (RandR 1.5) and the screen
  change notification. FPC ships no XRandR unit. }

{$mode objfpc}{$H+}

interface

uses
  ctypes, x, xlib;

const
  RRScreenChangeNotify = 0;          { added to the extension's event base }
  RRNotify = 1;                      { crtc / output changes: also added to the event base }
  RRScreenChangeNotifyMask = 1;
  RRCrtcChangeNotifyMask = 2;
  RROutputChangeNotifyMask = 4;

type
  PRROutput = ^culong;
  PXRRMonitorInfo = ^TXRRMonitorInfo;
  TXRRMonitorInfo = record
    name: TAtom;
    primary: cint;
    automatic: cint;
    noutput: cint;
    x, y, width, height, mwidth, mheight: cint;
    outputs: PRROutput;
  end;

  { the event is only used to refresh Xlib's idea of the screen size }
  TXRRScreenChangeNotifyEvent = record
    _type: cint;
    serial: culong;
    send_event: cint;
    display: PDisplay;
    window, root: TWindow;
    timestamp, config_timestamp: TTime;
    size_index: cushort;
    subpixel_order: cushort;
    rotation: cushort;
    width, height, mwidth, mheight: cint;
  end;

function XRRQueryExtension(dpy: PDisplay; EventBase, ErrorBase: pcint): cint; cdecl;
  external 'Xrandr' name 'XRRQueryExtension';
procedure XRRSelectInput(dpy: PDisplay; Win: TWindow; Mask: cint); cdecl;
  external 'Xrandr' name 'XRRSelectInput';
function XRRUpdateConfiguration(Ev: PXEvent): cint; cdecl;
  external 'Xrandr' name 'XRRUpdateConfiguration';
function XRRGetMonitors(dpy: PDisplay; Win: TWindow; GetActive: cint; NMonitors: pcint): PXRRMonitorInfo; cdecl;
  external 'Xrandr' name 'XRRGetMonitors';
procedure XRRFreeMonitors(Monitors: PXRRMonitorInfo); cdecl; external 'Xrandr' name 'XRRFreeMonitors';
function XRRAllocateMonitor(dpy: PDisplay; NOutput: cint): PXRRMonitorInfo; cdecl;
  external 'Xrandr' name 'XRRAllocateMonitor';
procedure XRRSetMonitor(dpy: PDisplay; Win: TWindow; Monitor: PXRRMonitorInfo); cdecl;
  external 'Xrandr' name 'XRRSetMonitor';
procedure XRRDeleteMonitor(dpy: PDisplay; Win: TWindow; Name: TAtom); cdecl;
  external 'Xrandr' name 'XRRDeleteMonitor';

type
  TMonitor = record
    X, Y, W, H: Integer;
    Primary: Boolean;
    Auto: Boolean;     { made up by the server for an output, not defined by a client }
  end;
  TMonitorList = array of TMonitor;

{ True if the server has RandR; EventBase is where RRScreenChangeNotify arrives }
function HaveRandR(dpy: PDisplay; out EventBase: Integer): Boolean;
{ The active monitors, left to right. Empty if the query fails. }
function QueryMonitors(dpy: PDisplay; Root: TWindow): TMonitorList;

implementation

function HaveRandR(dpy: PDisplay; out EventBase: Integer): Boolean;
var
  Ev, Er: cint;
begin
  Ev := 0;
  Result := XRRQueryExtension(dpy, @Ev, @Er) <> 0;
  EventBase := Ev;
end;

function QueryMonitors(dpy: PDisplay; Root: TWindow): TMonitorList;
var
  P, Q: PXRRMonitorInfo;
  N, I, J, K: cint;
  T: TMonitor;
begin
  SetLength(Result, 0);
  N := 0;
  P := XRRGetMonitors(dpy, Root, 1, @N);
  if P = nil then Exit;
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    Q := P + I;
    Result[I].X := Q^.x; Result[I].Y := Q^.y; Result[I].W := Q^.width; Result[I].H := Q^.height;
    Result[I].Primary := Q^.primary <> 0;
    Result[I].Auto := Q^.automatic <> 0;
  end;
  XRRFreeMonitors(P);
  { monitors a client defined replace the automatic per-output ones }
  K := 0;
  for I := 0 to High(Result) do if not Result[I].Auto then Inc(K);
  if K > 0 then
  begin
    K := 0;
    for I := 0 to High(Result) do
      if not Result[I].Auto then begin Result[K] := Result[I]; Inc(K); end;
    SetLength(Result, K);
  end;
  { left to right, then top to bottom: a stable order for "monitor 1, 2..." }
  for I := 1 to High(Result) do
  begin
    T := Result[I];
    J := I - 1;
    while (J >= 0) and ((Result[J].X > T.X) or ((Result[J].X = T.X) and (Result[J].Y > T.Y))) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := T;
  end;
end;

end.
