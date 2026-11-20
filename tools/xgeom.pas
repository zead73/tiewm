program xgeom;

{ Dumps the children of the root window (or of the window given as argument)
  with geometry, map state, name and child count, one line per window.
  Positions are what XGetGeometry says, i.e. relative to the parent. For a
  root-relative position use "xgeom abs <winid>". }

{$mode objfpc}{$H+}

uses
  SysUtils, ctypes, x, xlib;

var
  Dpy: PDisplay;
  Root, Par, Win: TWindow;
  Kids: PWindow;
  NKids: cuint;
  I: Integer;
  Atr: TXWindowAttributes;
  Nm: PChar;
  Rx, Ry: cint;
  Ch: TWindow;
  Top: Boolean;

procedure Describe(W: TWindow; Indent: string);
var
  K: PWindow;
  N: cuint;
  R, P: TWindow;
  A: TXWindowAttributes;
  Name: PChar;
  S: string;
  J: Integer;
begin
  if XGetWindowAttributes(Dpy, W, @A) = 0 then Exit;
  Name := nil;
  XFetchName(Dpy, W, @Name);
  S := '';
  if Name <> nil then begin S := Name; XFree(Name); end;
  WriteLn(Format('%swin=0x%x x=%d y=%d w=%d h=%d viewable=%d override=%d name="%s"',
    [Indent, W, A.x, A.y, A.width, A.height, Ord(A.map_state = IsViewable),
     Ord(A.override_redirect <> 0), S]));
  if XQueryTree(Dpy, W, @R, @P, @K, @N) <> 0 then
  begin
    if Indent = '' then
      for J := 0 to Integer(N) - 1 do
        Describe(K[J], '  ');
    if K <> nil then XFree(K);
  end;
end;

begin
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then begin WriteLn('no display'); Halt(1); end;
  Root := DefaultRootWindow(Dpy);
  if (ParamCount >= 2) and (ParamStr(1) = 'abs') then
  begin
    Win := StrToQWord(ParamStr(2));
    XTranslateCoordinates(Dpy, Win, Root, 0, 0, @Rx, @Ry, @Ch);
    XGetWindowAttributes(Dpy, Win, @Atr);
    WriteLn(Format('abs x=%d y=%d w=%d h=%d', [Rx, Ry, Atr.width, Atr.height]));
  end
  else
  begin
    if XQueryTree(Dpy, Root, @Par, @Par, @Kids, @NKids) <> 0 then
    begin
      for I := 0 to Integer(NKids) - 1 do Describe(Kids[I], '');
      if Kids <> nil then XFree(Kids);
    end;
  end;
  XCloseDisplay(Dpy);
end.
