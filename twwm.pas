unit twwm;

{ The window manager proper: manages top-level windows, frames them with
  xfwm4 theme graphics (twtheme/twxdraw), click-to-focus, move/resize by
  mouse, close/maximize buttons, and a minimal EWMH layer.

  Vertical slice, deliberately incomplete: no workspaces, no iconify/shade,
  no key bindings, no Alt+Tab, no multi-monitor. }

{$mode objfpc}{$H+}

interface

uses
  ctypes, SysUtils, StrUtils, Classes, BaseUnix, x, xlib, xutil, xatom, cursorfont, keysym,
  twimage, twtheme, twxft, twxdraw, twxshape, twconfig, twlog, twmenu;

type
  TClient = class
    Win, Frame: TWindow;
    X, Y, W, H: Integer;          { frame outer geometry, root relative }
    Name: string;
    IgnoreUnmap: Integer;         { unmaps we caused ourselves }
    InputHint, HasDelete, HasTakeFocus: Boolean;
    MinW, MinH, MaxW, MaxH, IncW, IncH, BaseW, BaseH: Integer;   { client sizes }
    Maximized, Fullscreen, Iconic, Above, Below, Shaded: Boolean;
    Decorated: Boolean;           { False: no frame graphics at all (the app draws its own) }
    UnshadeH: Integer;            { frame height to return to when unshaded }
    Desktop: Integer;             { 0..N-1, or -1 = sticky (all desktops) }
    Transient: TWindow;           { WM_TRANSIENT_FOR, 0 if none }
    SaveX, SaveY, SaveW, SaveH: Integer;   { geometry to return to from maximize/fullscreen }
    PaintedActive: Boolean;
    PaintedW, PaintedH: Integer;
    PaintedName: string;
    Painted: Boolean;
    Pixmap: TPixmap;
  end;

  TDock = record
    Win: TWindow;
    Left, Right, Top, Bottom: Integer;
    Below: Boolean;      { _NET_WM_STATE_BELOW, e.g. conky: stays under normal windows }
  end;

  TExt = record
    L, R, T, B: Integer;
  end;

  TDragKind = (dgNone, dgMove, dgResize);
  TKbMode = (kmNone, kmMove, kmResize);

  { TWM }

  TWM = class
  private
    FDpy: PDisplay;
    FScr: Integer;
    FRoot: TWindow;
    FScrW, FScrH: Integer;
    FTheme: TXfwmTheme;
    FFont: TTitleFont;
    FOpts: TFrameOpts;
    FClients: TList;       { creation order }
    FMru: TList;           { most recently focused last }
    FDocks: array of TDock;
    FNumDesk, FCurDesk: Integer;
    FDesktops: array of TWindow;   { _NET_WM_WINDOW_TYPE_DESKTOP windows: always at the bottom }
    FFocused: TClient;
    FCheckWin: TWindow;
    FQuit: Boolean;
    FDebug: Boolean;
    { atoms }
    aProtocols, aDelete, aTakeFocus, aWmState, aChangeState, aUtf8: TAtom;
    aSupported, aNetWmName, aActive, aClientList, aClientListStk, aFrameExtents: TAtom;
    aNetWmState, aMaxVert, aMaxHorz, aCloseWindow, aWindowType: TAtom;
    aTypeDock, aTypeDesktop, aTypeMenu, aTypeDropdown, aTypePopup, aTypeTooltip, aTypeNotification, aTypeCombo, aTypeDnd: TAtom;
    aHidden, aFullscreen, aWmDesktop, aBelow, aAbove, aShaded, aSticky, aDeskNames, aMotif: TAtom;
    aStrut, aStrutPartial, aNumDesktops, aCurDesktop, aWorkarea, aDeskGeom, aDeskViewport, aSupportingCheck: TAtom;
    { drag state }
    FDrag: TDragKind;
    FDragClient: TClient;
    FDragHit: THitKind;
    FDragPX, FDragPY, FDragX, FDragY, FDragW, FDragH: Integer;
    FCfg: TConfig;
    FKbMode: TKbMode;
    FKbClient: TClient;
    FKbX, FKbY, FKbW, FKbH: Integer;
    FMenu: TPopupMenu;
    FMenuFont: TTitleFont;
    FMenuClient: TClient;
    FCycleMods: cuint;
    FReload: Boolean;
    FCycling: Boolean;
    FCycleList: TList;
    FCycleIdx: Integer;
    FPressClient: TClient;
    FPressLetter: Char;
    FLastClickTime: culong;
    FLastClickWin: TWindow;
    FCursors: array[THitKind] of TCursor;
    FMoveCursor, FArrowCursor: TCursor;
    procedure Log(const Msg: string);
    procedure InternAtoms;
    procedure SetupEwmh;
    procedure SetCards(Win: TWindow; Prop: TAtom; const V: array of culong);
    procedure SetWins(Win: TWindow; Prop: TAtom; const V: array of TWindow);
    function GetProp(Win: TWindow; Prop, ReqType: TAtom; out N: culong): PByte;
    function GetAtoms(Win: TWindow; Prop: TAtom): TList;
    function ReadName(Win: TWindow): string;
    procedure ReadHints(C: TClient);
    function WindowTypeIs(Win: TWindow; T: TAtom): Boolean;
    function IsUnframed(Win: TWindow): Boolean;
    function HasState(Win: TWindow; St: TAtom): Boolean;
    procedure Restack;
    function OnDesk(C: TClient): Boolean;
    function VisibleNow(C: TClient): Boolean;
    procedure ApplyVisibility(C: TClient);
    procedure SwitchDesktop(N: Integer; ATime: culong);
    procedure MoveToDesktop(C: TClient; D: Integer);
    procedure SetDesktopProp(C: TClient);
    function ReadDesktopProp(Win: TWindow): Integer;
    procedure ReadStruts(var D: TDock);
    procedure UpdateWorkarea;
    procedure WorkArea(out AX, AY, AW, AH: Integer);
    function FindClient(Win: TWindow): TClient;
    function FindFrame(Frame: TWindow): TClient;
    procedure Manage(Win: TWindow; Startup: Boolean);
    procedure Unmanage(C: TClient; Destroyed: Boolean);
    procedure ScanExisting;
    procedure Repaint(C: TClient; Force: Boolean);
    procedure SetFrameGeometry(C: TClient; NX, NY, NW, NH: Integer);
    procedure SendConfigure(C: TClient);
    function Ext(C: TClient): TExt;
    procedure ClientSizeOf(C: TClient; out CW, CH: Integer);
    procedure ConstrainClient(C: TClient; var CW, CH: Integer);
    procedure FocusClient(C: TClient; ATime: culong);
    procedure RaiseClient(C: TClient);
    procedure CloseClient(C: TClient);
    procedure ToggleMaximize(C: TClient);
    procedure SetFullscreen(C: TClient; On: Boolean);
    procedure SetAbove(C: TClient; On: Boolean);
    procedure SetBelow(C: TClient; On: Boolean);
    procedure SetShaded(C: TClient; On: Boolean);
    function WantsDecorations(Win: TWindow): Boolean;
    procedure SetDecorated(C: TClient; On: Boolean);
    function OptsFor(C: TClient): TFrameOpts;
    procedure StartKb(Mode: TKbMode; ATime: culong);
    procedure EndKb(Commit: Boolean);
    procedure KbKey(var Ev: TXKeyEvent);
    procedure Iconify(C: TClient);
    procedure Deiconify(C: TClient);
    procedure FocusNext(Exclude: TClient);
    procedure Activate(C: TClient; ATime: culong);
    procedure RaiseTransients(C: TClient; Depth: Integer);
    procedure SetFrameExtentsProp(C: TClient);
    procedure OpenWindowMenu(C: TClient; X, Y: Integer; ATime: culong);
    procedure RunMenuAction(Id: Integer);
    procedure GrabKeys;
    function FindBinding(Kc, St: cuint): Integer;
    procedure RunAction(const B: TKeyBinding; ATime: culong);
    procedure MoveFocusedTo(K: Integer; ATime: culong);
    function TitleAlign: TTitleAlign;
    procedure OnKeyPress(var Ev: TXKeyEvent);
    procedure OnKeyRelease(var Ev: TXKeyEvent);
    procedure StartCycle(Dir: Integer; ATime: culong; Mods: cuint);
    procedure StepCycle(Dir: Integer);
    procedure EndCycle;
    procedure UpdateClientList;
    procedure SetWmState(C: TClient; State: Integer);
    procedure UpdateNetState(C: TClient);
    procedure Place(C: TClient; HasPos: Boolean; CX, CY: Integer);
    procedure BeginDrag(C: TClient; Kind: TDragKind; Hit: THitKind; XRoot, YRoot: Integer; ATime: culong);
    procedure EndDrag;
    procedure DoMotion(XRoot, YRoot: Integer);
    procedure HandleEvent(var Ev: TXEvent);
    procedure OnMapRequest(var Ev: TXMapRequestEvent);
    procedure OnConfigureRequest(var Ev: TXConfigureRequestEvent);
    procedure OnUnmap(var Ev: TXUnmapEvent);
    procedure OnDestroy(var Ev: TXDestroyWindowEvent);
    procedure OnButtonPress(var Ev: TXButtonEvent);
    procedure OnButtonRelease(var Ev: TXButtonEvent);
    procedure OnMotion(var Ev: TXMotionEvent);
    procedure OnClientMessage(var Ev: TXClientMessageEvent);
    procedure OnProperty(var Ev: TXPropertyEvent);
    procedure DefineHitCursor(C: TClient; XF, YF: Integer);
  public
    constructor Create(ADpy: PDisplay; const ACfg: TConfig);
    destructor Destroy; override;
    { selects the root events; False if another WM already owns them }
    function Claim: Boolean;
    procedure Run;
    procedure Shutdown;
    { SIGHUP: re-read the key bindings from the config file }
    procedure RequestReload;
    property Quit: Boolean read FQuit write FQuit;
  end;

var
  GBadAccess: Boolean;

implementation

const
  SubstructureMasks = SubstructureRedirectMask or SubstructureNotifyMask;
  CleanLocks = LockMask or Mod2Mask;   { Caps Lock, Num Lock }
  DoubleClickMs = 400;

{ ---- error handlers ---- }

function StartupErrorHandler(Dpy: PDisplay; Err: PXErrorEvent): cint; cdecl;
begin
  if Err^.error_code = BadAccess then GBadAccess := True;
  Result := 0;
end;

function TolerantErrorHandler(Dpy: PDisplay; Err: PXErrorEvent): cint; cdecl;
begin
  { clients vanish asynchronously; BadWindow & friends are normal }
  LogDebug(Format('X error code=%d request=%d resource=0x%s', [Err^.error_code, Err^.request_code, IntToHex(Err^.resourceid, 1)]));
  Result := 0;
end;

{ ---- TWM ---- }

constructor TWM.Create(ADpy: PDisplay; const ACfg: TConfig);
var
  MC: TMenuColors;
begin
  inherited Create;
  FCfg := ACfg;
  FDpy := ADpy;
  FScr := DefaultScreen(FDpy);
  FRoot := DefaultRootWindow(FDpy);
  FScrW := DisplayWidth(FDpy, FScr);
  FScrH := DisplayHeight(FDpy, FScr);
  FDebug := GetEnvironmentVariable('TIEWM_DEBUG') <> '';
  FNumDesk := FCfg.NumDesktops;
  if FNumDesk < 1 then FNumDesk := 1;
  if FNumDesk > 20 then FNumDesk := 20;
  FCurDesk := 0;
  FClients := TList.Create;
  FMru := TList.Create;
  FCycleList := TList.Create;
  TitleFontGrey := FCfg.FontGreyscale;
  TitleFontHint := FCfg.FontHinting;
  InactiveTextColor := FCfg.InactiveText;
  FTheme := TXfwmTheme.Create;
  { a wrong theme name must not take the session down: fall back }
  if not FTheme.Load(FCfg.Theme, FCfg.Palette) then
  begin
    LogInfo('xfwm4 theme "' + FCfg.Theme + '" not found, using Daloa');
    WriteLn(StdErr, 'tiewm: xfwm4 theme "', FCfg.Theme, '" not found, using Daloa');
    Flush(StdErr);
    if not FTheme.Load('Daloa', FCfg.Palette) then
      raise Exception.Create('xfwm4 theme not found: ' + FCfg.Theme + ' (and no Daloa to fall back to)');
  end;
  FFont := TTitleFont.Create(FDpy, FScr, FCfg.TitleFont);
  FMenuFont := TTitleFont.Create(FDpy, FScr, FCfg.MenuFont);
  MC.Back := $2D2D2D;
  MC.Border := FCfg.Palette.Color1[wsActive] and $FFFFFF;
  MC.Text := $E6E6E6;
  MC.Disabled := $8A8A8A;
  MC.HoverBack := MC.Border;
  MC.HoverText := $FFFFFF;
  FMenu := TPopupMenu.Create(FDpy, FScr, FMenuFont, MC);
  FOpts := DefaultFrameOpts(FTheme);
  FOpts.Layout := FCfg.ButtonLayout;
  InternAtoms;
end;

function TWM.TitleAlign: TTitleAlign;
begin
  if FCfg.TitleAlign = 'center' then Result := taCenter
  else if FCfg.TitleAlign = 'right' then Result := taRight
  else Result := taLeft;
end;

procedure TWM.RequestReload;
begin
  FReload := True;
end;

destructor TWM.Destroy;
begin
  FMenu.Free;
  FMenuFont.Free;
  FFont.Free;
  FTheme.Free;
  FClients.Free;
  FMru.Free;
  FCycleList.Free;
  inherited Destroy;
end;

procedure TWM.Log(const Msg: string);
begin
  LogInfo(Msg);
end;

procedure TWM.InternAtoms;
  function A(const N: string): TAtom;
  begin
    Result := XInternAtom(FDpy, PChar(N), 0);
  end;
begin
  aProtocols := A('WM_PROTOCOLS'); aDelete := A('WM_DELETE_WINDOW'); aTakeFocus := A('WM_TAKE_FOCUS');
  aWmState := A('WM_STATE'); aChangeState := A('WM_CHANGE_STATE'); aUtf8 := A('UTF8_STRING');
  aSupported := A('_NET_SUPPORTED'); aNetWmName := A('_NET_WM_NAME'); aActive := A('_NET_ACTIVE_WINDOW');
  aClientList := A('_NET_CLIENT_LIST'); aClientListStk := A('_NET_CLIENT_LIST_STACKING');
  aFrameExtents := A('_NET_FRAME_EXTENTS'); aNetWmState := A('_NET_WM_STATE');
  aMaxVert := A('_NET_WM_STATE_MAXIMIZED_VERT'); aMaxHorz := A('_NET_WM_STATE_MAXIMIZED_HORZ');
  aCloseWindow := A('_NET_CLOSE_WINDOW'); aWindowType := A('_NET_WM_WINDOW_TYPE');
  aTypeDock := A('_NET_WM_WINDOW_TYPE_DOCK'); aTypeDesktop := A('_NET_WM_WINDOW_TYPE_DESKTOP');
  aTypeMenu := A('_NET_WM_WINDOW_TYPE_MENU'); aTypeDropdown := A('_NET_WM_WINDOW_TYPE_DROPDOWN_MENU');
  aTypePopup := A('_NET_WM_WINDOW_TYPE_POPUP_MENU'); aTypeTooltip := A('_NET_WM_WINDOW_TYPE_TOOLTIP');
  aTypeNotification := A('_NET_WM_WINDOW_TYPE_NOTIFICATION'); aTypeCombo := A('_NET_WM_WINDOW_TYPE_COMBO');
  aTypeDnd := A('_NET_WM_WINDOW_TYPE_DND');
  aHidden := A('_NET_WM_STATE_HIDDEN'); aFullscreen := A('_NET_WM_STATE_FULLSCREEN');
  aWmDesktop := A('_NET_WM_DESKTOP');
  aBelow := A('_NET_WM_STATE_BELOW');
  aAbove := A('_NET_WM_STATE_ABOVE');
  aShaded := A('_NET_WM_STATE_SHADED');
  aMotif := A('_MOTIF_WM_HINTS');
  aSticky := A('_NET_WM_STATE_STICKY');
  aDeskNames := A('_NET_DESKTOP_NAMES');
  aStrut := A('_NET_WM_STRUT'); aStrutPartial := A('_NET_WM_STRUT_PARTIAL');
  aNumDesktops := A('_NET_NUMBER_OF_DESKTOPS'); aCurDesktop := A('_NET_CURRENT_DESKTOP');
  aWorkarea := A('_NET_WORKAREA'); aDeskGeom := A('_NET_DESKTOP_GEOMETRY');
  aDeskViewport := A('_NET_DESKTOP_VIEWPORT'); aSupportingCheck := A('_NET_SUPPORTING_WM_CHECK');
end;

function TWM.Claim: Boolean;
var
  H: THitKind;
begin
  GBadAccess := False;
  XSetErrorHandler(@StartupErrorHandler);
  XSelectInput(FDpy, FRoot, SubstructureMasks or PropertyChangeMask or ButtonPressMask);
  XSync(FDpy, 0);
  if GBadAccess then Exit(False);
  XSetErrorHandler(@TolerantErrorHandler);
  { cursors }
  FArrowCursor := XCreateFontCursor(FDpy, XC_left_ptr);
  FMoveCursor := XCreateFontCursor(FDpy, XC_fleur);
  for H := Low(THitKind) to High(THitKind) do FCursors[H] := FArrowCursor;
  FCursors[hkN] := XCreateFontCursor(FDpy, XC_top_side);
  FCursors[hkS] := XCreateFontCursor(FDpy, XC_bottom_side);
  FCursors[hkE] := XCreateFontCursor(FDpy, XC_right_side);
  FCursors[hkW] := XCreateFontCursor(FDpy, XC_left_side);
  FCursors[hkNW] := XCreateFontCursor(FDpy, XC_top_left_corner);
  FCursors[hkNE] := XCreateFontCursor(FDpy, XC_top_right_corner);
  FCursors[hkSW] := XCreateFontCursor(FDpy, XC_bottom_left_corner);
  FCursors[hkSE] := XCreateFontCursor(FDpy, XC_bottom_right_corner);
  XDefineCursor(FDpy, FRoot, FArrowCursor);
  SetupEwmh;
  GrabKeys;
  Result := True;
end;

{ ---- property helpers ---- }

procedure TWM.SetCards(Win: TWindow; Prop: TAtom; const V: array of culong);
begin
  if Length(V) = 0 then
    XDeleteProperty(FDpy, Win, Prop)
  else
    XChangeProperty(FDpy, Win, Prop, XA_CARDINAL, 32, PropModeReplace, PByte(@V[0]), Length(V));
end;

procedure TWM.SetWins(Win: TWindow; Prop: TAtom; const V: array of TWindow);
begin
  if Length(V) = 0 then
    XChangeProperty(FDpy, Win, Prop, XA_WINDOW, 32, PropModeReplace, nil, 0)
  else
    XChangeProperty(FDpy, Win, Prop, XA_WINDOW, 32, PropModeReplace, PByte(@V[0]), Length(V));
end;

function TWM.GetProp(Win: TWindow; Prop, ReqType: TAtom; out N: culong): PByte;
var
  ActType: TAtom;
  ActFmt: cint;
  After: culong;
  Data: PByte;
begin
  N := 0;
  Data := nil;
  if (XGetWindowProperty(FDpy, Win, Prop, 0, 4096, 0, ReqType, @ActType, @ActFmt, @N, @After, @Data) <> Success)
     or (ActType = None) then
  begin
    if Data <> nil then XFree(Data);
    N := 0;
    Exit(nil);
  end;
  Result := Data;
end;

function TWM.GetAtoms(Win: TWindow; Prop: TAtom): TList;
var
  D: PByte;
  N, I: culong;
begin
  Result := TList.Create;
  D := GetProp(Win, Prop, XA_ATOM, N);
  if D = nil then Exit;
  for I := 0 to N - 1 do
    Result.Add(Pointer(PtrUInt(PCULong(D)[I])));
  XFree(D);
end;

function TWM.ReadName(Win: TWindow): string;
var
  D: PByte;
  N: culong;
  Nm: PChar;
begin
  Result := '';
  D := GetProp(Win, aNetWmName, aUtf8, N);
  if D <> nil then
  begin
    SetString(Result, PChar(D), N);
    XFree(D);
    Exit;
  end;
  Nm := nil;
  if (XFetchName(FDpy, Win, @Nm) <> 0) and (Nm <> nil) then
  begin
    Result := Nm;
    XFree(Nm);
  end;
end;

function TWM.WindowTypeIs(Win: TWindow; T: TAtom): Boolean;
var
  L: TList;
  I: Integer;
begin
  Result := False;
  L := GetAtoms(Win, aWindowType);
  try
    for I := 0 to L.Count - 1 do
      if TAtom(PtrUInt(L[I])) = T then Result := True;
  finally
    L.Free;
  end;
end;

function TWM.IsUnframed(Win: TWindow): Boolean;
var
  L: TList;
  I: Integer;
  T: TAtom;
begin
  Result := False;
  L := GetAtoms(Win, aWindowType);
  try
    for I := 0 to L.Count - 1 do
    begin
      T := TAtom(PtrUInt(L[I]));
      if (T = aTypeDock) or (T = aTypeDesktop) or (T = aTypeMenu) or (T = aTypeDropdown) or
         (T = aTypePopup) or (T = aTypeTooltip) or (T = aTypeNotification) or (T = aTypeCombo) or
         (T = aTypeDnd) then
        Result := True;
    end;
  finally
    L.Free;
  end;
end;

{ ---- workspaces ---- }

function TWM.OnDesk(C: TClient): Boolean;
begin
  Result := (C.Desktop < 0) or (C.Desktop = FCurDesk);
end;

function TWM.VisibleNow(C: TClient): Boolean;
begin
  Result := (not C.Iconic) and OnDesk(C);
end;

procedure TWM.ApplyVisibility(C: TClient);
begin
  if C.Iconic then Exit;
  if OnDesk(C) then XMapWindow(FDpy, C.Frame) else XUnmapWindow(FDpy, C.Frame);
end;

procedure TWM.SetDesktopProp(C: TClient);
var
  V: culong;
begin
  if C.Desktop < 0 then V := $FFFFFFFF else V := C.Desktop;
  SetCards(C.Win, aWmDesktop, [V]);
end;

function TWM.ReadDesktopProp(Win: TWindow): Integer;
var
  D: PByte;
  N: culong;
  V: culong;
begin
  Result := -2;     { no usable property }
  D := GetProp(Win, aWmDesktop, XA_CARDINAL, N);
  if D = nil then Exit;
  if N >= 1 then
  begin
    V := PCULong(D)[0];
    if V = $FFFFFFFF then Result := -1
    else if V < culong(FNumDesk) then Result := Integer(V);
  end;
  XFree(D);
end;

procedure TWM.SwitchDesktop(N: Integer; ATime: culong);
var
  I: Integer;
  T: TClient;
begin
  if (N < 0) or (N >= FNumDesk) or (N = FCurDesk) then Exit;
  if FDrag <> dgNone then EndDrag;
  if FCycling then EndCycle;
  if FKbMode <> kmNone then EndKb(True);
  FMenu.Close;
  FCurDesk := N;
  SetCards(FRoot, aCurDesktop, [culong(N)]);
  for I := 0 to FClients.Count - 1 do ApplyVisibility(TClient(FClients[I]));
  if (FFocused <> nil) and VisibleNow(FFocused) then Exit;
  FFocused := nil;
  for I := FMru.Count - 1 downto 0 do
  begin
    T := TClient(FMru[I]);
    if VisibleNow(T) then
    begin
      FocusClient(T, ATime);
      Exit;
    end;
  end;
  XSetInputFocus(FDpy, FRoot, RevertToPointerRoot, ATime);
  XDeleteProperty(FDpy, FRoot, aActive);
end;

procedure TWM.MoveToDesktop(C: TClient; D: Integer);
var
  I: Integer;
  T: TClient;
begin
  if (D >= FNumDesk) or (D < -1) or (C.Desktop = D) then Exit;
  C.Desktop := D;
  SetDesktopProp(C);
  UpdateNetState(C);
  ApplyVisibility(C);
  for I := 0 to FClients.Count - 1 do
  begin
    T := TClient(FClients[I]);
    if (T <> C) and (T.Transient = C.Win) then MoveToDesktop(T, D);
  end;
  if (C = FFocused) and (not OnDesk(C)) then FocusNext(C);
end;

function TWM.HasState(Win: TWindow; St: TAtom): Boolean;
var
  L: TList;
  I: Integer;
begin
  Result := False;
  L := GetAtoms(Win, aNetWmState);
  try
    for I := 0 to L.Count - 1 do
      if TAtom(PtrUInt(L[I])) = St then Result := True;
  finally
    L.Free;
  end;
end;

{ Layers, bottom to top: desktop windows, "below" docks (conky), normal windows,
  docks (panel). Normal frames get raised on their own; this puts the others back.
  While a window is fullscreen the panel is left alone so it cannot cover it. }
procedure TWM.Restack;
var
  I: Integer;
  Full: Boolean;
begin
  Full := False;
  for I := 0 to FClients.Count - 1 do
    if TClient(FClients[I]).Fullscreen and not TClient(FClients[I]).Iconic then Full := True;
  for I := 0 to FClients.Count - 1 do
    if TClient(FClients[I]).Below and VisibleNow(TClient(FClients[I])) then
      XLowerWindow(FDpy, TClient(FClients[I]).Frame);
  for I := 0 to High(FDocks) do
    if FDocks[I].Below then XLowerWindow(FDpy, FDocks[I].Win);
  for I := 0 to High(FDesktops) do
    XLowerWindow(FDpy, FDesktops[I]);
  if not Full then
  begin
    for I := 0 to FClients.Count - 1 do
      if TClient(FClients[I]).Above and VisibleNow(TClient(FClients[I])) then
        XRaiseWindow(FDpy, TClient(FClients[I]).Frame);
    for I := 0 to High(FDocks) do
      if not FDocks[I].Below then XRaiseWindow(FDpy, FDocks[I].Win);
  end;
end;

procedure TWM.ReadStruts(var D: TDock);
var
  Data: PByte;
  N: culong;
begin
  D.Left := 0; D.Right := 0; D.Top := 0; D.Bottom := 0;
  Data := GetProp(D.Win, aStrutPartial, XA_CARDINAL, N);
  if (Data = nil) or (N < 4) then
  begin
    if Data <> nil then XFree(Data);
    Data := GetProp(D.Win, aStrut, XA_CARDINAL, N);
  end;
  if (Data <> nil) and (N >= 4) then
  begin
    D.Left := PCULong(Data)[0];
    D.Right := PCULong(Data)[1];
    D.Top := PCULong(Data)[2];
    D.Bottom := PCULong(Data)[3];
  end;
  if Data <> nil then XFree(Data);
end;

procedure TWM.WorkArea(out AX, AY, AW, AH: Integer);
var
  I, L, R, T, B: Integer;
begin
  L := 0; R := 0; T := 0; B := 0;
  for I := 0 to High(FDocks) do
  begin
    if FDocks[I].Left > L then L := FDocks[I].Left;
    if FDocks[I].Right > R then R := FDocks[I].Right;
    if FDocks[I].Top > T then T := FDocks[I].Top;
    if FDocks[I].Bottom > B then B := FDocks[I].Bottom;
  end;
  AX := L; AY := T; AW := FScrW - L - R; AH := FScrH - T - B;
  if AW < 1 then AW := 1;
  if AH < 1 then AH := 1;
end;

procedure TWM.UpdateWorkarea;
var
  AX, AY, AW, AH, I: Integer;
  V: array of culong;
begin
  WorkArea(AX, AY, AW, AH);
  SetLength(V, 4 * FNumDesk);
  for I := 0 to FNumDesk - 1 do
  begin
    V[4 * I] := culong(AX); V[4 * I + 1] := culong(AY); V[4 * I + 2] := culong(AW); V[4 * I + 3] := culong(AH);
  end;
  SetCards(FRoot, aWorkarea, V);
end;

procedure TWM.SetupEwmh;
var
  Sup: array of culong;
  Name: string;
  Atoms: array[0..20] of TAtom;
  Names: string;
  Zero: array of culong;
  I: Integer;
begin
  FCheckWin := XCreateSimpleWindow(FDpy, FRoot, -100, -100, 1, 1, 0, 0, 0);
  Name := 'tiewm';
  XChangeProperty(FDpy, FCheckWin, aNetWmName, aUtf8, 8, PropModeReplace, PByte(PChar(Name)), Length(Name));
  SetWins(FCheckWin, aSupportingCheck, [FCheckWin]);
  SetWins(FRoot, aSupportingCheck, [FCheckWin]);
  Atoms[0] := aSupported; Atoms[1] := aActive; Atoms[2] := aClientList; Atoms[3] := aClientListStk;
  Atoms[4] := aFrameExtents; Atoms[5] := aNetWmState; Atoms[6] := aMaxVert; Atoms[7] := aMaxHorz;
  Atoms[8] := aCloseWindow; Atoms[9] := aWindowType; Atoms[10] := aSupportingCheck;
  Atoms[11] := aNumDesktops; Atoms[12] := aCurDesktop; Atoms[13] := aWorkarea;
  Atoms[14] := aHidden; Atoms[15] := aFullscreen; Atoms[16] := aWmDesktop;
  Atoms[17] := aSticky; Atoms[18] := aDeskNames; Atoms[19] := aAbove; Atoms[20] := aShaded;
  SetLength(Sup, Length(Atoms));
  for I := 0 to High(Atoms) do Sup[I] := Atoms[I];
  SetCards(FRoot, aSupported, Sup);
  { atoms are of type ATOM, not CARDINAL }
  XChangeProperty(FDpy, FRoot, aSupported, XA_ATOM, 32, PropModeReplace, PByte(@Atoms[0]), Length(Atoms));
  SetCards(FRoot, aNumDesktops, [culong(FNumDesk)]);
  SetCards(FRoot, aCurDesktop, [culong(FCurDesk)]);
  SetCards(FRoot, aDeskGeom, [culong(FScrW), culong(FScrH)]);
  SetLength(Zero, 2 * FNumDesk);
  for I := 0 to High(Zero) do Zero[I] := 0;
  SetCards(FRoot, aDeskViewport, Zero);
  Names := '';
  for I := 1 to FNumDesk do Names := Names + 'Workspace ' + IntToStr(I) + #0;
  XChangeProperty(FDpy, FRoot, aDeskNames, aUtf8, 8, PropModeReplace, PByte(PChar(Names)), Length(Names));
  UpdateWorkarea;
end;

{ ---- client bookkeeping ---- }

function TWM.FindClient(Win: TWindow): TClient;
var
  I: Integer;
begin
  for I := 0 to FClients.Count - 1 do
    if TClient(FClients[I]).Win = Win then Exit(TClient(FClients[I]));
  Result := nil;
end;

function TWM.FindFrame(Frame: TWindow): TClient;
var
  I: Integer;
begin
  for I := 0 to FClients.Count - 1 do
    if TClient(FClients[I]).Frame = Frame then Exit(TClient(FClients[I]));
  Result := nil;
end;

procedure TWM.UpdateClientList;
var
  L: array of TWindow;
  I: Integer;
begin
  SetLength(L, FClients.Count);
  for I := 0 to FClients.Count - 1 do L[I] := TClient(FClients[I]).Win;
  SetWins(FRoot, aClientList, L);
  SetWins(FRoot, aClientListStk, L);
end;

procedure TWM.SetWmState(C: TClient; State: Integer);
var
  V: array[0..1] of culong;
begin
  V[0] := State;
  V[1] := 0;
  XChangeProperty(FDpy, C.Win, aWmState, aWmState, 32, PropModeReplace, PByte(@V[0]), 2);
end;

procedure TWM.UpdateNetState(C: TClient);
var
  V: array[0..7] of TAtom;
  N: Integer;
begin
  N := 0;
  if C.Below then begin V[N] := aBelow; Inc(N); end;
  if C.Shaded then begin V[N] := aShaded; Inc(N); end;
  if C.Above then begin V[N] := aAbove; Inc(N); end;
  if C.Desktop < 0 then begin V[N] := aSticky; Inc(N); end;
  if C.Maximized then begin V[N] := aMaxVert; Inc(N); V[N] := aMaxHorz; Inc(N); end;
  if C.Fullscreen then begin V[N] := aFullscreen; Inc(N); end;
  if C.Iconic then begin V[N] := aHidden; Inc(N); end;
  if N = 0 then
    XDeleteProperty(FDpy, C.Win, aNetWmState)
  else
    XChangeProperty(FDpy, C.Win, aNetWmState, XA_ATOM, 32, PropModeReplace, PByte(@V[0]), N);
end;

procedure TWM.ReadHints(C: TClient);
var
  Sz: TXSizeHints;
  Supplied: clong;
  Wm: PXWMHints;
  Prots: PAtom;
  NProt, I: cint;
  TWin: TWindow;
begin
  C.MinW := 1; C.MinH := 1; C.MaxW := 65535; C.MaxH := 65535;
  C.IncW := 1; C.IncH := 1; C.BaseW := 0; C.BaseH := 0;
  FillChar(Sz, SizeOf(Sz), 0);
  if XGetWMNormalHints(FDpy, C.Win, @Sz, @Supplied) <> 0 then
  begin
    if (Sz.flags and PMinSize) <> 0 then begin C.MinW := Sz.min_width; C.MinH := Sz.min_height; end;
    if (Sz.flags and PMaxSize) <> 0 then begin C.MaxW := Sz.max_width; C.MaxH := Sz.max_height; end;
    if (Sz.flags and PResizeInc) <> 0 then begin C.IncW := Sz.width_inc; C.IncH := Sz.height_inc; end;
    if (Sz.flags and PBaseSize) <> 0 then begin C.BaseW := Sz.base_width; C.BaseH := Sz.base_height; end
    else if (Sz.flags and PMinSize) <> 0 then begin C.BaseW := Sz.min_width; C.BaseH := Sz.min_height; end;
  end;
  if C.IncW < 1 then C.IncW := 1;
  if C.IncH < 1 then C.IncH := 1;
  if C.MinW < 1 then C.MinW := 1;
  if C.MinH < 1 then C.MinH := 1;
  C.InputHint := True;
  Wm := XGetWMHints(FDpy, C.Win);
  if Wm <> nil then
  begin
    if (Wm^.flags and InputHint) <> 0 then C.InputHint := Wm^.input <> 0;
    XFree(Wm);
  end;
  C.Transient := 0;
  TWin := 0;
  if (XGetTransientForHint(FDpy, C.Win, @TWin) <> 0) and (TWin <> FRoot) and (TWin <> C.Win) then
    C.Transient := TWin;
  C.HasDelete := False;
  C.HasTakeFocus := False;
  Prots := nil;
  NProt := 0;
  if (XGetWMProtocols(FDpy, C.Win, @Prots, @NProt) <> 0) and (Prots <> nil) then
  begin
    for I := 0 to NProt - 1 do
    begin
      if Prots[I] = aDelete then C.HasDelete := True;
      if Prots[I] = aTakeFocus then C.HasTakeFocus := True;
    end;
    XFree(Prots);
  end;
end;

{ ---- geometry ---- }

function TWM.Ext(C: TClient): TExt;
var
  M: TThemeMetrics;
begin
  if C.Fullscreen or not C.Decorated then
  begin
    Result.L := 0; Result.R := 0; Result.T := 0; Result.B := 0;
  end
  else
  begin
    M := FTheme.Metrics;
    Result.L := M.LeftW; Result.R := M.RightW; Result.T := M.TitleH; Result.B := M.BottomH;
  end;
end;

procedure TWM.SetFrameExtentsProp(C: TClient);
var
  E: TExt;
begin
  E := Ext(C);
  SetCards(C.Win, aFrameExtents, [culong(E.L), culong(E.R), culong(E.T), culong(E.B)]);
end;

procedure TWM.ClientSizeOf(C: TClient; out CW, CH: Integer);
var
  E: TExt;
begin
  E := Ext(C);
  CW := C.W - E.L - E.R;
  if C.Shaded then CH := C.UnshadeH - E.T - E.B else CH := C.H - E.T - E.B;
  if CW < 1 then CW := 1;
  if CH < 1 then CH := 1;
end;

procedure TWM.ConstrainClient(C: TClient; var CW, CH: Integer);
begin
  if CW < C.MinW then CW := C.MinW;
  if CH < C.MinH then CH := C.MinH;
  if CW > C.MaxW then CW := C.MaxW;
  if CH > C.MaxH then CH := C.MaxH;
  if C.IncW > 1 then CW := C.BaseW + ((CW - C.BaseW) div C.IncW) * C.IncW;
  if C.IncH > 1 then CH := C.BaseH + ((CH - C.BaseH) div C.IncH) * C.IncH;
  if CW < C.MinW then CW := C.MinW;
  if CH < C.MinH then CH := C.MinH;
end;

procedure TWM.SendConfigure(C: TClient);
var
  Ev: TXEvent;
  E: TExt;
  CW, CH: Integer;
begin
  E := Ext(C);
  ClientSizeOf(C, CW, CH);
  FillChar(Ev, SizeOf(Ev), 0);
  Ev.xconfigure._type := ConfigureNotify;
  Ev.xconfigure.event := C.Win;
  Ev.xconfigure.window := C.Win;
  Ev.xconfigure.x := C.X + E.L;
  Ev.xconfigure.y := C.Y + E.T;
  Ev.xconfigure.width := CW;
  Ev.xconfigure.height := CH;
  Ev.xconfigure.border_width := 0;
  Ev.xconfigure.above := None;
  Ev.xconfigure.override_redirect := 0;
  XSendEvent(FDpy, C.Win, 0, StructureNotifyMask, @Ev);
end;

procedure TWM.Repaint(C: TClient; Force: Boolean);
var
  Act: Boolean;
  Pm, Mask: TPixmap;
  TX, BY: Integer;
begin
  if C.Fullscreen or not C.Decorated then Exit;
  Act := C = FFocused;
  if (not Force) and C.Painted and (C.PaintedActive = Act) and (C.PaintedW = C.W) and
     (C.PaintedH = C.H) and (C.PaintedName = C.Name) then Exit;
  if Act then
    Pm := PaintFrameEx(FDpy, FScr, FTheme, FFont, wsActive, C.W, C.H, C.Name, TitleAlign, C.Shaded, Mask, TX, BY)
  else
    Pm := PaintFrameEx(FDpy, FScr, FTheme, FFont, wsInactive, C.W, C.H, C.Name, TitleAlign, C.Shaded, Mask, TX, BY);
  XSetWindowBackgroundPixmap(FDpy, C.Frame, Pm);
  XShapeCombineMask(FDpy, C.Frame, ShapeBounding, 0, 0, Mask, ShapeSet);
  XClearWindow(FDpy, C.Frame);
  XFreePixmap(FDpy, Mask);
  XFreePixmap(FDpy, Pm);   { the server keeps its own reference as the window background }
  C.Painted := True;
  C.PaintedActive := Act;
  C.PaintedW := C.W;
  C.PaintedH := C.H;
  C.PaintedName := C.Name;
end;

procedure TWM.SetFrameGeometry(C: TClient; NX, NY, NW, NH: Integer);
var
  M: TThemeMetrics;
  CW, CH: Integer;
  Resized: Boolean;
begin
  M := FTheme.Metrics;
  Resized := (NW <> C.W) or (NH <> C.H);
  C.X := NX; C.Y := NY; C.W := NW; C.H := NH;
  ClientSizeOf(C, CW, CH);
  XMoveResizeWindow(FDpy, C.Frame, NX, NY, NW, NH);
  if Resized then
  begin
    XResizeWindow(FDpy, C.Win, CW, CH);
    Repaint(C, True);
  end;
  SendConfigure(C);
end;

procedure TWM.Place(C: TClient; HasPos: Boolean; CX, CY: Integer);
var
  AX, AY, AW, AH: Integer;
  P: TClient;
  E: TExt;
begin
  E := Ext(C);
  WorkArea(AX, AY, AW, AH);
  if HasPos then
  begin
    C.X := CX - E.L;
    C.Y := CY - E.T;
  end
  else
  begin
    C.X := AX + (AW - C.W) div 2;
    C.Y := AY + (AH - C.H) div 2;
    P := FindClient(C.Transient);
    if P <> nil then
    begin
      C.X := P.X + (P.W - C.W) div 2;
      C.Y := P.Y + (P.H - C.H) div 2;
    end;
  end;
  if C.X + C.W > AX + AW then C.X := AX + AW - C.W;
  if C.Y + C.H > AY + AH then C.Y := AY + AH - C.H;
  if C.X < AX then C.X := AX;
  if C.Y < AY then C.Y := AY;
end;

{ ---- managing ---- }

procedure TWM.Manage(Win: TWindow; Startup: Boolean);
var
  Atr: TXWindowAttributes;
  C: TClient;
  E: TExt;
  Sz: TXSizeHints;
  Supplied: clong;
  HasPos: Boolean;
  CW, CH, I: Integer;
  SetA: TXSetWindowAttributes;
  Dk: TDock;
  WasViewable: Boolean;
begin
  if (Win = FRoot) or (Win = FCheckWin) then Exit;
  if FindClient(Win) <> nil then Exit;
  if XGetWindowAttributes(FDpy, Win, @Atr) = 0 then Exit;
  if Atr.override_redirect <> 0 then Exit;
  if IsUnframed(Win) then
  begin
    if WindowTypeIs(Win, aTypeDock) then
    begin
      for I := 0 to High(FDocks) do if FDocks[I].Win = Win then begin XMapWindow(FDpy, Win); Exit; end;
      Dk.Win := Win;
      Dk.Below := HasState(Win, aBelow);
      ReadStruts(Dk);
      SetLength(FDocks, Length(FDocks) + 1);
      FDocks[High(FDocks)] := Dk;
      XSelectInput(FDpy, Win, PropertyChangeMask or StructureNotifyMask);
      UpdateWorkarea;
    end
    else if WindowTypeIs(Win, aTypeDesktop) then
    begin
      for I := 0 to High(FDesktops) do if FDesktops[I] = Win then begin XMapWindow(FDpy, Win); Restack; Exit; end;
      SetLength(FDesktops, Length(FDesktops) + 1);
      FDesktops[High(FDesktops)] := Win;
      XSelectInput(FDpy, Win, StructureNotifyMask);
    end;
    XMapWindow(FDpy, Win);
    Restack;
    Exit;
  end;
  WasViewable := Atr.map_state = IsViewable;
  C := TClient.Create;
  C.Win := Win;
  C.Name := ReadName(Win);
  ReadHints(C);
  C.Decorated := WantsDecorations(Win);
  E := Ext(C);
  C.Desktop := ReadDesktopProp(Win);
  if C.Desktop = -2 then
  begin
    if FindClient(C.Transient) <> nil then C.Desktop := FindClient(C.Transient).Desktop
    else C.Desktop := FCurDesk;
  end;
  CW := Atr.width; CH := Atr.height;
  ConstrainClient(C, CW, CH);
  C.W := CW + E.L + E.R;
  C.H := CH + E.T + E.B;
  FillChar(Sz, SizeOf(Sz), 0);
  HasPos := False;
  if XGetWMNormalHints(FDpy, Win, @Sz, @Supplied) <> 0 then
    HasPos := (Sz.flags and (USPosition or PPosition)) <> 0;
  if Startup then
  begin
    C.X := Atr.x - E.L;
    C.Y := Atr.y - E.T;
    if C.Y < 0 then C.Y := 0;
  end
  else
    Place(C, HasPos, Atr.x, Atr.y);
  C.Frame := XCreateSimpleWindow(FDpy, FRoot, C.X, C.Y, C.W, C.H, 0, 0, 0);
  XSelectInput(FDpy, C.Frame, SubstructureMasks or ButtonPressMask or ButtonReleaseMask or
    PointerMotionMask or ExposureMask or EnterWindowMask);
  XSetWindowBorderWidth(FDpy, Win, 0);
  XAddToSaveSet(FDpy, Win);
  if WasViewable then Inc(C.IgnoreUnmap);   { reparenting a mapped window unmaps it }
  XReparentWindow(FDpy, Win, C.Frame, E.L, E.T);
  XResizeWindow(FDpy, Win, CW, CH);
  SetA.event_mask := PropertyChangeMask or FocusChangeMask;
  XChangeWindowAttributes(FDpy, Win, CWEventMask, @SetA);
  { passive sync grab: lets us focus/raise on click, then replay the click to the app }
  XGrabButton(FDpy, AnyButton, AnyModifier, Win, 0, ButtonPressMask or ButtonReleaseMask,
    GrabModeSync, GrabModeAsync, None, None);
  FClients.Add(C);
  FMru.Add(C);
  Repaint(C, True);
  XMapWindow(FDpy, Win);
  if OnDesk(C) then XMapWindow(FDpy, C.Frame);
  SetWmState(C, NormalState);
  SetDesktopProp(C);
  UpdateNetState(C);
  SetCards(Win, aFrameExtents, [culong(E.L), culong(E.R), culong(E.T), culong(E.B)]);
  SendConfigure(C);
  UpdateClientList;
  Log(Format('managed 0x%x "%s" frame 0x%x at %d,%d %dx%d%s', [Win, C.Name, C.Frame, C.X, C.Y, C.W, C.H,
    IfThen(C.Decorated, '', ' (no decorations)')]));
  if (not Startup) and OnDesk(C) then FocusClient(C, CurrentTime);
end;

procedure TWM.Unmanage(C: TClient; Destroyed: Boolean);
var
  E: TExt;
  Par: TClient;
begin
  E := Ext(C);
  Par := FindClient(C.Transient);
  if FMenuClient = C then
  begin
    FMenu.Close;
    FMenuClient := nil;
  end;
  if FKbClient = C then EndKb(True);
  if FCycleList.IndexOf(C) >= 0 then
  begin
    FCycleList.Remove(C);
    if FCycling and (FCycleList.Count < 2) then EndCycle;
  end;
  Log(Format('unmanage 0x%x destroyed=%d', [C.Win, Ord(Destroyed)]));
  if FDrag <> dgNone then if FDragClient = C then EndDrag;
  if FPressClient = C then FPressClient := nil;
  if not Destroyed then
  begin
    XUnmapWindow(FDpy, C.Frame);
    XReparentWindow(FDpy, C.Win, FRoot, C.X + E.L, C.Y + E.T);
    XRemoveFromSaveSet(FDpy, C.Win);
    SetWmState(C, WithdrawnState);
    XDeleteProperty(FDpy, C.Win, aFrameExtents);
    XDeleteProperty(FDpy, C.Win, aNetWmState);
  end;
  XDestroyWindow(FDpy, C.Frame);
  FClients.Remove(C);
  FMru.Remove(C);
  if FFocused = C then
  begin
    FFocused := nil;
    if (Par <> nil) and (Par <> C) and VisibleNow(Par) then FocusClient(Par, CurrentTime)
    else FocusNext(nil);
  end;
  C.Free;
  UpdateClientList;
end;

procedure TWM.ScanExisting;
var
  Root, Par: TWindow;
  Kids: PWindow;
  N: cuint;
  I: Integer;
  Atr: TXWindowAttributes;
begin
  XGrabServer(FDpy);
  try
    if XQueryTree(FDpy, FRoot, @Root, @Par, @Kids, @N) <> 0 then
    begin
      for I := 0 to Integer(N) - 1 do
        if (XGetWindowAttributes(FDpy, Kids[I], @Atr) <> 0) and (Atr.override_redirect = 0) and
           (Atr.map_state = IsViewable) then
          Manage(Kids[I], True);
      if Kids <> nil then XFree(Kids);
    end;
    Restack;
  finally
    XUngrabServer(FDpy);
  end;
end;

{ ---- focus, stacking, closing ---- }

procedure TWM.FocusClient(C: TClient; ATime: culong);
var
  Old: TClient;
  Ev: TXEvent;
begin
  if C = nil then Exit;
  Old := FFocused;
  FFocused := C;
  FMru.Remove(C);
  FMru.Add(C);
  if C.InputHint then
    XSetInputFocus(FDpy, C.Win, RevertToPointerRoot, ATime);
  if C.HasTakeFocus then
  begin
    FillChar(Ev, SizeOf(Ev), 0);
    Ev.xclient._type := ClientMessage;
    Ev.xclient.window := C.Win;
    Ev.xclient.message_type := aProtocols;
    Ev.xclient.format := 32;
    Ev.xclient.data.l[0] := clong(aTakeFocus);
    Ev.xclient.data.l[1] := clong(ATime);
    XSendEvent(FDpy, C.Win, 0, NoEventMask, @Ev);
  end;
  SetWins(FRoot, aActive, [C.Win]);
  if (Old <> nil) and (Old <> C) then Repaint(Old, False);
  Repaint(C, False);
end;

procedure TWM.RaiseClient(C: TClient);
begin
  XRaiseWindow(FDpy, C.Frame);
  RaiseTransients(C, 0);
  Restack;
end;

procedure TWM.RaiseTransients(C: TClient; Depth: Integer);
var
  I: Integer;
  T: TClient;
begin
  if Depth > 4 then Exit;
  for I := 0 to FClients.Count - 1 do
  begin
    T := TClient(FClients[I]);
    if (T <> C) and (T.Transient = C.Win) and (not T.Iconic) then
    begin
      XRaiseWindow(FDpy, T.Frame);
      RaiseTransients(T, Depth + 1);
    end;
  end;
end;

procedure TWM.CloseClient(C: TClient);
var
  Ev: TXEvent;
begin
  if C.HasDelete then
  begin
    FillChar(Ev, SizeOf(Ev), 0);
    Ev.xclient._type := ClientMessage;
    Ev.xclient.window := C.Win;
    Ev.xclient.message_type := aProtocols;
    Ev.xclient.format := 32;
    Ev.xclient.data.l[0] := clong(aDelete);
    Ev.xclient.data.l[1] := clong(CurrentTime);
    XSendEvent(FDpy, C.Win, 0, NoEventMask, @Ev);
  end
  else
    XKillClient(FDpy, C.Win);
end;

procedure TWM.ToggleMaximize(C: TClient);
var
  AX, AY, AW, AH: Integer;
begin
  if C.Fullscreen or C.Iconic then Exit;
  if C.Shaded then SetShaded(C, False);
  if C.Maximized then
  begin
    C.Maximized := False;
    SetFrameGeometry(C, C.SaveX, C.SaveY, C.SaveW, C.SaveH);
  end
  else
  begin
    C.SaveX := C.X; C.SaveY := C.Y; C.SaveW := C.W; C.SaveH := C.H;
    WorkArea(AX, AY, AW, AH);
    C.Maximized := True;
    SetFrameGeometry(C, AX, AY, AW, AH);
  end;
  UpdateNetState(C);
end;

{ ---- iconify / fullscreen ---- }

procedure TWM.Activate(C: TClient; ATime: culong);
begin
  if not OnDesk(C) then SwitchDesktop(C.Desktop, ATime);
  if C.Iconic then Deiconify(C);
  FocusClient(C, ATime);
  RaiseClient(C);
end;

procedure TWM.FocusNext(Exclude: TClient);
var
  I: Integer;
  T, Old: TClient;
begin
  for I := FMru.Count - 1 downto 0 do
  begin
    T := TClient(FMru[I]);
    if (T <> Exclude) and VisibleNow(T) then
    begin
      FocusClient(T, CurrentTime);
      Exit;
    end;
  end;
  Old := FFocused;
  FFocused := nil;
  if (Old <> nil) and (FClients.IndexOf(Old) >= 0) and (not Old.Iconic) then Repaint(Old, False);
  XSetInputFocus(FDpy, FRoot, RevertToPointerRoot, CurrentTime);
  XDeleteProperty(FDpy, FRoot, aActive);
end;

{ _MOTIF_WM_HINTS: flags, functions, decorations, input_mode, status. When the decorations
  field is present: with MWM_DECOR_ALL set, the listed bits are taken away from "all";
  without it, only the listed bits are wanted. No title bar wanted = the app draws its own
  frame, so we draw none (a "border only" request is treated the same). }
function TWM.WantsDecorations(Win: TWindow): Boolean;
const
  MWM_HINTS_DECORATIONS = 2;
  MWM_DECOR_ALL = 1;
  MWM_DECOR_TITLE = 8;
var
  D: PByte;
  N: culong;
  Flags, Decor: culong;
begin
  Result := True;
  D := GetProp(Win, aMotif, aMotif, N);
  if D = nil then Exit;
  if N >= 3 then
  begin
    Flags := PCULong(D)[0];
    Decor := PCULong(D)[2];
    if (Flags and MWM_HINTS_DECORATIONS) <> 0 then
    begin
      if (Decor and MWM_DECOR_ALL) <> 0 then Result := (Decor and MWM_DECOR_TITLE) = 0
      else Result := (Decor and MWM_DECOR_TITLE) <> 0;
    end;
  end;
  XFree(D);
end;

{ Adds or removes the frame graphics while the client stays exactly where it is. }
procedure TWM.SetDecorated(C: TClient; On: Boolean);
var
  OldE, E: TExt;
  CX, CY, CW, CH, AX, AY, AW, AH: Integer;
begin
  if C.Decorated = On then Exit;
  if C.Fullscreen then
  begin
    C.Decorated := On;      { shows when fullscreen ends }
    Exit;
  end;
  if C.Shaded then SetShaded(C, False);
  OldE := Ext(C);
  CX := C.X + OldE.L;
  CY := C.Y + OldE.T;
  ClientSizeOf(C, CW, CH);
  C.Decorated := On;
  E := Ext(C);
  if C.Maximized then
  begin
    WorkArea(AX, AY, AW, AH);
    C.X := AX; C.Y := AY; C.W := AW; C.H := AH;
    ClientSizeOf(C, CW, CH);
  end
  else
  begin
    C.X := CX - E.L;
    C.Y := CY - E.T;
    C.W := CW + E.L + E.R;
    C.H := CH + E.T + E.B;
  end;
  XMoveResizeWindow(FDpy, C.Frame, C.X, C.Y, C.W, C.H);
  XMoveResizeWindow(FDpy, C.Win, E.L, E.T, CW, CH);
  if On then
    Repaint(C, True)
  else
  begin
    C.Painted := False;
    XShapeCombineMask(FDpy, C.Frame, ShapeBounding, 0, 0, None, ShapeSet);   { plain rectangle }
  end;
  SetFrameExtentsProp(C);
  SendConfigure(C);
  Log(Format('0x%x "%s": titlebar %s', [C.Win, C.Name, IfThen(On, 'on', 'off')]));
end;

function TWM.OptsFor(C: TClient): TFrameOpts;
begin
  Result := FOpts;
  Result.Shaded := C.Shaded;
end;

{ Rolls the window up to its titlebar. The client stays mapped, only clipped by the
  smaller frame, so it keeps running and keeps its real size. }
procedure TWM.SetShaded(C: TClient; On: Boolean);
begin
  if C.Shaded = On then Exit;
  if On then
  begin
    if C.Maximized or C.Fullscreen or C.Iconic or not C.Decorated then Exit;
    C.UnshadeH := C.H;
    C.Shaded := True;
    C.H := FTheme.Metrics.TitleH;
  end
  else
  begin
    C.Shaded := False;
    C.H := C.UnshadeH;
  end;
  XResizeWindow(FDpy, C.Frame, C.W, C.H);
  Repaint(C, True);
  SendConfigure(C);
  UpdateNetState(C);
end;

procedure TWM.SetAbove(C: TClient; On: Boolean);
begin
  if C.Above = On then Exit;
  C.Above := On;
  if On then C.Below := False;     { above and below exclude each other }
  UpdateNetState(C);
  if On then RaiseClient(C) else Restack;
end;

procedure TWM.SetBelow(C: TClient; On: Boolean);
begin
  if C.Below = On then Exit;
  C.Below := On;
  if On then C.Above := False;
  UpdateNetState(C);
  Restack;
end;

procedure TWM.Iconify(C: TClient);
var
  I: Integer;
  T: TClient;
  Atr: TXWindowAttributes;
begin
  if C.Iconic then Exit;
  { transients go with their parent }
  for I := 0 to FClients.Count - 1 do
  begin
    T := TClient(FClients[I]);
    if (T <> C) and (T.Transient = C.Win) then Iconify(T);
  end;
  C.Iconic := True;
  if (XGetWindowAttributes(FDpy, C.Win, @Atr) <> 0) and (Atr.map_state <> IsUnmapped) then
  begin
    Inc(C.IgnoreUnmap);
    XUnmapWindow(FDpy, C.Win);
  end;
  XUnmapWindow(FDpy, C.Frame);
  SetWmState(C, IconicState);
  UpdateNetState(C);
  if FDrag <> dgNone then if FDragClient = C then EndDrag;
  if FFocused = C then FocusNext(C);
end;

procedure TWM.Deiconify(C: TClient);
var
  I: Integer;
  T: TClient;
begin
  if not C.Iconic then Exit;
  C.Iconic := False;
  XMapWindow(FDpy, C.Win);
  if OnDesk(C) then XMapWindow(FDpy, C.Frame);
  SetWmState(C, NormalState);
  UpdateNetState(C);
  for I := 0 to FClients.Count - 1 do
  begin
    T := TClient(FClients[I]);
    if (T <> C) and (T.Transient = C.Win) then Deiconify(T);
  end;
end;

procedure TWM.SetFullscreen(C: TClient; On: Boolean);
var
  M: TThemeMetrics;
  AX, AY, AW, AH, NX, NY, NW, NH, CW, CH: Integer;
begin
  if C.Fullscreen = On then Exit;
  M := FTheme.Metrics;
  if C.Shaded then SetShaded(C, False);
  if On then
  begin
    if C.Iconic then Deiconify(C);
    if not C.Maximized then
    begin
      C.SaveX := C.X; C.SaveY := C.Y; C.SaveW := C.W; C.SaveH := C.H;
    end;
    C.Fullscreen := True;
    C.X := 0; C.Y := 0; C.W := FScrW; C.H := FScrH;
    XMoveResizeWindow(FDpy, C.Frame, 0, 0, FScrW, FScrH);
    XMoveResizeWindow(FDpy, C.Win, 0, 0, FScrW, FScrH);
    XShapeCombineMask(FDpy, C.Frame, ShapeBounding, 0, 0, None, ShapeSet);   { no shape: plain rectangle }
    C.Painted := False;
    RaiseClient(C);
  end
  else
  begin
    C.Fullscreen := False;
    if C.Maximized then
    begin
      WorkArea(AX, AY, AW, AH);
      NX := AX; NY := AY; NW := AW; NH := AH;
    end
    else
    begin
      NX := C.SaveX; NY := C.SaveY; NW := C.SaveW; NH := C.SaveH;
    end;
    C.X := NX; C.Y := NY; C.W := NW; C.H := NH;
    ClientSizeOf(C, CW, CH);
    XMoveResizeWindow(FDpy, C.Frame, NX, NY, NW, NH);
    XMoveResizeWindow(FDpy, C.Win, Ext(C).L, Ext(C).T, CW, CH);
    Repaint(C, True);
  end;
  SetFrameExtentsProp(C);
  SendConfigure(C);
  UpdateNetState(C);
  Restack;   { panel goes back on top (or stays below while a window is fullscreen) }
end;

{ ---- window menu ---- }

const
  mnBelow = 8;
  mnShade = 7;
  mnMinimize = 1;
  mnMaximize = 2;
  mnFullscreen = 3;
  mnAbove = 4;
  mnSticky = 5;
  mnClose = 6;
  mnDesktop = 100;     { + 0-based desktop }

procedure TWM.OpenWindowMenu(C: TClient; X, Y: Integer; ATime: culong);
var
  K: Integer;
begin
  if FMenu.IsOpen then FMenu.Close;
  if FCycling then EndCycle;
  FMenu.Clear;
  FMenu.Add(mnMinimize, 'Minimize', False, True);
  if C.Maximized then FMenu.Add(mnMaximize, 'Restore', False, not C.Fullscreen)
  else FMenu.Add(mnMaximize, 'Maximize', False, not C.Fullscreen);
  FMenu.Add(mnFullscreen, 'Fullscreen', C.Fullscreen, True);
  FMenu.Add(mnAbove, 'Always on top', C.Above, True);
  FMenu.Add(mnBelow, 'Always below', C.Below, True);
  FMenu.Add(mnSticky, 'On all workspaces', C.Desktop < 0, True);
  FMenu.Add(mnShade, 'Shade', C.Shaded, C.Decorated and not (C.Maximized or C.Fullscreen));
  FMenu.AddSeparator;
  for K := 0 to FNumDesk - 1 do
    FMenu.Add(mnDesktop + K, 'Move to Workspace ' + IntToStr(K + 1), C.Desktop = K, C.Desktop <> K);
  FMenu.AddSeparator;
  FMenu.Add(mnClose, 'Close', False, True);
  FMenuClient := C;
  if not FMenu.Popup(X, Y, ATime) then
  begin
    FMenuClient := nil;
    Log('window menu: could not grab the pointer');
  end;
end;

procedure TWM.RunMenuAction(Id: Integer);
var
  C: TClient;
begin
  C := FMenuClient;
  FMenuClient := nil;
  if (C = nil) or (FClients.IndexOf(C) < 0) then Exit;
  if Id = mnMinimize then Iconify(C)
  else if Id = mnMaximize then ToggleMaximize(C)
  else if Id = mnFullscreen then SetFullscreen(C, not C.Fullscreen)
  else if Id = mnAbove then SetAbove(C, not C.Above)
  else if Id = mnShade then SetShaded(C, not C.Shaded)
  else if Id = mnBelow then SetBelow(C, not C.Below)
  else if Id = mnSticky then
  begin
    if C.Desktop < 0 then MoveToDesktop(C, FCurDesk) else MoveToDesktop(C, -1);
  end
  else if Id = mnClose then CloseClient(C)
  else if (Id >= mnDesktop) and (Id < mnDesktop + FNumDesk) then MoveToDesktop(C, Id - mnDesktop);
end;

{ ---- keyboard: Alt+F4, Alt+Tab cycling, Super+Return, Alt+F9, Alt+F11 ---- }

procedure TWM.GrabKeys;
const
  Locks: array[0..3] of cuint = (0, LockMask, Mod2Mask, LockMask or Mod2Mask);
var
  I, K: Integer;
begin
  XUngrabKey(FDpy, 0, AnyModifier, FRoot);   { 0 = AnyKey: also used when the bindings are reloaded }
  for I := 0 to High(FCfg.Keys) do
  begin
    FCfg.Keys[I].Kc := XKeysymToKeycode(FDpy, FCfg.Keys[I].Sym);
    if FCfg.Keys[I].Kc = 0 then
    begin
      Log('no keycode for ' + FormatCombo(FCfg.Keys[I].Sym, FCfg.Keys[I].Mods));
      Continue;
    end;
    for K := 0 to High(Locks) do
      XGrabKey(FDpy, FCfg.Keys[I].Kc, FCfg.Keys[I].Mods or Locks[K], FRoot, 0, GrabModeAsync, GrabModeAsync);
  end;
end;

function TWM.FindBinding(Kc, St: cuint): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FCfg.Keys) do
    if (FCfg.Keys[I].Kc = Kc) and (FCfg.Keys[I].Mods = St) then Exit(I);
  Result := -1;
end;

{ moves the focused window to desktop K (0-based) and goes there with it }
procedure TWM.MoveFocusedTo(K: Integer; ATime: culong);
var
  C: TClient;
begin
  if (FFocused = nil) or (FFocused.Desktop < 0) then Exit;
  if (K < 0) or (K >= FNumDesk) then Exit;
  C := FFocused;
  C.Desktop := K;
  SetDesktopProp(C);
  UpdateNetState(C);
  SwitchDesktop(K, ATime);
  FocusClient(C, ATime);
end;

procedure TWM.RunAction(const B: TKeyBinding; ATime: culong);
begin
  case B.Action of
    kaClose: if FFocused <> nil then CloseClient(FFocused);
    kaCycle: StartCycle(1, ATime, B.Mods);
    kaCycleBack: StartCycle(-1, ATime, B.Mods);
    kaMaximize: if FFocused <> nil then ToggleMaximize(FFocused);
    kaIconify: if FFocused <> nil then Iconify(FFocused);
    kaFullscreen: if FFocused <> nil then SetFullscreen(FFocused, not FFocused.Fullscreen);
    kaDeskLeft: SwitchDesktop(FCurDesk - 1, ATime);
    kaDeskRight: SwitchDesktop(FCurDesk + 1, ATime);
    kaMoveLeft: if FFocused <> nil then MoveFocusedTo(FFocused.Desktop - 1, ATime);
    kaMoveRight: if FFocused <> nil then MoveFocusedTo(FFocused.Desktop + 1, ATime);
    kaWindowMenu:
      if FFocused <> nil then
        OpenWindowMenu(FFocused, FFocused.X + 24, FFocused.Y + FTheme.Metrics.TitleH, ATime);
    kaShade: if FFocused <> nil then SetShaded(FFocused, not FFocused.Shaded);
    kaMoveWindow: StartKb(kmMove, ATime);
    kaResizeWindow: StartKb(kmResize, ATime);
    kaGotoDesk: SwitchDesktop(B.Arg - 1, ATime);
    kaMoveToDesk: MoveFocusedTo(B.Arg - 1, ATime);
  end;
end;

procedure TWM.StartCycle(Dir: Integer; ATime: culong; Mods: cuint);
var
  I: Integer;
  Rw, Cw: TWindow;
  Rx, Ry, Wx, Wy: cint;
  Mask: cuint;
begin
  FCycleList.Clear;
  for I := FMru.Count - 1 downto 0 do
    if OnDesk(TClient(FMru[I])) then FCycleList.Add(FMru[I]);
  if FCycleList.Count < 2 then begin FCycleList.Clear; Exit; end;
  FCycleIdx := 0;
  { cycling ends when the modifier(s) that started it are released; Shift alone does not count }
  FCycleMods := Mods and not ShiftMask;
  if FCycleMods = 0 then FCycleMods := Mods;
  { while the modifier stays down we own the keyboard, so key repeats and the release reach us }
  if XGrabKeyboard(FDpy, FRoot, 0, GrabModeAsync, GrabModeAsync, ATime) = GrabSuccess then
    FCycling := True;
  StepCycle(Dir);
  if FCycling then
  begin
    { the modifier may already be up if the key press was very short }
    if XQueryPointer(FDpy, FRoot, @Rw, @Cw, @Rx, @Ry, @Wx, @Wy, @Mask) and ((Mask and FCycleMods) = 0) then
      EndCycle;
  end
  else
    FCycleList.Clear;
end;

procedure TWM.StepCycle(Dir: Integer);
var
  N: Integer;
begin
  N := FCycleList.Count;
  if N < 2 then Exit;
  FCycleIdx := ((FCycleIdx + Dir) mod N + N) mod N;
  Activate(TClient(FCycleList[FCycleIdx]), CurrentTime);
end;

procedure TWM.EndCycle;
begin
  if FCycling then XUngrabKeyboard(FDpy, CurrentTime);
  FCycling := False;
  FCycleList.Clear;
end;

{ ---- Alt+F7 / Alt+F8: move / resize the focused window with the arrow keys ---- }

procedure TWM.StartKb(Mode: TKbMode; ATime: culong);
var
  C: TClient;
begin
  C := FFocused;
  if (C = nil) or C.Maximized or C.Fullscreen or C.Iconic then Exit;
  if (Mode = kmResize) and C.Shaded then Exit;
  if FKbMode <> kmNone then Exit;
  if FCycling then EndCycle;
  if FMenu.IsOpen then FMenu.Close;
  if FDrag <> dgNone then EndDrag;
  if XGrabKeyboard(FDpy, FRoot, 0, GrabModeAsync, GrabModeAsync, ATime) <> GrabSuccess then Exit;
  FKbMode := Mode;
  FKbClient := C;
  FKbX := C.X; FKbY := C.Y; FKbW := C.W; FKbH := C.H;
  RaiseClient(C);
end;

procedure TWM.EndKb(Commit: Boolean);
var
  C: TClient;
begin
  if FKbMode = kmNone then Exit;
  C := FKbClient;
  XUngrabKeyboard(FDpy, CurrentTime);
  FKbMode := kmNone;
  FKbClient := nil;
  if (C = nil) or (FClients.IndexOf(C) < 0) then Exit;
  if not Commit then SetFrameGeometry(C, FKbX, FKbY, FKbW, FKbH);   { Escape: back to where it was }
  SendConfigure(C);
end;

procedure TWM.KbKey(var Ev: TXKeyEvent);
var
  Ks: TKeySym;
  C: TClient;
  Step, DX, DY, CW, CH: Integer;
  E: TExt;
begin
  C := FKbClient;
  if (C = nil) or (FClients.IndexOf(C) < 0) then
  begin
    EndKb(True);
    Exit;
  end;
  Ks := XLookupKeysym(@Ev, 0);
  if Ks = XK_Escape then begin EndKb(False); Exit; end;
  if (Ks = XK_Return) or (Ks = XK_KP_Enter) then begin EndKb(True); Exit; end;
  if (Ev.state and ShiftMask) <> 0 then Step := 1 else Step := 10;
  DX := 0; DY := 0;
  if Ks = XK_Left then DX := -Step
  else if Ks = XK_Right then DX := Step
  else if Ks = XK_Up then DY := -Step
  else if Ks = XK_Down then DY := Step
  else Exit;
  if FKbMode = kmMove then
  begin
    C.X := C.X + DX;
    C.Y := C.Y + DY;
    XMoveWindow(FDpy, C.Frame, C.X, C.Y);
    SendConfigure(C);
  end
  else
  begin
    E := Ext(C);
    ClientSizeOf(C, CW, CH);
    { windows that resize in steps (terminals) move one step at a time }
    if (DX <> 0) and (C.IncW > 1) and (Abs(DX) < C.IncW) then DX := DX div Abs(DX) * C.IncW;
    if (DY <> 0) and (C.IncH > 1) and (Abs(DY) < C.IncH) then DY := DY div Abs(DY) * C.IncH;
    CW := CW + DX;
    CH := CH + DY;
    ConstrainClient(C, CW, CH);
    SetFrameGeometry(C, C.X, C.Y, CW + E.L + E.R, CH + E.T + E.B);
  end;
end;

procedure TWM.OnKeyPress(var Ev: TXKeyEvent);
var
  St: cuint;
  I: Integer;
begin
  if FKbMode <> kmNone then
  begin
    KbKey(Ev);
    Exit;
  end;
  St := Ev.state and not CleanLocks;
  I := FindBinding(Ev.keycode, St);
  if FCycling then
  begin
    if I >= 0 then
      case FCfg.Keys[I].Action of
        kaCycle: StepCycle(1);
        kaCycleBack: StepCycle(-1);
      end;
    Exit;
  end;
  if I >= 0 then RunAction(FCfg.Keys[I], Ev.time);
end;

procedure TWM.OnKeyRelease(var Ev: TXKeyEvent);
var
  Rw, Cw: TWindow;
  Rx, Ry, Wx, Wy: cint;
  Mask: cuint;
begin
  if not FCycling then Exit;
  if XQueryPointer(FDpy, FRoot, @Rw, @Cw, @Rx, @Ry, @Wx, @Wy, @Mask) and ((Mask and FCycleMods) = 0) then
    EndCycle;
end;

{ ---- dragging ---- }

procedure TWM.BeginDrag(C: TClient; Kind: TDragKind; Hit: THitKind; XRoot, YRoot: Integer; ATime: culong);
var
  Cur: TCursor;
begin
  if C.Maximized or C.Fullscreen or C.Iconic then Exit;
  if (Kind = dgResize) and C.Shaded then Exit;
  FDrag := Kind;
  FDragClient := C;
  FDragHit := Hit;
  FDragPX := XRoot; FDragPY := YRoot;
  FDragX := C.X; FDragY := C.Y; FDragW := C.W; FDragH := C.H;
  if Kind = dgMove then Cur := FMoveCursor else Cur := FCursors[Hit];
  if XGrabPointer(FDpy, FRoot, 0, ButtonReleaseMask or PointerMotionMask, GrabModeAsync, GrabModeAsync,
       None, Cur, ATime) <> GrabSuccess then
    FDrag := dgNone;
  XAllowEvents(FDpy, AsyncPointer, ATime);
end;

procedure TWM.EndDrag;
begin
  if FDrag = dgNone then Exit;
  XUngrabPointer(FDpy, CurrentTime);
  if FDragClient <> nil then SendConfigure(FDragClient);
  FDrag := dgNone;
  FDragClient := nil;
end;

procedure TWM.DoMotion(XRoot, YRoot: Integer);
var
  DX, DY, NX, NY, NW, NH, CW, CH, RightEdge, BottomEdge: Integer;
  C: TClient;
  E: TExt;
  Resizing: Boolean;
begin
  C := FDragClient;
  if C = nil then Exit;
  E := Ext(C);
  DX := XRoot - FDragPX;
  DY := YRoot - FDragPY;
  if FDrag = dgMove then
  begin
    C.X := FDragX + DX;
    C.Y := FDragY + DY;
    XMoveWindow(FDpy, C.Frame, C.X, C.Y);
    SendConfigure(C);
    Exit;
  end;
  NX := FDragX; NY := FDragY; NW := FDragW; NH := FDragH;
  Resizing := False;
  if FDragHit in [hkE, hkNE, hkSE] then begin NW := FDragW + DX; Resizing := True; end;
  if FDragHit in [hkW, hkNW, hkSW] then begin NW := FDragW - DX; Resizing := True; end;
  if FDragHit in [hkS, hkSE, hkSW] then begin NH := FDragH + DY; Resizing := True; end;
  if FDragHit in [hkN, hkNE, hkNW] then begin NH := FDragH - DY; Resizing := True; end;
  if not Resizing then Exit;
  CW := NW - E.L - E.R;
  CH := NH - E.T - E.B;
  ConstrainClient(C, CW, CH);
  NW := CW + E.L + E.R;
  NH := CH + E.T + E.B;
  RightEdge := FDragX + FDragW;
  BottomEdge := FDragY + FDragH;
  { edges that are dragged from the top/left keep the opposite side fixed }
  if FDragHit in [hkW, hkNW, hkSW] then NX := RightEdge - NW;
  if FDragHit in [hkN, hkNE, hkNW] then NY := BottomEdge - NH;
  SetFrameGeometry(C, NX, NY, NW, NH);
end;

procedure TWM.DefineHitCursor(C: TClient; XF, YF: Integer);
var
  H: THit;
begin
  H := FTheme.HitTest(OptsFor(C), C.W, C.H, XF, YF);
  XDefineCursor(FDpy, C.Frame, FCursors[H.Kind]);
end;

{ ---- event handlers ---- }

procedure TWM.OnMapRequest(var Ev: TXMapRequestEvent);
var
  C: TClient;
begin
  C := FindClient(Ev.window);
  if C <> nil then
  begin
    if C.Iconic then Activate(C, CurrentTime)
    else
    begin
      XMapWindow(FDpy, C.Win);
      if OnDesk(C) then XMapWindow(FDpy, C.Frame);
    end;
    Exit;
  end;
  Manage(Ev.window, False);
end;

procedure TWM.OnConfigureRequest(var Ev: TXConfigureRequestEvent);
var
  C: TClient;
  Chg: TXWindowChanges;
  E: TExt;
  CW, CH, NX, NY: Integer;
begin
  C := FindClient(Ev.window);
  if C = nil then
  begin
    FillChar(Chg, SizeOf(Chg), 0);
    Chg.x := Ev.x; Chg.y := Ev.y; Chg.width := Ev.width; Chg.height := Ev.height;
    Chg.border_width := Ev.border_width; Chg.sibling := Ev.above; Chg.stack_mode := Ev.detail;
    XConfigureWindow(FDpy, Ev.window, Ev.value_mask, @Chg);
    Exit;
  end;
  E := Ext(C);
  if C.Maximized or C.Fullscreen then begin SendConfigure(C); Exit; end;
  if C.Shaded then SetShaded(C, False);
  ClientSizeOf(C, CW, CH);
  NX := C.X; NY := C.Y;
  if (Ev.value_mask and CWWidth) <> 0 then CW := Ev.width;
  if (Ev.value_mask and CWHeight) <> 0 then CH := Ev.height;
  if (Ev.value_mask and CWX) <> 0 then NX := Ev.x - E.L;
  if (Ev.value_mask and CWY) <> 0 then NY := Ev.y - E.T;
  ConstrainClient(C, CW, CH);
  SetFrameGeometry(C, NX, NY, CW + E.L + E.R, CH + E.T + E.B);
  if ((Ev.value_mask and CWStackMode) <> 0) and (Ev.detail = Above) then RaiseClient(C);
end;

procedure TWM.OnUnmap(var Ev: TXUnmapEvent);
var
  C: TClient;
begin
  C := FindClient(Ev.window);
  if C = nil then Exit;
  if C.IgnoreUnmap > 0 then
  begin
    Dec(C.IgnoreUnmap);
    Exit;
  end;
  Unmanage(C, False);
end;

procedure TWM.OnDestroy(var Ev: TXDestroyWindowEvent);
var
  C: TClient;
  I: Integer;
begin
  C := FindClient(Ev.window);
  if C <> nil then
  begin
    Unmanage(C, True);
    Exit;
  end;
  for I := 0 to High(FDesktops) do
    if FDesktops[I] = Ev.window then
    begin
      FDesktops[I] := FDesktops[High(FDesktops)];
      SetLength(FDesktops, Length(FDesktops) - 1);
      Break;
    end;
  for I := 0 to High(FDocks) do
    if FDocks[I].Win = Ev.window then
    begin
      FDocks[I] := FDocks[High(FDocks)];
      SetLength(FDocks, Length(FDocks) - 1);
      UpdateWorkarea;
      Break;
    end;
end;

procedure TWM.OnButtonPress(var Ev: TXButtonEvent);
var
  Rects: TButtonRects;
  K: Integer;
  C: TClient;
  H: THit;
  St: Cardinal;
  Dbl: Boolean;
begin
  St := Ev.state and not CleanLocks;
  { click inside the client area (sync grab): focus, raise, then replay }
  C := FindClient(Ev.window);
  if C <> nil then
  begin
    if ((St and Mod1Mask) <> 0) and (Ev.button in [1, 3]) then
    begin
      FocusClient(C, Ev.time);
      RaiseClient(C);
      if Ev.button = 1 then BeginDrag(C, dgMove, hkNone, Ev.x_root, Ev.y_root, Ev.time)
      else
      begin
        { Alt+right-drag resizes from the nearest corner }
        if Ev.x_root < C.X + C.W div 2 then
          if Ev.y_root < C.Y + C.H div 2 then BeginDrag(C, dgResize, hkNW, Ev.x_root, Ev.y_root, Ev.time)
          else BeginDrag(C, dgResize, hkSW, Ev.x_root, Ev.y_root, Ev.time)
        else
          if Ev.y_root < C.Y + C.H div 2 then BeginDrag(C, dgResize, hkNE, Ev.x_root, Ev.y_root, Ev.time)
          else BeginDrag(C, dgResize, hkSE, Ev.x_root, Ev.y_root, Ev.time);
      end;
      Exit;
    end;
    FocusClient(C, Ev.time);
    RaiseClient(C);
    XAllowEvents(FDpy, ReplayPointer, Ev.time);
    Exit;
  end;
  C := FindFrame(Ev.window);
  if C = nil then Exit;
  FocusClient(C, Ev.time);
  RaiseClient(C);
  H := FTheme.HitTest(OptsFor(C), C.W, C.H, Ev.x, Ev.y);
  if Ev.button = 3 then
  begin
    { right-click on the titlebar: window menu }
    if (H.Kind = hkTitle) or ((H.Kind = hkButton) and (H.Letter = 'O')) then
      OpenWindowMenu(C, Ev.x_root, Ev.y_root, Ev.time);
    Exit;
  end;
  if Ev.button <> 1 then Exit;
  case H.Kind of
    hkButton:
      if H.Letter = 'O' then
      begin
        Rects := FTheme.ButtonRects(FOpts, C.W, wsActive);
        for K := 0 to High(Rects) do
          if Rects[K].Letter = 'O' then
            OpenWindowMenu(C, C.X + Rects[K].X, C.Y + Rects[K].Y + Rects[K].H, Ev.time);
      end
      else
      begin
        FPressClient := C;
        FPressLetter := H.Letter;
      end;
    hkTitle:
      begin
        Dbl := (FLastClickWin = C.Frame) and (Ev.time - FLastClickTime < DoubleClickMs);
        FLastClickWin := C.Frame;
        FLastClickTime := Ev.time;
        if Dbl then
        begin
          FLastClickTime := 0;
          ToggleMaximize(C);
        end
        else
          BeginDrag(C, dgMove, hkNone, Ev.x_root, Ev.y_root, Ev.time);
      end;
    hkNone: ;
  else
    BeginDrag(C, dgResize, H.Kind, Ev.x_root, Ev.y_root, Ev.time);
  end;
end;

procedure TWM.OnButtonRelease(var Ev: TXButtonEvent);
var
  H: THit;
  C: TClient;
begin
  if FDrag <> dgNone then
  begin
    EndDrag;
    Exit;
  end;
  if (FPressClient <> nil) and (Ev.button = 1) then
  begin
    C := FPressClient;
    FPressClient := nil;
    if Ev.window <> C.Frame then Exit;
    H := FTheme.HitTest(OptsFor(C), C.W, C.H, Ev.x, Ev.y);
    if (H.Kind = hkButton) and (H.Letter = FPressLetter) then
      case H.Letter of
        'C': CloseClient(C);
        'M': ToggleMaximize(C);
        'H': Iconify(C);
        'S': SetShaded(C, not C.Shaded);
      end;
  end;
end;

procedure TWM.OnMotion(var Ev: TXMotionEvent);
var
  C: TClient;
begin
  if FDrag <> dgNone then
  begin
    DoMotion(Ev.x_root, Ev.y_root);
    Exit;
  end;
  C := FindFrame(Ev.window);
  if C <> nil then DefineHitCursor(C, Ev.x, Ev.y);
end;

procedure TWM.OnClientMessage(var Ev: TXClientMessageEvent);
var
  C: TClient;
  Act: clong;
  Want: Boolean;
  K: Integer;
  A: TAtom;
begin
  if (Ev.message_type = aCurDesktop) and (Ev.window = FRoot) then
  begin
    SwitchDesktop(Integer(Ev.data.l[0]), CurrentTime);
    Exit;
  end;
  C := FindClient(Ev.window);
  if C = nil then
  begin
    if Ev.message_type = aNetWmState then
      for K := 0 to High(FDocks) do
        if FDocks[K].Win = Ev.window then
        begin
          if (TAtom(Ev.data.l[1]) = aBelow) or (TAtom(Ev.data.l[2]) = aBelow) then
          begin
            case Ev.data.l[0] of
              0: FDocks[K].Below := False;
              1: FDocks[K].Below := True;
            else
              FDocks[K].Below := not FDocks[K].Below;
            end;
            Restack;
          end;
        end;
    Exit;
  end;
  if Ev.message_type = aActive then
    Activate(C, CurrentTime)
  else if Ev.message_type = aWmDesktop then
  begin
    if culong(Ev.data.l[0]) = $FFFFFFFF then MoveToDesktop(C, -1)
    else MoveToDesktop(C, Integer(Ev.data.l[0]));
  end
  else if Ev.message_type = aCloseWindow then
    CloseClient(C)
  else if Ev.message_type = aChangeState then
  begin
    if Ev.data.l[0] = IconicState then Iconify(C);
  end
  else if Ev.message_type = aNetWmState then
  begin
    Act := Ev.data.l[0];
    for K := 1 to 2 do
    begin
      A := TAtom(Ev.data.l[K]);
      if A = None then Continue;
      if (A = aMaxVert) or (A = aMaxHorz) then
      begin
        case Act of
          0: Want := False;
          1: Want := True;
        else
          Want := not C.Maximized;
        end;
        if Want <> C.Maximized then ToggleMaximize(C);
      end
      else if A = aShaded then
      begin
        case Act of
          0: Want := False;
          1: Want := True;
        else
          Want := not C.Shaded;
        end;
        SetShaded(C, Want);
      end
      else if A = aBelow then
      begin
        case Act of
          0: Want := False;
          1: Want := True;
        else
          Want := not C.Below;
        end;
        SetBelow(C, Want);
      end
      else if A = aAbove then
      begin
        case Act of
          0: Want := False;
          1: Want := True;
        else
          Want := not C.Above;
        end;
        SetAbove(C, Want);
      end
      else if A = aSticky then
      begin
        case Act of
          0: Want := False;
          1: Want := True;
        else
          Want := C.Desktop >= 0;
        end;
        if Want then MoveToDesktop(C, -1) else MoveToDesktop(C, FCurDesk);
      end
      else if A = aFullscreen then
      begin
        case Act of
          0: Want := False;
          1: Want := True;
        else
          Want := not C.Fullscreen;
        end;
        SetFullscreen(C, Want);
      end;
    end;
  end;
end;

procedure TWM.OnProperty(var Ev: TXPropertyEvent);
var
  C: TClient;
  I: Integer;
begin
  for I := 0 to High(FDocks) do
    if FDocks[I].Win = Ev.window then
    begin
      if Ev.atom = aNetWmState then
      begin
        FDocks[I].Below := HasState(Ev.window, aBelow);
        Restack;
      end
      else
      begin
        ReadStruts(FDocks[I]);
        UpdateWorkarea;
      end;
      Exit;
    end;
  C := FindClient(Ev.window);
  if C = nil then Exit;
  if (Ev.atom = aNetWmName) or (Ev.atom = XA_WM_NAME) then
  begin
    C.Name := ReadName(C.Win);
    Repaint(C, False);
  end
  else if Ev.atom = aMotif then
    SetDecorated(C, WantsDecorations(C.Win))
  else if (Ev.atom = XA_WM_NORMAL_HINTS) or (Ev.atom = XA_WM_HINTS) or (Ev.atom = aProtocols) or
          (Ev.atom = XA_WM_TRANSIENT_FOR) then
    ReadHints(C);
end;

procedure TWM.HandleEvent(var Ev: TXEvent);
var
  MenuId: Integer;
  R: TMenuResult;
begin
  if FMenu.IsOpen then
  begin
    R := FMenu.HandleEvent(Ev, MenuId);
    if R = mrSelected then RunMenuAction(MenuId);
    if R <> mrNone then Exit;
  end;
  case Ev._type of
    MapRequest: OnMapRequest(Ev.xmaprequest);
    ConfigureRequest: OnConfigureRequest(Ev.xconfigurerequest);
    UnmapNotify: OnUnmap(Ev.xunmap);
    DestroyNotify: OnDestroy(Ev.xdestroywindow);
    KeyPress: OnKeyPress(Ev.xkey);
    KeyRelease: OnKeyRelease(Ev.xkey);
    ButtonPress: OnButtonPress(Ev.xbutton);
    ButtonRelease: OnButtonRelease(Ev.xbutton);
    MotionNotify: OnMotion(Ev.xmotion);
    ClientMessage: OnClientMessage(Ev.xclient);
    PropertyNotify: OnProperty(Ev.xproperty);
  end;
end;

procedure TWM.Run;
var
  NewCfg: TConfig;
  Ev, Nx: TXEvent;
  Fds: TFDSet;
  Fd: cint;
  Tv: TTimeVal;
begin
  ScanExisting;
  Fd := ConnectionNumber(FDpy);
  XSync(FDpy, 0);
  while not FQuit do
  begin
    while XPending(FDpy) > 0 do
    begin
      XNextEvent(FDpy, @Ev);
      { drags generate floods of motion: keep only the newest }
      if Ev._type = MotionNotify then
        while XCheckTypedEvent(FDpy, MotionNotify, @Nx) do Ev := Nx;
      try
        HandleEvent(Ev);
      except
        { a bug in one handler must not take the whole session down }
        on E: Exception do
          LogInfo(Format('EXCEPTION %s in event type %d: %s', [E.ClassName, Ev._type, E.Message]));
      end;
    end;
    if FReload then
    begin
      FReload := False;
      NewCfg := LoadConfig(FCfg.Path);
      FCfg.Keys := NewCfg.Keys;
      GrabKeys;
      Log(Format('reloaded key bindings from %s (%d bindings, %d warnings)',
        [FCfg.Path, Length(FCfg.Keys), Length(NewCfg.Warnings)]));
    end;
    XFlush(FDpy);
    fpFD_ZERO(Fds);
    fpFD_SET(Fd, Fds);
    Tv.tv_sec := 0;
    Tv.tv_usec := 100000;
    fpSelect(Fd + 1, @Fds, nil, nil, @Tv);
  end;
end;

procedure TWM.Shutdown;
var
  I: Integer;
  C: TClient;
  E: TExt;
begin
  if FDrag <> dgNone then EndDrag;
  if FCycling then EndCycle;
  { give every client back to the root so nothing is lost with the frames }
  for I := FClients.Count - 1 downto 0 do
  begin
    C := TClient(FClients[I]);
    E := Ext(C);
    XUnmapWindow(FDpy, C.Frame);
    XReparentWindow(FDpy, C.Win, FRoot, C.X + E.L, C.Y + E.T);
    XRemoveFromSaveSet(FDpy, C.Win);
    XMapWindow(FDpy, C.Win);
    XDeleteProperty(FDpy, C.Win, aFrameExtents);
    XDeleteProperty(FDpy, C.Win, aNetWmState);
    XDestroyWindow(FDpy, C.Frame);
  end;
  XDeleteProperty(FDpy, FRoot, aActive);
  XDeleteProperty(FDpy, FRoot, aClientList);
  XDeleteProperty(FDpy, FRoot, aClientListStk);
  XDeleteProperty(FDpy, FRoot, aSupportingCheck);
  XDeleteProperty(FDpy, FRoot, aSupported);
  XDestroyWindow(FDpy, FCheckWin);
  XSetInputFocus(FDpy, FRoot, RevertToPointerRoot, CurrentTime);
  XSync(FDpy, 0);
end;

end.
