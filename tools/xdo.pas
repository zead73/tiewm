program xdo;

{ Fake pointer/keyboard input through the XTest extension, for testing the WM.
  Commands are given as arguments, run in order:
    move X Y | down B | up B | click B | drag X1 Y1 X2 Y2 [B]
    key NAME | keydown NAME | keyup NAME   (X keysym names, e.g. Alt_L, Num_Lock)
    sleep MS
  Always run with DISPLAY set explicitly. }

{$mode objfpc}{$H+}

uses
  SysUtils, BaseUnix, ctypes, x, xlib, keysym;

function XTestFakeMotionEvent(dpy: PDisplay; Screen, XPos, YPos: cint; Delay: culong): cint; cdecl;
  external 'Xtst' name 'XTestFakeMotionEvent';
function XTestFakeButtonEvent(dpy: PDisplay; Button: cuint; IsPress: cint; Delay: culong): cint; cdecl;
  external 'Xtst' name 'XTestFakeButtonEvent';
function XTestFakeKeyEvent(dpy: PDisplay; Keycode: cuint; IsPress: cint; Delay: culong): cint; cdecl;
  external 'Xtst' name 'XTestFakeKeyEvent';

var
  Dpy: PDisplay;
  I, N: Integer;

procedure Flush;
begin
  XSync(Dpy, 0);
  Sleep(30);
end;

procedure DoMove(AX, AY: Integer);
begin
  XTestFakeMotionEvent(Dpy, -1, AX, AY, 0);
  Flush;
end;

procedure DoKey(const Name: string; Press: Boolean);
var
  Ks: TKeySym;
  Kc: cuint;
begin
  Ks := XStringToKeysym(PChar(Name));
  if Ks = 0 then begin WriteLn('unknown keysym ', Name); Halt(2); end;
  Kc := XKeysymToKeycode(Dpy, Ks);
  if Kc = 0 then begin WriteLn('no keycode for ', Name); Halt(2); end;
  XTestFakeKeyEvent(Dpy, Kc, Ord(Press), 0);
  Flush;
end;

function Arg(K: Integer): string;
begin
  if K > ParamCount then begin WriteLn('missing argument'); Halt(2); end;
  Result := ParamStr(K);
end;

var
  Cmd: string;
  X1, Y1, X2, Y2, B, Step: Integer;
begin
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then begin WriteLn('no display'); Halt(1); end;
  I := 1;
  N := ParamCount;
  while I <= N do
  begin
    Cmd := ParamStr(I);
    Inc(I);
    if Cmd = 'move' then begin DoMove(StrToInt(Arg(I)), StrToInt(Arg(I + 1))); Inc(I, 2); end
    else if Cmd = 'down' then begin XTestFakeButtonEvent(Dpy, StrToInt(Arg(I)), 1, 0); Flush; Inc(I); end
    else if Cmd = 'up' then begin XTestFakeButtonEvent(Dpy, StrToInt(Arg(I)), 0, 0); Flush; Inc(I); end
    else if Cmd = 'click' then
    begin
      B := StrToInt(Arg(I)); Inc(I);
      XTestFakeButtonEvent(Dpy, B, 1, 0); Flush;
      XTestFakeButtonEvent(Dpy, B, 0, 0); Flush;
    end
    else if Cmd = 'drag' then
    begin
      X1 := StrToInt(Arg(I)); Y1 := StrToInt(Arg(I + 1));
      X2 := StrToInt(Arg(I + 2)); Y2 := StrToInt(Arg(I + 3));
      Inc(I, 4);
      B := 1;
      if (I <= N) and (StrToIntDef(ParamStr(I), -1) in [1..5]) and
         ((I = N) or (StrToIntDef(ParamStr(I + 1), -1) < 0)) then
      begin
        B := StrToInt(ParamStr(I)); Inc(I);
      end;
      DoMove(X1, Y1);
      XTestFakeButtonEvent(Dpy, B, 1, 0); Flush;
      for Step := 1 to 8 do
        DoMove(X1 + (X2 - X1) * Step div 8, Y1 + (Y2 - Y1) * Step div 8);
      XTestFakeButtonEvent(Dpy, B, 0, 0); Flush;
    end
    else if Cmd = 'key' then begin DoKey(Arg(I), True); DoKey(Arg(I), False); Inc(I); end
    else if Cmd = 'keydown' then begin DoKey(Arg(I), True); Inc(I); end
    else if Cmd = 'keyup' then begin DoKey(Arg(I), False); Inc(I); end
    else if Cmd = 'sleep' then begin Sleep(StrToInt(Arg(I))); Inc(I); end
    else begin WriteLn('unknown command ', Cmd); Halt(2); end;
  end;
  XCloseDisplay(Dpy);
end.
