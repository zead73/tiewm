program testwin;

{ Small X client for WM testing: one solid-colour window that logs what the
  WM does to it (one line per event on stdout).
    testwin [-t title] [-w width] [-h height] [-c rrggbb] [-s seconds]
            [-m minw,minh] [-p x,y]   program-specified position (USPosition)
            [-T newtitle,afterseconds]  change the title later
            [-y desktop|dock|dockbelow]  set _NET_WM_WINDOW_TYPE (dockbelow also sets STATE_BELOW)
            [-P 0xID]                 mark as transient for that window
            [-i seconds]              iconify itself (XIconifyWindow) after N seconds
            [-n]                      ignore WM_DELETE_WINDOW (do not advertise it)
  Defaults: "testwin" 300x200 ff00ff, runs 30 s. Exits 0 on WM_DELETE_WINDOW. }

{$mode objfpc}{$H+}

uses
  SysUtils, BaseUnix, ctypes, x, xlib, xutil, xatom;

var
  Dpy: PDisplay;
  Win: TWindow;
  Ev: TXEvent;
  Title, NewTitle: string;
  W, H, Secs, MinW, MinH, PosX, PosY, ChangeAfter, IconifyAfter: Integer;
  ParentId: QWord;
  Iconified: Boolean;
  WinType: string;
  AType, ATypeDock, AState, ABelow: TAtom;
  Col: LongWord;
  HavePos, NoDelete: Boolean;
  Hints: TXSizeHints;
  WmDelete, WmProtocols: TAtom;
  T0, Now_: Int64;
  Changed: Boolean;
  I: Integer;
  S, Opt: string;
  P: Integer;

procedure Say(const Msg: string);
begin
  WriteLn(Msg);
  Flush(Output);
end;

begin
  Title := 'testwin'; W := 300; H := 200; Col := $FF00FF; Secs := 30;
  MinW := 0; MinH := 0; HavePos := False; NoDelete := False; NewTitle := ''; ChangeAfter := 0;
  IconifyAfter := -1; ParentId := 0; Iconified := False; WinType := '';
  I := 1;
  while I <= ParamCount do
  begin
    Opt := ParamStr(I);
    if Opt = '-n' then NoDelete := True
    else if I < ParamCount then
    begin
      S := ParamStr(I + 1);
      if Opt = '-t' then Title := S
      else if Opt = '-w' then W := StrToInt(S)
      else if Opt = '-h' then H := StrToInt(S)
      else if Opt = '-c' then Col := LongWord(StrToInt('$' + S))
      else if Opt = '-s' then Secs := StrToInt(S)
      else if Opt = '-m' then
      begin
        P := Pos(',', S); MinW := StrToInt(Copy(S, 1, P - 1)); MinH := StrToInt(Copy(S, P + 1, 99));
      end
      else if Opt = '-p' then
      begin
        P := Pos(',', S); PosX := StrToInt(Copy(S, 1, P - 1)); PosY := StrToInt(Copy(S, P + 1, 99));
        HavePos := True;
      end
      else if Opt = '-y' then WinType := S
      else if Opt = '-P' then ParentId := StrToQWord(S)
      else if Opt = '-i' then IconifyAfter := StrToInt(S)
      else if Opt = '-T' then
      begin
        P := Pos(',', S); NewTitle := Copy(S, 1, P - 1); ChangeAfter := StrToInt(Copy(S, P + 1, 99));
      end
      else begin WriteLn('unknown option ', Opt); Halt(2); end;
      Inc(I);
    end;
    Inc(I);
  end;
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then begin WriteLn('cannot open display'); Halt(1); end;
  Win := XCreateSimpleWindow(Dpy, DefaultRootWindow(Dpy), 0, 0, W, H, 0, 0, Col);
  XStoreName(Dpy, Win, PChar(Title));
  FillChar(Hints, SizeOf(Hints), 0);
  if (MinW > 0) or HavePos then
  begin
    if MinW > 0 then begin Hints.flags := Hints.flags or PMinSize; Hints.min_width := MinW; Hints.min_height := MinH; end;
    if HavePos then begin Hints.flags := Hints.flags or USPosition; Hints.x := PosX; Hints.y := PosY; end;
    XSetWMNormalHints(Dpy, Win, @Hints);
  end;
  if HavePos then XMoveWindow(Dpy, Win, PosX, PosY);
  WmDelete := XInternAtom(Dpy, 'WM_DELETE_WINDOW', 0);
  WmProtocols := XInternAtom(Dpy, 'WM_PROTOCOLS', 0);
  if not NoDelete then XSetWMProtocols(Dpy, Win, @WmDelete, 1);
  if ParentId <> 0 then XSetTransientForHint(Dpy, Win, ParentId);
  if WinType <> '' then
  begin
    AType := XInternAtom(Dpy, '_NET_WM_WINDOW_TYPE', 0);
    if WinType = 'desktop' then ATypeDock := XInternAtom(Dpy, '_NET_WM_WINDOW_TYPE_DESKTOP', 0)
    else ATypeDock := XInternAtom(Dpy, '_NET_WM_WINDOW_TYPE_DOCK', 0);
    XChangeProperty(Dpy, Win, AType, XA_ATOM, 32, PropModeReplace, PByte(@ATypeDock), 1);
    if WinType = 'dockbelow' then
    begin
      AState := XInternAtom(Dpy, '_NET_WM_STATE', 0);
      ABelow := XInternAtom(Dpy, '_NET_WM_STATE_BELOW', 0);
      XChangeProperty(Dpy, Win, AState, XA_ATOM, 32, PropModeReplace, PByte(@ABelow), 1);
    end;
  end;
  XSelectInput(Dpy, Win, StructureNotifyMask or ButtonPressMask or FocusChangeMask or ExposureMask or KeyPressMask);
  XMapWindow(Dpy, Win);
  XFlush(Dpy);
  Say(Format('mapped id=0x%x', [Win]));
  T0 := FpTime;
  Changed := False;
  while True do
  begin
    Now_ := FpTime;
    if Now_ - T0 >= Secs then Break;
    if (NewTitle <> '') and (not Changed) and (Now_ - T0 >= ChangeAfter) then
    begin
      XStoreName(Dpy, Win, PChar(NewTitle));
      XFlush(Dpy);
      Changed := True;
      Say('title changed to ' + NewTitle);
    end;
    if (IconifyAfter >= 0) and (not Iconified) and (Now_ - T0 >= IconifyAfter) then
    begin
      XIconifyWindow(Dpy, Win, DefaultScreen(Dpy));
      XFlush(Dpy);
      Iconified := True;
      Say('iconify requested');
    end;
    while XPending(Dpy) > 0 do
    begin
      XNextEvent(Dpy, @Ev);
      case Ev._type of
        ConfigureNotify:
          Say(Format('ConfigureNotify x=%d y=%d w=%d h=%d synthetic=%d',
            [Ev.xconfigure.x, Ev.xconfigure.y, Ev.xconfigure.width, Ev.xconfigure.height,
             Ord(Ev.xconfigure.send_event <> 0)]));
        ButtonPress:
          Say(Format('ButtonPress x=%d y=%d button=%d', [Ev.xbutton.x, Ev.xbutton.y, Ev.xbutton.button]));
        MapNotify: Say('MapNotify');
        UnmapNotify: Say('UnmapNotify');
        FocusIn: Say('FocusIn');
        FocusOut: Say('FocusOut');
        KeyPress: Say('KeyPress');
        ClientMessage:
          if (Ev.xclient.message_type = WmProtocols) and (TAtom(Ev.xclient.data.l[0]) = WmDelete) then
          begin
            Say('WM_DELETE_WINDOW');
            XDestroyWindow(Dpy, Win);
            XCloseDisplay(Dpy);
            Halt(0);
          end;
      end;
    end;
    Sleep(40);
  end;
  Say('timeout');
  XCloseDisplay(Dpy);
end.
