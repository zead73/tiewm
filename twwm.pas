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
  twimage, twtheme, twxft, twxdraw, twxshape, twxrandr, twconfig, twlog, twmenu;

type
  TClient = class
    Win, Frame: TWindow;
    X, Y, W, H: Integer;          { frame outer geometry, root relative }
    Name: string;
    IgnoreUnmap: Integer;         { unmaps we caused ourselves }
    InputHint, HasDelete, HasTakeFocus, HasPing: Boolean;
    PingSent: culong;             { server time of the last _NET_WM_PING we sent, 0 = answered or none }
    PingTick: Int64;              { our own clock (ms) when it was sent }
    MinW, MinH, MaxW, MaxH, IncW, IncH, BaseW, BaseH: Integer;   { client sizes }
    MinAspX, MinAspY, MaxAspX, MaxAspY: Integer;                  { aspect-ratio limits (width:height), 0 = none }
    Leader: TWindow;              { WM_CLIENT_LEADER: the window that names this window's group, 0 = none }
    UrgentHint: Boolean;          { WM_HINTS urgency bit is set }
    Gravity: Integer;             { ICCCM win_gravity: 1 NorthWest (default) .. 9 SouthEast, 10 Static }
    Maximized, Fullscreen, Iconic, Above, Below, Shaded, Modal, StartIconic: Boolean;
    Extra: array of TAtom;        { other _NET_WM_STATE atoms the app set (skip_taskbar...): kept as they are }
    Decorated: Boolean;           { False: no frame graphics at all (the app draws its own) }
    ResName, ResClass: string;    { WM_CLASS: instance and class }
    Icon: TImg;                   { scaled _NET_WM_ICON for the menu button, nil = none set }
    HoverLetter, PressLetter: Char;     { titlebar button under the pointer / being held down, #0 = none }
    PaintedHover, PaintedPress: Char;
    PaintedToggled: string;
    DecorUser: Integer;           { 0 = follow the app's hints, 1 = user wants a titlebar, 2 = user wants none }
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
    LeftY0, LeftY1, RightY0, RightY1, TopX0, TopX1, BotX0, BotX1: Integer;   { _NET_WM_STRUT_PARTIAL ranges }
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
    FMon: TMonitorList;     { the monitors, left to right }
    FLastPoll: Int64;
    FRandrBase: Integer;    { RandR event base, -1 = no RandR }
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
    aHidden, aFullscreen, aWmDesktop, aBelow, aAbove, aShaded, aSticky, aDeskNames, aMotif, aNetWmIcon, aModal, aSkipTaskbar, aSkipPager, aDemandsAttn: TAtom;
    aPing, aClientLeader, aMoveResize, aMoveResizeWin, aAllowed, aReqExtents, aTypeSplash: TAtom;
    aCompSel, aCompMove: TAtom;    { hints for a compositor that asks for them, see SendMoveHint }
    aCompCube, aKeepsMapped: TAtom;
    { set while a compositor wants windows of other workspaces left mapped }
    FKeepOwner: TWindow;
    FActions: array[0..11] of TAtom;
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
    FGenericIcon: TImg;
    FIconSize: Integer;
    FMenu: TPopupMenu;
    FMenuFont: TTitleFont;
    FMenuClient: TClient;
    FCycleMods: cuint;
    FReload: Boolean;
    FCycling: Boolean;
    FCycleList: TList;
    FCycleIdx: Integer;
    FFocusCand: TClient;     { focus-follows-mouse: the window the pointer entered, waiting for its delay }
    FFocusDue: Int64;
    FCycleWin: TWindow;      { the Alt+Tab list while cycling, 0 = not shown }
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
    procedure WorkAreaOf(M: Integer; out AX, AY, AW, AH: Integer);
    procedure RefreshMonitors;
    procedure LogMonitors;
    procedure ApplyScreenChange;
    procedure PollMonitors;
    function MonitorAt(PX, PY: Integer): Integer;
    function InsideAnyMonitor(PX, PY: Integer): Boolean;
    function MonitorOf(C: TClient): Integer;
    function PointerMonitor: Integer;
    procedure OnScreenChange(var Ev: TXEvent);
    procedure MoveToMonitor(C: TClient; Dir: Integer);
    procedure MoveToMonitorIndex(C: TClient; Dst: Integer);
    procedure OnEnter(var Ev: TXCrossingEvent);
    procedure PollFocusFollow;
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
    procedure SendProtocol(C: TClient; Proto: TAtom);
    procedure ToggleMaximize(C: TClient);
    procedure SetFullscreen(C: TClient; On: Boolean);
    procedure SetAbove(C: TClient; On: Boolean);
    procedure SetBelow(C: TClient; On: Boolean);
    procedure SetShaded(C: TClient; On: Boolean);
    function WantsDecorations(Win: TWindow): Boolean;
    procedure ReadClass(C: TClient);
    procedure ReadStates(C: TClient; out Sticky, Full: Boolean);
    function ExtraHas(C: TClient; A: TAtom): Boolean;
    procedure ExtraSet(C: TClient; A: TAtom; On: Boolean);
    function WmStateOf(Win: TWindow): Integer;
    function ModalBlocker(C: TClient): TClient;
    function ResolveModal(C: TClient): TClient;
    procedure ReadIcon(C: TClient);
    function ShowIcon: Boolean;
    procedure SetHover(C: TClient; L: Char);
    procedure OnLeave(var Ev: TXCrossingEvent);
    function HitFor(C: TClient; X, Y: Integer): THit;
    procedure SaveDecorRule(C: TClient);
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
    procedure DrawCycleList;
    procedure HideCycleList;
    procedure UpdateClientList;
    procedure SetWmState(C: TClient; State: Integer);
    procedure UpdateNetState(C: TClient);
    procedure SetAllowedActions(C: TClient);
    procedure GravityFrame(C: TClient; ReqX, ReqY: Integer; const E: TExt; out FX, FY: Integer);
    procedure Place(C: TClient; HasPos: Boolean; CX, CY: Integer);
    procedure BeginDrag(C: TClient; Kind: TDragKind; Hit: THitKind; XRoot, YRoot: Integer; ATime: culong);
    procedure EndDrag;
    procedure ShowFrame(C: TClient);
    procedure CheckKeepMapped;
    procedure SetKeepOwner(Owner: TWindow);
    procedure SendMoveHint(C: TClient; Starting: Boolean; GrabX, GrabY: Integer);
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
    procedure ReplyFrameExtents(Win: TWindow);
    procedure OnMoveResize(C: TClient; var Ev: TXClientMessageEvent);
    procedure OnMoveResizeWindow(C: TClient; var Ev: TXClientMessageEvent);
    procedure ApplyRequest(C: TClient; Mask: culong; RX, RY, RW, RH: Integer);
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

{ a plain window glyph for applications that set no icon }
function MakeGenericIcon(Size: Integer): TImg;
var
  X, Y: Integer;
  Col: LongWord;
begin
  Result := TImg.Create(Size, Size);
  for Y := 1 to Size - 3 do
    for X := 1 to Size - 2 do
    begin
      if (X = 1) or (X = Size - 2) or (Y = 1) or (Y = Size - 3) then Col := $FF6A7380
      else if Y <= 4 then Col := $FF5A7FB5
      else Col := $FFE9ECEF;
      Result.SetPx(X, Y, Col);
    end;
end;

{ Area-averaged scale of an ARGB icon into a Size x Size image, keeping the aspect ratio. }
function ScaleIcon(Src: PCULong; W, H, Size: Integer): TImg;
var
  DW, DH, OX, OY, DX, DY, SX, SY, X0, X1, Y0, Y1, Cnt: Integer;
  SumA, SumR, SumG, SumB: Int64;
  P: LongWord;
  A: Int64;
begin
  Result := TImg.Create(Size, Size);
  if W >= H then begin DW := Size; DH := Size * H div W; end
  else begin DH := Size; DW := Size * W div H; end;
  if DW < 1 then DW := 1;
  if DH < 1 then DH := 1;
  OX := (Size - DW) div 2;
  OY := (Size - DH) div 2;
  for DY := 0 to DH - 1 do
    for DX := 0 to DW - 1 do
    begin
      X0 := DX * W div DW; X1 := (DX + 1) * W div DW; if X1 <= X0 then X1 := X0 + 1;
      Y0 := DY * H div DH; Y1 := (DY + 1) * H div DH; if Y1 <= Y0 then Y1 := Y0 + 1;
      SumA := 0; SumR := 0; SumG := 0; SumB := 0; Cnt := 0;
      for SY := Y0 to Y1 - 1 do
        for SX := X0 to X1 - 1 do
        begin
          P := LongWord(Src[SY * W + SX] and $FFFFFFFF);
          A := P shr 24;
          SumA := SumA + A;
          SumR := SumR + ((P shr 16) and 255) * A;
          SumG := SumG + ((P shr 8) and 255) * A;
          SumB := SumB + (P and 255) * A;
          Inc(Cnt);
        end;
      if (SumA > 0) and (Cnt > 0) then
        Result.SetPx(OX + DX, OY + DY,
          (LongWord(SumA div Cnt) shl 24) or (LongWord(SumR div SumA) shl 16) or
          (LongWord(SumG div SumA) shl 8) or LongWord(SumB div SumA));
    end;
end;

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
  FallbackName: string;
begin
  inherited Create;
  FCfg := ACfg;
  FDpy := ADpy;
  FScr := DefaultScreen(FDpy);
  FRoot := DefaultRootWindow(FDpy);
  FScrW := DisplayWidth(FDpy, FScr);
  FScrH := DisplayHeight(FDpy, FScr);
  FRandrBase := -1;
  if HaveRandR(FDpy, FRandrBase) then XRRSelectInput(FDpy, FRoot, RRScreenChangeNotifyMask or RRCrtcChangeNotifyMask or RROutputChangeNotifyMask)
  else FRandrBase := -1;
  RefreshMonitors;
  LogMonitors;
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
  FTheme := TXfwmTheme.Create;
  { a wrong theme name must not take the session down: fall back to Daloa, then Default }
  if not FTheme.Load(FCfg.Theme, FCfg.Palette) then
  begin
    FallbackName := '';
    if (FCfg.Theme <> 'Daloa') and FTheme.Load('Daloa', FCfg.Palette) then FallbackName := 'Daloa'
    else if (FCfg.Theme <> 'Default') and FTheme.Load('Default', FCfg.Palette) then FallbackName := 'Default';
    if FallbackName = '' then
      raise Exception.Create('no xfwm4 theme found (looked in ~/.themes, /usr/share/themes and /usr/local/share/themes): ' +
        'install xfwm4 (it ships Daloa and Default) or put a theme in ~/.themes');
    LogInfo('xfwm4 theme "' + FCfg.Theme + '" not found, using ' + FallbackName);
    WriteLn(StdErr, 'tiewm: xfwm4 theme "', FCfg.Theme, '" not found, using ', FallbackName);
    Flush(StdErr);
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
  FIconSize := FTheme.MenuIconSize;
  FGenericIcon := MakeGenericIcon(FIconSize);
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
  FGenericIcon.Free;
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
  aNetWmIcon := A('_NET_WM_ICON');
  aModal := A('_NET_WM_STATE_MODAL');
  aSkipTaskbar := A('_NET_WM_STATE_SKIP_TASKBAR');
  aSkipPager := A('_NET_WM_STATE_SKIP_PAGER');
  aDemandsAttn := A('_NET_WM_STATE_DEMANDS_ATTENTION');
  aMoveResize := A('_NET_WM_MOVERESIZE'); aMoveResizeWin := A('_NET_MOVERESIZE_WINDOW');
  aPing := A('_NET_WM_PING');
  aClientLeader := A('WM_CLIENT_LEADER');
  aAllowed := A('_NET_WM_ALLOWED_ACTIONS'); aReqExtents := A('_NET_REQUEST_FRAME_EXTENTS');
  aTypeSplash := A('_NET_WM_WINDOW_TYPE_SPLASH');
  aCompSel := A('_TIECOMP_S' + IntToStr(FScr)); aCompMove := A('_TIECOMP_MOVE');
  aCompCube := A('_TIECOMP_CUBE'); aKeepsMapped := A('_TIEWM_KEEPS_MAPPED');
  FActions[0] := A('_NET_WM_ACTION_MOVE'); FActions[1] := A('_NET_WM_ACTION_RESIZE');
  FActions[2] := A('_NET_WM_ACTION_MINIMIZE'); FActions[3] := A('_NET_WM_ACTION_SHADE');
  FActions[4] := A('_NET_WM_ACTION_STICK'); FActions[5] := A('_NET_WM_ACTION_MAXIMIZE_HORZ');
  FActions[6] := A('_NET_WM_ACTION_MAXIMIZE_VERT'); FActions[7] := A('_NET_WM_ACTION_FULLSCREEN');
  FActions[8] := A('_NET_WM_ACTION_CHANGE_DESKTOP'); FActions[9] := A('_NET_WM_ACTION_CLOSE');
  FActions[10] := A('_NET_WM_ACTION_ABOVE'); FActions[11] := A('_NET_WM_ACTION_BELOW');
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
  { N is unsigned: an empty list (N = 0) must not turn "N - 1" into a huge loop bound }
  I := 0;
  while I < N do
  begin
    Result.Add(Pointer(PtrUInt(PCULong(D)[I])));
    Inc(I);
  end;
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

{ Maps or unmaps a frame to suit its workspace. With a compositor that draws
  the other workspaces (a desktop cube), their frames stay mapped, so they have
  contents, but take no pointer input and are not drawn by it elsewhere. }
procedure TWM.ShowFrame(C: TClient);
begin
  if OnDesk(C) then
  begin
    XShapeCombineMask(FDpy, C.Frame, ShapeInput, 0, 0, None, ShapeSet);
    XMapWindow(FDpy, C.Frame);
  end
  else if FKeepOwner <> None then
  begin
    { an empty input region first, so it can never be clicked while up }
    XShapeCombineRectangles(FDpy, C.Frame, ShapeInput, 0, 0, nil, 0, ShapeSet, 0);
    XMapWindow(FDpy, C.Frame);
  end
  else XUnmapWindow(FDpy, C.Frame);
end;

procedure TWM.ApplyVisibility(C: TClient);
begin
  if C.Iconic then Exit;
  ShowFrame(C);
end;

{ A compositor asks by owning _TIECOMP_S<screen> and putting _TIECOMP_CUBE = 1
  on that window. We answer with _TIEWM_KEEPS_MAPPED on the root, naming our
  check window, so that it knows we complied and that we are still here. }
procedure TWM.CheckKeepMapped;
var
  Owner: TWindow;
  D: PByte;
  N: culong;
begin
  Owner := XGetSelectionOwner(FDpy, aCompSel);
  if Owner <> None then
  begin
    D := GetProp(Owner, aCompCube, XA_CARDINAL, N);
    if (D = nil) or (N < 1) or (PCULong(D)[0] <> 1) then Owner := None;
    if D <> nil then XFree(D);
  end;
  SetKeepOwner(Owner);
end;

procedure TWM.SetKeepOwner(Owner: TWindow);
var
  I: Integer;
begin
  if Owner = FKeepOwner then Exit;
  FKeepOwner := Owner;
  { its DestroyNotify (it is a child of the root) tells us if it dies }
  for I := 0 to FClients.Count - 1 do ApplyVisibility(TClient(FClients[I]));
  if Owner <> None then SetCards(FRoot, aKeepsMapped, [culong(FCheckWin)])
  else XDeleteProperty(FDpy, FRoot, aKeepsMapped);
  Log(Format('keeping other workspaces mapped: %d', [Ord(Owner <> None)]));
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
  if C.Decorated then Repaint(C, False);
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
  D.LeftY0 := 0; D.LeftY1 := MaxInt; D.RightY0 := 0; D.RightY1 := MaxInt;
  D.TopX0 := 0; D.TopX1 := MaxInt; D.BotX0 := 0; D.BotX1 := MaxInt;
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
    if N >= 12 then
    begin
      D.LeftY0 := PCULong(Data)[4]; D.LeftY1 := PCULong(Data)[5];
      D.RightY0 := PCULong(Data)[6]; D.RightY1 := PCULong(Data)[7];
      D.TopX0 := PCULong(Data)[8]; D.TopX1 := PCULong(Data)[9];
      D.BotX0 := PCULong(Data)[10]; D.BotX1 := PCULong(Data)[11];
    end;
  end;
  if Data <> nil then XFree(Data);
end;

{ ---- monitors ---- }

procedure TWM.RefreshMonitors;
begin
  FMon := nil;
  if FRandrBase >= 0 then FMon := QueryMonitors(FDpy, FRoot);
  if Length(FMon) = 0 then
  begin
    SetLength(FMon, 1);
    FMon[0].X := 0; FMon[0].Y := 0; FMon[0].W := FScrW; FMon[0].H := FScrH; FMon[0].Primary := True;
  end;
end;

procedure TWM.LogMonitors;
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := 0 to High(FMon) do
    S := S + Format(' %dx%d+%d+%d', [FMon[I].W, FMon[I].H, FMon[I].X, FMon[I].Y]);
  Log(Format('screen %dx%d, %d monitor(s):%s', [FScrW, FScrH, Length(FMon), S]));
end;

function TWM.InsideAnyMonitor(PX, PY: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FMon) do
    if (PX >= FMon[I].X) and (PX < FMon[I].X + FMon[I].W) and (PY >= FMon[I].Y) and (PY < FMon[I].Y + FMon[I].H) then
      Exit(True);
  Result := False;
end;

{ the monitor containing the point, else the nearest one }
function TWM.MonitorAt(PX, PY: Integer): Integer;
var
  I, DX, DY, D, Best: Integer;
begin
  Result := 0;
  Best := MaxInt;
  for I := 0 to High(FMon) do
  begin
    DX := 0; DY := 0;
    if PX < FMon[I].X then DX := FMon[I].X - PX
    else if PX >= FMon[I].X + FMon[I].W then DX := PX - (FMon[I].X + FMon[I].W - 1);
    if PY < FMon[I].Y then DY := FMon[I].Y - PY
    else if PY >= FMon[I].Y + FMon[I].H then DY := PY - (FMon[I].Y + FMon[I].H - 1);
    D := DX * DX + DY * DY;
    if D < Best then begin Best := D; Result := I; end;
  end;
end;

function TWM.MonitorOf(C: TClient): Integer;
begin
  Result := MonitorAt(C.X + C.W div 2, C.Y + C.H div 2);
end;

function TWM.PointerMonitor: Integer;
var
  Rw, Cw: TWindow;
  Rx, Ry, Wx, Wy: cint;
  Mask: cuint;
begin
  Result := 0;
  if XQueryPointer(FDpy, FRoot, @Rw, @Cw, @Rx, @Ry, @Wx, @Wy, @Mask) then Result := MonitorAt(Rx, Ry);
end;

{ the area of monitor M that docks leave free: a strut reserves a band along a screen edge
  (over the range its partial strut names), and counts for M where that band reaches into it }
procedure TWM.WorkAreaOf(M: Integer; out AX, AY, AW, AH: Integer);
var
  I, L, R, T, B, V, MR, MB: Integer;
  Mn: TMonitor;
begin
  Mn := FMon[M];
  MR := Mn.X + Mn.W;
  MB := Mn.Y + Mn.H;
  L := Mn.X; R := MR; T := Mn.Y; B := MB;
  for I := 0 to High(FDocks) do
  begin
    with FDocks[I] do
    begin
      if (Left > 0) and (LeftY0 < MB) and (LeftY1 >= Mn.Y) then begin V := Left; if V > L then L := V; end;
      if (Right > 0) and (RightY0 < MB) and (RightY1 >= Mn.Y) then begin V := FScrW - Right; if V < R then R := V; end;
      if (Top > 0) and (TopX0 < MR) and (TopX1 >= Mn.X) then begin V := Top; if V > T then T := V; end;
      if (Bottom > 0) and (BotX0 < MR) and (BotX1 >= Mn.X) then begin V := FScrH - Bottom; if V < B then B := V; end;
    end;
  end;
  if L > MR - 1 then L := MR - 1;
  if T > MB - 1 then T := MB - 1;
  if R < L + 1 then R := L + 1;
  if B < T + 1 then B := T + 1;
  AX := L; AY := T; AW := R - L; AH := B - T;
end;

{ the work area of the whole desktop: the box around every monitor's free area }
procedure TWM.WorkArea(out AX, AY, AW, AH: Integer);
var
  I, X, Y, W, H, X0, Y0, X1, Y1: Integer;
begin
  X0 := MaxInt; Y0 := MaxInt; X1 := -MaxInt; Y1 := -MaxInt;
  for I := 0 to High(FMon) do
  begin
    WorkAreaOf(I, X, Y, W, H);
    if X < X0 then X0 := X;
    if Y < Y0 then Y0 := Y;
    if X + W > X1 then X1 := X + W;
    if Y + H > Y1 then Y1 := Y + H;
  end;
  AX := X0; AY := Y0; AW := X1 - X0; AH := Y1 - Y0;
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
  Atoms: array[0..29] of TAtom;
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
  Atoms[21] := aModal; Atoms[22] := aSkipTaskbar; Atoms[23] := aSkipPager; Atoms[24] := aDemandsAttn;
  Atoms[25] := aBelow; Atoms[26] := aMoveResize; Atoms[27] := aMoveResizeWin;
  Atoms[28] := aAllowed; Atoms[29] := aReqExtents;
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
  V: array of TAtom;
  I: Integer;

  procedure Put(A: TAtom);
  begin
    SetLength(V, Length(V) + 1);
    V[High(V)] := A;
  end;

begin
  SetLength(V, 0);
  if C.Modal then Put(aModal);
  if C.Below then Put(aBelow);
  if C.Shaded then Put(aShaded);
  if C.Above then Put(aAbove);
  if C.Desktop < 0 then Put(aSticky);
  if C.Maximized then begin Put(aMaxVert); Put(aMaxHorz); end;
  if C.Fullscreen then Put(aFullscreen);
  if C.Iconic then Put(aHidden);
  for I := 0 to High(C.Extra) do Put(C.Extra[I]);
  if Length(V) = 0 then
    XDeleteProperty(FDpy, C.Win, aNetWmState)
  else
    XChangeProperty(FDpy, C.Win, aNetWmState, XA_ATOM, 32, PropModeReplace, PByte(@V[0]), Length(V));
  SetAllowedActions(C);
end;

{ _NET_WM_ALLOWED_ACTIONS: what a taskbar / pager may offer for this window }
procedure TWM.SetAllowedActions(C: TClient);
var
  V: array[0..11] of TAtom;
  N, I: Integer;
  Fixed: Boolean;
begin
  Fixed := (C.MinW >= C.MaxW) and (C.MinH >= C.MaxH);
  N := 0;
  for I := 0 to 11 do
  begin
    case I of
      1, 5, 6: if Fixed then Continue;          { a window of fixed size cannot be resized or maximized }
      3: if not C.Decorated then Continue;       { nothing to roll up to }
    end;
    V[N] := FActions[I];
    Inc(N);
  end;
  XChangeProperty(FDpy, C.Win, aAllowed, XA_ATOM, 32, PropModeReplace, PByte(@V[0]), N);
end;

function TWM.ExtraHas(C: TClient; A: TAtom): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(C.Extra) do
    if C.Extra[I] = A then Exit(True);
  Result := False;
end;

procedure TWM.ExtraSet(C: TClient; A: TAtom; On: Boolean);
var
  I, N: Integer;
begin
  if On then
  begin
    if ExtraHas(C, A) then Exit;
    SetLength(C.Extra, Length(C.Extra) + 1);
    C.Extra[High(C.Extra)] := A;
  end
  else
  begin
    N := 0;
    for I := 0 to High(C.Extra) do
      if C.Extra[I] <> A then
      begin
        C.Extra[N] := C.Extra[I];
        Inc(N);
      end;
    SetLength(C.Extra, N);
  end;
end;

{ The states an application sets before mapping its window. Everything tiewm does not manage itself
  (skip_taskbar, skip_pager, demands_attention, ...) is remembered and written back, so the panel
  still sees it. Fullscreen is honoured too (games and Wine set it only this way); maximized/shaded/hidden
  are not, and are requested by client message after mapping. }
procedure TWM.ReadStates(C: TClient; out Sticky, Full: Boolean);
var
  L: TList;
  I: Integer;
  A: TAtom;
begin
  Sticky := False;
  Full := False;
  SetLength(C.Extra, 0);
  L := GetAtoms(C.Win, aNetWmState);
  try
    for I := 0 to L.Count - 1 do
    begin
      A := TAtom(PtrUInt(L[I]));
      if A = aModal then C.Modal := True
      else if A = aAbove then C.Above := True
      else if A = aBelow then C.Below := True
      else if A = aSticky then Sticky := True
      else if A = aFullscreen then Full := True
      else if (A = aMaxVert) or (A = aMaxHorz) or (A = aShaded) or (A = aHidden) then
      begin
        { not honoured at map time }
      end
      else ExtraSet(C, A, True);
    end;
    if C.Above and C.Below then C.Below := False;
  finally
    L.Free;
  end;
end;

{ the WM_STATE a previous window manager left on a window, -1 if there is none }
function TWM.WmStateOf(Win: TWindow): Integer;
var
  D: PByte;
  N: culong;
begin
  Result := -1;
  D := GetProp(Win, aWmState, aWmState, N);
  if D = nil then Exit;
  if N >= 1 then Result := Integer(PCULong(D)[0]);
  XFree(D);
end;

{ A modal dialog blocks the window it is transient for: that window cannot be focused while the
  dialog is up (focus goes to the dialog), and clicks on it are swallowed. }
function TWM.ModalBlocker(C: TClient): TClient;
var
  I: Integer;
  M: TClient;
begin
  for I := FClients.Count - 1 downto 0 do
  begin
    M := TClient(FClients[I]);
    if (M <> C) and M.Modal and (not M.Iconic) and OnDesk(M) then
    begin
      if M.Transient = C.Win then Exit(M);
      { a modal window that names no parent blocks the rest of its group (same WM_CLIENT_LEADER) }
      if (M.Transient = 0) and (M.Leader <> 0) and (C.Leader = M.Leader) and (C.Transient <> M.Win) then Exit(M);
    end;
  end;
  Result := nil;
end;

{ follows a chain of modal dialogs (dialog over dialog over the main window) to the top one }
function TWM.ResolveModal(C: TClient): TClient;
var
  B: TClient;
  Depth: Integer;
begin
  Result := C;
  for Depth := 1 to 8 do
  begin
    B := ModalBlocker(Result);
    if B = nil then Exit;
    Result := B;
  end;
end;

procedure TWM.ReadHints(C: TClient);
var
  Sz: TXSizeHints;
  Supplied: clong;
  Wm: PXWMHints;
  Prots: PAtom;
  NProt, I: cint;
  TWin: TWindow;
  Urg: Boolean;
  LeadData: PByte;
  LeadN: culong;
begin
  Urg := False;
  C.MinW := 1; C.MinH := 1; C.MaxW := 65535; C.MaxH := 65535;
  C.IncW := 1; C.IncH := 1; C.BaseW := 0; C.BaseH := 0;
  C.Gravity := 1;
  C.MinAspX := 0; C.MinAspY := 0; C.MaxAspX := 0; C.MaxAspY := 0;
  FillChar(Sz, SizeOf(Sz), 0);
  if XGetWMNormalHints(FDpy, C.Win, @Sz, @Supplied) <> 0 then
  begin
    if ((Sz.flags and PWinGravity) <> 0) and (Sz.win_gravity >= 1) and (Sz.win_gravity <= 10) then
      C.Gravity := Sz.win_gravity;
    if (Sz.flags and PAspect) <> 0 then
    begin
      C.MinAspX := Sz.min_aspect.x; C.MinAspY := Sz.min_aspect.y;
      C.MaxAspX := Sz.max_aspect.x; C.MaxAspY := Sz.max_aspect.y;
    end;
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
  C.StartIconic := False;
  Wm := XGetWMHints(FDpy, C.Win);
  if Wm <> nil then
  begin
    if (Wm^.flags and InputHint) <> 0 then C.InputHint := Wm^.input <> 0;
    if ((Wm^.flags and StateHint) <> 0) and (Wm^.initial_state = IconicState) then C.StartIconic := True;
    Urg := (Wm^.flags and XUrgencyHint) <> 0;
    XFree(Wm);
  end;
  { the urgency bit is shown to the panel as _NET_WM_STATE_DEMANDS_ATTENTION }
  if Urg <> C.UrgentHint then
  begin
    C.UrgentHint := Urg;
    ExtraSet(C, aDemandsAttn, Urg);
    if C.Frame <> 0 then UpdateNetState(C);
  end;
  C.Leader := 0;
  LeadData := GetProp(C.Win, aClientLeader, XA_WINDOW, LeadN);
  if LeadData <> nil then
  begin
    if LeadN >= 1 then C.Leader := PCULong(LeadData)[0];
    XFree(LeadData);
  end;
  C.Transient := 0;
  TWin := 0;
  if (XGetTransientForHint(FDpy, C.Win, @TWin) <> 0) and (TWin <> FRoot) and (TWin <> C.Win) then
    C.Transient := TWin;
  C.HasDelete := False;
  C.HasTakeFocus := False;
  C.HasPing := False;
  Prots := nil;
  NProt := 0;
  if (XGetWMProtocols(FDpy, C.Win, @Prots, @NProt) <> 0) and (Prots <> nil) then
  begin
    for I := 0 to NProt - 1 do
    begin
      if Prots[I] = aDelete then C.HasDelete := True;
      if Prots[I] = aTakeFocus then C.HasTakeFocus := True;
      if Prots[I] = aPing then C.HasPing := True;
    end;
    XFree(Prots);
  end;
end;

{ ---- geometry ---- }

function TWM.Ext(C: TClient): TExt;
var
  M: TThemeMetrics;
begin
  if C.Fullscreen or ((not C.Decorated) and (C.Maximized or (FCfg.UndecoratedBorder = 0))) then
  begin
    Result.L := 0; Result.R := 0; Result.T := 0; Result.B := 0;
  end
  else if not C.Decorated then
  begin
    { windows without a titlebar get an optional thin resize border }
    Result.L := FCfg.UndecoratedBorder; Result.R := FCfg.UndecoratedBorder;
    Result.T := FCfg.UndecoratedBorder; Result.B := FCfg.UndecoratedBorder;
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
  { aspect ratio (width : height): shrink whichever side is too long }
  if (C.MaxAspX > 0) and (C.MaxAspY > 0) and (CH > 0) and (CW * C.MaxAspY > CH * C.MaxAspX) then
    CW := CH * C.MaxAspX div C.MaxAspY;
  if (C.MinAspX > 0) and (C.MinAspY > 0) and (CW * C.MinAspY < CH * C.MinAspX) then
    CH := CW * C.MinAspY div C.MinAspX;
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
  PressNow: Char;
  IconNow: TImg;
  Tg: string;
begin
  if C.Fullscreen then Exit;
  Act := C = FFocused;
  if not C.Decorated then
  begin
    { no frame graphics; only the optional solid resize border changes with focus }
    if (Ext(C).L > 0) and ((not C.Painted) or (C.PaintedActive <> Act) or Force) then
    begin
      if Act then XSetWindowBackground(FDpy, C.Frame, FCfg.Palette.Color1[wsActive] and $FFFFFF)
      else XSetWindowBackground(FDpy, C.Frame, FCfg.Palette.Color1[wsInactive] and $FFFFFF);
      XClearWindow(FDpy, C.Frame);
    end;
    C.Painted := True;
    C.PaintedActive := Act;
    Exit;
  end;
  { a button shows "pressed" only while the pointer is still over it }
  if C.PressLetter = C.HoverLetter then PressNow := C.PressLetter else PressNow := #0;
  IconNow := nil;
  if ShowIcon then
  begin
    if C.Icon <> nil then IconNow := C.Icon else IconNow := FGenericIcon;
  end;
  { buttons drawn in their toggled form: rolled up, on all workspaces, maximized }
  Tg := '';
  if C.Shaded then Tg := Tg + 'S';
  if C.Desktop = -1 then Tg := Tg + 'T';
  if C.Maximized then Tg := Tg + 'M';
  if (not Force) and C.Painted and (C.PaintedToggled = Tg) and (C.PaintedActive = Act) and (C.PaintedW = C.W) and
     (C.PaintedH = C.H) and (C.PaintedName = C.Name) and (C.PaintedHover = C.HoverLetter) and
     (C.PaintedPress = PressNow) then Exit;
  if Act then
    Pm := PaintFrameEx(FDpy, FScr, FTheme, FFont, wsActive, C.W, C.H, C.Name, TitleAlign, C.Shaded, C.HoverLetter, PressNow, IconNow, Tg, Mask, TX, BY)
  else
    Pm := PaintFrameEx(FDpy, FScr, FTheme, FFont, wsInactive, C.W, C.H, C.Name, TitleAlign, C.Shaded, C.HoverLetter, PressNow, IconNow, Tg, Mask, TX, BY);
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
  C.PaintedHover := C.HoverLetter;
  C.PaintedPress := PressNow;
  C.PaintedToggled := Tg;
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
  if Resized or (not C.Decorated) then
    XMoveResizeWindow(FDpy, C.Win, Ext(C).L, Ext(C).T, CW, CH);   { extents can change (maximize) }
  if Resized then Repaint(C, True);
  SendConfigure(C);
end;

{ ICCCM window gravity: where the frame goes so that the position an app asked
  for (the client window's own x,y) is honoured the way its win_gravity says.
  NorthWest (the default): the frame's top-left corner is at x,y. Static: the
  client itself is at x,y and the frame extends up and left of it. }
procedure TWM.GravityFrame(C: TClient; ReqX, ReqY: Integer; const E: TExt; out FX, FY: Integer);
begin
  case C.Gravity of
    2, 5, 8: FX := ReqX - (E.L + E.R) div 2;
    3, 6, 9: FX := ReqX - (E.L + E.R);
    10: FX := ReqX - E.L;
  else
    FX := ReqX;
  end;
  case C.Gravity of
    4, 5, 6: FY := ReqY - (E.T + E.B) div 2;
    7, 8, 9: FY := ReqY - (E.T + E.B);
    10: FY := ReqY - E.T;
  else
    FY := ReqY;
  end;
end;

procedure TWM.Place(C: TClient; HasPos: Boolean; CX, CY: Integer);
var
  AX, AY, AW, AH, Mn: Integer;
  P: TClient;
  E: TExt;
begin
  E := Ext(C);
  P := FindClient(C.Transient);
  if HasPos then
  begin
    GravityFrame(C, CX, CY, E, C.X, C.Y);
    Mn := MonitorAt(C.X + C.W div 2, C.Y + C.H div 2);
  end
  else
  begin
    { a dialog opens on its parent's monitor, anything else on the one the pointer is on }
    if P <> nil then Mn := MonitorOf(P) else Mn := PointerMonitor;
    WorkAreaOf(Mn, AX, AY, AW, AH);
    C.X := AX + (AW - C.W) div 2;
    C.Y := AY + (AH - C.H) div 2;
    if P <> nil then
    begin
      C.X := P.X + (P.W - C.W) div 2;
      C.Y := P.Y + (P.H - C.H) div 2;
    end;
  end;
  WorkAreaOf(Mn, AX, AY, AW, AH);
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
  RuleTb: Boolean;
  StickyInit, FullInit: Boolean;
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
  ReadClass(C);
  { adopting a window a previous WM had minimized, or an app that asks to start minimized }
  if Startup then C.StartIconic := (Atr.map_state = IsUnmapped) and (WmStateOf(Win) = IconicState);
  ReadStates(C, StickyInit, FullInit);
  ReadIcon(C);
  C.Decorated := WantsDecorations(Win) and not WindowTypeIs(Win, aTypeSplash);
  { a rule from the config file (matched by WM_CLASS) beats the app's own hints }
  if FindWindowRule(FCfg, C.ResName, C.ResClass, RuleTb) then
  begin
    C.Decorated := RuleTb;
    if RuleTb then C.DecorUser := 1 else C.DecorUser := 2;
  end;
  E := Ext(C);
  C.Desktop := ReadDesktopProp(Win);
  if C.Desktop = -2 then
  begin
    if StickyInit then C.Desktop := -1
    else if FindClient(C.Transient) <> nil then C.Desktop := FindClient(C.Transient).Desktop
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
    PointerMotionMask or ExposureMask or EnterWindowMask or LeaveWindowMask);
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
  if C.StartIconic then
  begin
    C.Iconic := True;                { stays unmapped until the user restores it }
    SetWmState(C, IconicState);
  end
  else
  begin
    XMapWindow(FDpy, Win);
    ShowFrame(C);
    SetWmState(C, NormalState);
  end;
  SetDesktopProp(C);
  SetCards(Win, aFrameExtents, [culong(E.L), culong(E.R), culong(E.T), culong(E.B)]);
  { writes the state and the frame extents itself; a window that starts minimized stays that way }
  if FullInit and not C.StartIconic then SetFullscreen(C, True)
  else UpdateNetState(C);
  SendConfigure(C);
  UpdateClientList;
  Log(Format('managed 0x%x "%s" frame 0x%x at %d,%d %dx%d%s%s', [Win, C.Name, C.Frame, C.X, C.Y, C.W, C.H,
    IfThen(C.Decorated, '', ' (no decorations)'), IfThen(C.StartIconic, ' (minimized)', '')]));
  if (not Startup) and OnDesk(C) and (not C.StartIconic) then FocusClient(C, CurrentTime);
  if C.Above or C.Below then Restack;
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
  C.Icon.Free;
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
           ((Atr.map_state = IsViewable) or
            ((Atr.map_state = IsUnmapped) and (WmStateOf(Kids[I]) = IconicState) and (Kids[I] <> FCheckWin))) then
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
  C := ResolveModal(C);        { a window with a modal dialog open cannot take the focus }
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
  if ExtraHas(C, aDemandsAttn) then        { looking at it satisfies the request }
  begin
    ExtraSet(C, aDemandsAttn, False);
    UpdateNetState(C);
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

{ Sends a ClientMessage of WM_PROTOCOLS type to a client. }
procedure TWM.SendProtocol(C: TClient; Proto: TAtom);
var
  Ev: TXEvent;
begin
  FillChar(Ev, SizeOf(Ev), 0);
  Ev.xclient._type := ClientMessage;
  Ev.xclient.window := C.Win;
  Ev.xclient.message_type := aProtocols;
  Ev.xclient.format := 32;
  Ev.xclient.data.l[0] := clong(Proto);
  Ev.xclient.data.l[1] := clong(CurrentTime);
  Ev.xclient.data.l[2] := clong(C.Win);
  XSendEvent(FDpy, C.Win, 0, NoEventMask, @Ev);
end;

{ Asks the app to close. If it supports _NET_WM_PING we also ping it: a window that has not
  answered a ping sent more than 3 seconds ago is hung, and closing it again kills it. }
procedure TWM.CloseClient(C: TClient);
begin
  if C.HasDelete then
  begin
    if C.HasPing and (C.PingSent <> 0) and (GetTickCount64 - C.PingTick > 3000) then
    begin
      Log(Format('0x%x did not answer a ping: killing it', [C.Win]));
      XKillClient(FDpy, C.Win);
      Exit;
    end;
    if C.HasPing and (C.PingSent = 0) then
    begin
      C.PingSent := 1;
      C.PingTick := GetTickCount64;
      SendProtocol(C, aPing);
    end;
    SendProtocol(C, aDelete);
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
    WorkAreaOf(MonitorOf(C), AX, AY, AW, AH);
    C.Maximized := True;
    SetFrameGeometry(C, AX, AY, AW, AH);
  end;
  UpdateNetState(C);
  if not C.Decorated then SetFrameExtentsProp(C);   { the thin border goes away while maximized }
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
function TWM.ShowIcon: Boolean;
begin
  if FCfg.ShowAppIcon >= 0 then Result := FCfg.ShowAppIcon = 1
  else Result := FTheme.RCBool('show_app_icon', False);
end;

{ _NET_WM_ICON: a list of icons, each width, height, then width*height ARGB pixels. The
  smallest one that is at least IconSize wide is used, else the biggest. }
procedure TWM.ReadIcon(C: TClient);
var
  ActType: TAtom;
  ActFmt: cint;
  N, After: culong;
  Data: PByte;
  P: PCULong;
  Pos, W, H, BestPos, BestW, BestH: culong;
  BestArea, Area: Int64;
  Found, BestBigEnough: Boolean;
begin
  FreeAndNil(C.Icon);
  Data := nil;
  if (XGetWindowProperty(FDpy, C.Win, aNetWmIcon, 0, 1048576, 0, XA_CARDINAL, @ActType, @ActFmt, @N, @After,
        @Data) <> Success) or (ActType = None) or (Data = nil) then
  begin
    if Data <> nil then XFree(Data);
    Exit;
  end;
  try
    P := PCULong(Data);
    Pos := 0;
    Found := False;
    BestBigEnough := False;
    BestArea := 0; BestPos := 0; BestW := 0; BestH := 0;
    while Pos + 2 <= N do
    begin
      W := P[Pos]; H := P[Pos + 1];
      if (W = 0) or (H = 0) or (W > 1024) or (H > 1024) or (Pos + 2 + W * H > N) then Break;
      Area := Int64(W) * Int64(H);
      if (W >= FIconSize) and (H >= FIconSize) then
      begin
        if (not BestBigEnough) or (Area < BestArea) then
        begin
          BestBigEnough := True; BestArea := Area; BestPos := Pos; BestW := W; BestH := H; Found := True;
        end;
      end
      else if (not BestBigEnough) and ((not Found) or (Area > BestArea)) then
      begin
        BestArea := Area; BestPos := Pos; BestW := W; BestH := H; Found := True;
      end;
      Inc(Pos, 2 + W * H);
    end;
    if Found then C.Icon := ScaleIcon(@P[BestPos + 2], BestW, BestH, FIconSize);
  finally
    XFree(Data);
  end;
end;

procedure TWM.ReadClass(C: TClient);
var
  H: TXClassHint;
begin
  C.ResName := '';
  C.ResClass := '';
  FillChar(H, SizeOf(H), 0);
  if XGetClassHint(FDpy, C.Win, @H) <> 0 then
  begin
    if H.res_name <> nil then begin C.ResName := H.res_name; XFree(H.res_name); end;
    if H.res_class <> nil then begin C.ResClass := H.res_class; XFree(H.res_class); end;
  end;
end;

{ Remembers the user's titlebar choice for this application in the config file: a rule is
  written only when the choice differs from what the app asks for on its own; choosing
  what the app asks for removes the rule again. }
procedure TWM.SaveDecorRule(C: TClient);
var
  Name, Err: string;
  Mode: TRuleMode;
begin
  if C.ResClass <> '' then Name := C.ResClass else Name := C.ResName;
  if Name = '' then
  begin
    Log('no WM_CLASS: the titlebar choice for "' + C.Name + '" cannot be saved');
    Exit;
  end;
  if C.Decorated = WantsDecorations(C.Win) then Mode := rmRemove
  else if C.Decorated then Mode := rmTitlebar
  else Mode := rmNoTitlebar;
  if WriteWindowRule(FCfg.Path, Name, Mode, Err) then
  begin
    SetRuleInMemory(FCfg, Name, Mode);
    case Mode of
      rmRemove: Log('config: removed the window rule for ' + Name);
      rmTitlebar: Log('config: ' + Name + ' = titlebar saved to ' + FCfg.Path);
      rmNoTitlebar: Log('config: ' + Name + ' = no_titlebar saved to ' + FCfg.Path);
    end;
  end
  else
    Log('config: could not save the titlebar rule: ' + Err);
end;

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
    WorkAreaOf(MonitorOf(C), AX, AY, AW, AH);
    C.X := AX; C.Y := AY; C.W := AW; C.H := AH;
    ClientSizeOf(C, CW, CH);
  end
  else
  begin
    C.X := CX - E.L;
    C.Y := CY - E.T;
    C.W := CW + E.L + E.R;
    C.H := CH + E.T + E.B;
    { a titlebar that would land off the top/left of the work area is pushed back in }
    WorkAreaOf(MonitorOf(C), AX, AY, AW, AH);
    if C.Y < AY then C.Y := AY;
    if C.X < AX then C.X := AX;
  end;
  XMoveResizeWindow(FDpy, C.Frame, C.X, C.Y, C.W, C.H);
  XMoveResizeWindow(FDpy, C.Win, E.L, E.T, CW, CH);
  if not On then
  begin
    C.Painted := False;
    XShapeCombineMask(FDpy, C.Frame, ShapeBounding, 0, 0, None, ShapeSet);   { plain rectangle }
  end;
  Repaint(C, True);   { frame graphics, or just the thin border colour }
  SetFrameExtentsProp(C);
  SendConfigure(C);
  Log(Format('0x%x "%s": titlebar %s', [C.Win, C.Name, IfThen(On, 'on', 'off')]));
end;

{ What is under the point X,Y of C's frame: the theme's hit test for decorated windows, a thin
  resize border for undecorated ones. The corner zones run 16 px along the edges. }
function TWM.HitFor(C: TClient; X, Y: Integer): THit;
const
  CornerZone = 16;
var
  B, W, H: Integer;
begin
  if C.Decorated then Exit(FTheme.HitTest(OptsFor(C), C.W, C.H, X, Y));
  Result.Kind := hkNone;
  Result.Letter := #0;
  B := Ext(C).L;
  W := C.W;
  H := C.H;
  if (B = 0) or (X < 0) or (Y < 0) or (X >= W) or (Y >= H) then Exit;
  if Y < B then
  begin
    if X < CornerZone then Result.Kind := hkNW
    else if X >= W - CornerZone then Result.Kind := hkNE
    else Result.Kind := hkN;
  end
  else if Y >= H - B then
  begin
    if X < CornerZone then Result.Kind := hkSW
    else if X >= W - CornerZone then Result.Kind := hkSE
    else Result.Kind := hkS;
  end
  else if X < B then
  begin
    if Y < CornerZone then Result.Kind := hkNW
    else if Y >= H - CornerZone then Result.Kind := hkSW
    else Result.Kind := hkW;
  end
  else if X >= W - B then
  begin
    if Y < CornerZone then Result.Kind := hkNE
    else if Y >= H - CornerZone then Result.Kind := hkSE
    else Result.Kind := hkE;
  end;
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
  ShowFrame(C);
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
  AX, AY, AW, AH, NX, NY, NW, NH, CW, CH, Mn: Integer;
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
    Mn := MonitorOf(C);      { fullscreen fills the monitor the window is on }
    C.Fullscreen := True;
    C.X := FMon[Mn].X; C.Y := FMon[Mn].Y; C.W := FMon[Mn].W; C.H := FMon[Mn].H;
    XMoveResizeWindow(FDpy, C.Frame, C.X, C.Y, C.W, C.H);
    XMoveResizeWindow(FDpy, C.Win, 0, 0, C.W, C.H);
    XShapeCombineMask(FDpy, C.Frame, ShapeBounding, 0, 0, None, ShapeSet);   { no shape: plain rectangle }
    C.Painted := False;
    RaiseClient(C);
  end
  else
  begin
    Mn := MonitorOf(C);
    C.Fullscreen := False;
    if C.Maximized then
    begin
      WorkAreaOf(Mn, AX, AY, AW, AH);
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
  mnNoTitle = 9;
  mnBelow = 8;
  mnShade = 7;
  mnMinimize = 1;
  mnMaximize = 2;
  mnFullscreen = 3;
  mnAbove = 4;
  mnSticky = 5;
  mnClose = 6;
  mnDesktop = 100;     { + 0-based desktop }
  mnMonitor = 200;     { + 0-based monitor }

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
  FMenu.Add(mnNoTitle, 'No titlebar', not C.Decorated, True);
  FMenu.AddSeparator;
  for K := 0 to FNumDesk - 1 do
    FMenu.Add(mnDesktop + K, 'Move to Workspace ' + IntToStr(K + 1), C.Desktop = K, C.Desktop <> K);
  if Length(FMon) > 1 then
  begin
    FMenu.AddSeparator;
    for K := 0 to High(FMon) do
      FMenu.Add(mnMonitor + K, 'Move to Monitor ' + IntToStr(K + 1), MonitorOf(C) = K, (MonitorOf(C) <> K) and not C.Iconic);
  end;
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
  else if Id = mnNoTitle then
  begin
    { the user's choice wins over whatever the app asks for from now on }
    if C.Decorated then C.DecorUser := 2 else C.DecorUser := 1;
    SetDecorated(C, C.DecorUser = 1);
    SaveDecorRule(C);
  end
  else if Id = mnBelow then SetBelow(C, not C.Below)
  else if Id = mnSticky then
  begin
    if C.Desktop < 0 then MoveToDesktop(C, FCurDesk) else MoveToDesktop(C, -1);
  end
  else if Id = mnClose then CloseClient(C)
  else if (Id >= mnDesktop) and (Id < mnDesktop + FNumDesk) then MoveToDesktop(C, Id - mnDesktop)
  else if (Id >= mnMonitor) and (Id < mnMonitor + Length(FMon)) then MoveToMonitorIndex(C, Id - mnMonitor);
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
    kaAbove: if FFocused <> nil then SetAbove(FFocused, not FFocused.Above);
    kaMonitorNext: if FFocused <> nil then MoveToMonitor(FFocused, 1);
    kaMonitorPrev: if FFocused <> nil then MoveToMonitor(FFocused, -1);
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
  if FCycling then DrawCycleList;
end;

{ The Alt+Tab list: one row per window in cycling order, the selected one highlighted
  (xfwm4's "list" tab window). An override-redirect window drawn in one pixmap. }
procedure TWM.DrawCycleList;
const
  Pad = 12;
  MaxRows = 16;
var
  I, First, Rows, RowH, W, H, TW, MaxTW, X, Y, Mn, AX, AY, AW, AH: Integer;
  C: TClient;
  Pm: TPixmap;
  GC: TGC;
  Pal: TThemePalette;
  Attr: TXSetWindowAttributes;
  Txt: string;
  Col: LongWord;
begin
  Pal := FCfg.Palette;
  Rows := FCycleList.Count;
  if Rows > MaxRows then Rows := MaxRows;
  First := FCycleIdx - Rows + 1;       { keep the selected row inside the visible part }
  if First < 0 then First := 0;
  RowH := FMenuFont.Ascent + FMenuFont.Descent + 10;
  Mn := PointerMonitor;
  WorkAreaOf(Mn, AX, AY, AW, AH);
  MaxTW := AW * 6 div 10 - 2 * Pad;
  TW := 160;
  for I := First to First + Rows - 1 do
  begin
    C := TClient(FCycleList[I]);
    Txt := C.Name;
    if C.Iconic then Txt := Txt + '  (minimized)';
    if FMenuFont.Width(Txt) > TW then TW := FMenuFont.Width(Txt);
  end;
  if TW > MaxTW then TW := MaxTW;
  W := TW + 2 * Pad + 2;
  H := Rows * RowH + 2;
  X := AX + (AW - W) div 2;
  Y := AY + (AH - H) div 2;
  if FCycleWin = 0 then
  begin
    FCycleWin := XCreateSimpleWindow(FDpy, FRoot, X, Y, W, H, 0, 0, 0);
    Attr.override_redirect := 1;
    XChangeWindowAttributes(FDpy, FCycleWin, CWOverrideRedirect, @Attr);
  end
  else
    XMoveResizeWindow(FDpy, FCycleWin, X, Y, W, H);
  Pm := XCreatePixmap(FDpy, FRoot, W, H, DefaultDepth(FDpy, FScr));
  GC := XCreateGC(FDpy, Pm, 0, nil);
  XSetForeground(FDpy, GC, Pal.Color1[wsActive] and $FFFFFF);            { 1 px border }
  XFillRectangle(FDpy, Pm, GC, 0, 0, W, H);
  XSetForeground(FDpy, GC, Pal.Color2[wsActive] and $FFFFFF);
  XFillRectangle(FDpy, Pm, GC, 1, 1, W - 2, H - 2);
  for I := 0 to Rows - 1 do
  begin
    C := TClient(FCycleList[First + I]);
    if First + I = FCycleIdx then
    begin
      XSetForeground(FDpy, GC, Pal.Color1[wsActive] and $FFFFFF);
      XFillRectangle(FDpy, Pm, GC, 1, 1 + I * RowH, W - 2, RowH);
      Col := Pal.TextColor[wsActive] and $FFFFFF;
    end
    else if C.Iconic then Col := Pal.TextColor[wsInactive] and $FFFFFF
    else Col := Pal.Text2Color[wsActive] and $FFFFFF;
    Txt := C.Name;
    if C.Iconic then Txt := Txt + '  (minimized)';
    Txt := FMenuFont.Fit(Txt, TW);
    FMenuFont.Draw(Pm, DefaultVisual(FDpy, FScr), DefaultColormap(FDpy, FScr), 1 + Pad,
      1 + I * RowH + 5 + FMenuFont.Ascent, Txt, Col, smNone, 0);
  end;
  XFreeGC(FDpy, GC);
  XSetWindowBackgroundPixmap(FDpy, FCycleWin, Pm);
  XFreePixmap(FDpy, Pm);
  XMapRaised(FDpy, FCycleWin);
  XClearWindow(FDpy, FCycleWin);
end;

procedure TWM.HideCycleList;
begin
  if FCycleWin <> 0 then
  begin
    XDestroyWindow(FDpy, FCycleWin);
    FCycleWin := 0;
  end;
end;

procedure TWM.EndCycle;
begin
  HideCycleList;
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
  if FDrag = dgMove then SendMoveHint(C, True, XRoot - C.X, YRoot - C.Y);
end;

procedure TWM.EndDrag;
begin
  if FDrag = dgNone then Exit;
  XUngrabPointer(FDpy, CurrentTime);
  if (FDrag = dgMove) and (FDragClient <> nil) then SendMoveHint(FDragClient, False, 0, 0);
  if FDragClient <> nil then SendConfigure(FDragClient);
  FDrag := dgNone;
  FDragClient := nil;
end;

{ Tells a compositor that wants to know when a window is being dragged, so it
  can animate the move (tiecomp's wobbly windows). It asks by owning the
  _TIECOMP_S<screen> selection; with no owner nothing is sent. A _TIECOMP_MOVE
  client message to the owner carries: the frame, 1 at the start or 0 at the
  end, and where in the frame the pointer holds it. }
procedure TWM.SendMoveHint(C: TClient; Starting: Boolean; GrabX, GrabY: Integer);
var
  Owner: TWindow;
  Ev: TXEvent;
begin
  Owner := XGetSelectionOwner(FDpy, aCompSel);
  if Owner = None then Exit;
  FillChar(Ev, SizeOf(Ev), 0);
  Ev.xclient._type := ClientMessage;
  Ev.xclient.window := C.Frame;
  Ev.xclient.message_type := aCompMove;
  Ev.xclient.format := 32;
  Ev.xclient.data.l[0] := C.Frame;
  Ev.xclient.data.l[1] := Ord(Starting);
  Ev.xclient.data.l[2] := GrabX;
  Ev.xclient.data.l[3] := GrabY;
  XSendEvent(FDpy, Owner, False, 0, @Ev);
  LogDebug(Format('move hint frame=0x%x start=%d grab=%d,%d', [C.Frame, Ord(Starting), GrabX, GrabY]));
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
  H := HitFor(C, XF, YF);
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
      ShowFrame(C);
    end;
    Exit;
  end;
  Manage(Ev.window, False);
end;

{ Applies a position/size request (X,Y,W,H are the client window's, in the
  Mask CWX/CWY/CWWidth/CWHeight bits) the way the window's gravity says. }
procedure TWM.ApplyRequest(C: TClient; Mask: culong; RX, RY, RW, RH: Integer);
var
  E: TExt;
  CW, CH, NX, NY, GX, GY: Integer;
begin
  E := Ext(C);
  if C.Maximized or C.Fullscreen then begin SendConfigure(C); Exit; end;
  if C.Shaded then SetShaded(C, False);
  ClientSizeOf(C, CW, CH);
  NX := C.X; NY := C.Y;
  if (Mask and CWWidth) <> 0 then CW := RW;
  if (Mask and CWHeight) <> 0 then CH := RH;
  ConstrainClient(C, CW, CH);
  GravityFrame(C, RX, RY, E, GX, GY);
  { gravity anchors the frame on the right / bottom for the east / south kinds }
  if (Mask and CWX) <> 0 then NX := GX;
  if (Mask and CWY) <> 0 then NY := GY;
  SetFrameGeometry(C, NX, NY, CW + E.L + E.R, CH + E.T + E.B);
end;

procedure TWM.OnConfigureRequest(var Ev: TXConfigureRequestEvent);
var
  C: TClient;
  Chg: TXWindowChanges;
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
  ApplyRequest(C, Ev.value_mask, Ev.x, Ev.y, Ev.width, Ev.height);
  if ((Ev.value_mask and CWStackMode) <> 0) and (Ev.detail = Above) then RaiseClient(C);
end;

{ _NET_MOVERESIZE_WINDOW (wmctrl -e): data.l = flags, x, y, width, height.
  flags: low byte gravity (0 = the window's own), bits 8-11 = x y width height present. }
procedure TWM.OnMoveResizeWindow(C: TClient; var Ev: TXClientMessageEvent);
var
  Fl: culong;
  Mask: culong;
  Saved: Integer;
begin
  Fl := culong(Ev.data.l[0]);
  Mask := 0;
  if (Fl and (1 shl 8)) <> 0 then Mask := Mask or CWX;
  if (Fl and (1 shl 9)) <> 0 then Mask := Mask or CWY;
  if (Fl and (1 shl 10)) <> 0 then Mask := Mask or CWWidth;
  if (Fl and (1 shl 11)) <> 0 then Mask := Mask or CWHeight;
  if Mask = 0 then Exit;
  Saved := C.Gravity;
  if ((Fl and 255) >= 1) and ((Fl and 255) <= 10) then C.Gravity := Integer(Fl and 255);
  try
    ApplyRequest(C, Mask, Integer(Ev.data.l[1]), Integer(Ev.data.l[2]), Integer(Ev.data.l[3]), Integer(Ev.data.l[4]));
  finally
    C.Gravity := Saved;
  end;
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
  { the compositor that wanted windows kept mapped is gone: unmap them again,
    or they would all show at once }
  if (FKeepOwner <> None) and (Ev.window = FKeepOwner) then
  begin
    SetKeepOwner(None);
    Exit;
  end;
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
    if ModalBlocker(C) <> nil then
      XAllowEvents(FDpy, AsyncPointer, Ev.time)     { blocked by a modal dialog: the app never sees the click }
    else
      XAllowEvents(FDpy, ReplayPointer, Ev.time);
    Exit;
  end;
  C := FindFrame(Ev.window);
  if C = nil then Exit;
  FocusClient(C, Ev.time);
  RaiseClient(C);
  H := HitFor(C, Ev.x, Ev.y);
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
        C.HoverLetter := H.Letter;
        C.PressLetter := H.Letter;
        Repaint(C, False);
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
    C.PressLetter := #0;
    if FClients.IndexOf(C) >= 0 then Repaint(C, False);
    if Ev.window <> C.Frame then Exit;
    H := HitFor(C, Ev.x, Ev.y);
    if (H.Kind = hkButton) and (H.Letter = FPressLetter) then
      case H.Letter of
        'C': CloseClient(C);
        'M': ToggleMaximize(C);
        'H': Iconify(C);
        'S': SetShaded(C, not C.Shaded);
        'T': if C.Desktop = -1 then MoveToDesktop(C, FCurDesk) else MoveToDesktop(C, -1);
      end;
  end;
end;

procedure TWM.SetHover(C: TClient; L: Char);
begin
  if C.HoverLetter = L then Exit;
  C.HoverLetter := L;
  if C.Decorated then Repaint(C, False);
end;

procedure TWM.OnLeave(var Ev: TXCrossingEvent);
var
  C: TClient;
begin
  C := FindFrame(Ev.window);
  if C <> nil then
  begin
    SetHover(C, #0);
    if (FFocusCand = C) and (Ev.detail <> NotifyInferior) then FFocusCand := nil;
  end;
end;

{ focus-follows-mouse: entering a window starts a timer; PollFocusFollow focuses it when it expires }
procedure TWM.OnEnter(var Ev: TXCrossingEvent);
var
  C: TClient;
begin
  if not FCfg.FocusFollows then Exit;
  if (Ev.mode <> NotifyNormal) or (Ev.detail = NotifyInferior) then Exit;
  C := FindFrame(Ev.window);
  if (C = nil) or (C = FFocused) or C.Iconic then begin FFocusCand := nil; Exit; end;
  FFocusCand := C;
  FFocusDue := GetTickCount64 + FCfg.FocusDelay;
end;

procedure TWM.PollFocusFollow;
begin
  if FFocusCand = nil then Exit;
  if GetTickCount64 < FFocusDue then Exit;
  if (FClients.IndexOf(FFocusCand) >= 0) and (FDrag = dgNone) and (FKbMode = kmNone) and (not FCycling) and
     (not FMenu.IsOpen) and VisibleNow(FFocusCand) then
    FocusClient(FFocusCand, CurrentTime);
  FFocusCand := nil;
end;

procedure TWM.OnMotion(var Ev: TXMotionEvent);
var
  C: TClient;
  H: THit;
begin
  if FDrag <> dgNone then
  begin
    DoMotion(Ev.x_root, Ev.y_root);
    Exit;
  end;
  C := FindFrame(Ev.window);
  if C <> nil then
  begin
    DefineHitCursor(C, Ev.x, Ev.y);
    if C.Decorated then
    begin
      H := HitFor(C, Ev.x, Ev.y);
      if H.Kind = hkButton then SetHover(C, H.Letter) else SetHover(C, #0);
    end;
  end;
end;

{ _NET_WM_MOVERESIZE: an app (client-side decorations, frameless Qt windows)
  asks us to start a move or resize that it cannot run itself.
  data.l = x_root, y_root, direction, button, source. }
procedure TWM.OnMoveResize(C: TClient; var Ev: TXClientMessageEvent);
const
  Dirs: array[0..7] of THitKind = (hkNW, hkN, hkNE, hkE, hkSE, hkS, hkSW, hkW);
var
  Dir: Integer;
  Rw, Cw: TWindow;
  Rx, Ry, Wx, Wy: cint;
  Mask: cuint;
begin
  Dir := Integer(Ev.data.l[2]);
  if Dir = 11 then    { _NET_WM_MOVERESIZE_CANCEL }
  begin
    if (FDrag <> dgNone) and (FDragClient = C) then
    begin
      SetFrameGeometry(C, FDragX, FDragY, FDragW, FDragH);
      EndDrag;
    end
    else if (FKbMode <> kmNone) and (FKbClient = C) then EndKb(False);
    Exit;
  end;
  if (FDrag <> dgNone) or (FKbMode <> kmNone) or FMenu.IsOpen then Exit;
  if (Dir = 9) or (Dir = 10) then    { keyboard variants: same as Alt+F8 / Alt+F7 }
  begin
    if C <> FFocused then FocusClient(C, CurrentTime);
    if Dir = 9 then StartKb(kmResize, CurrentTime) else StartKb(kmMove, CurrentTime);
    Exit;
  end;
  if (Dir < 0) or (Dir > 8) then Exit;
  { the request is only valid while a button is held; a stale one would
    leave us waiting for a release that never comes }
  if not XQueryPointer(FDpy, FRoot, @Rw, @Cw, @Rx, @Ry, @Wx, @Wy, @Mask) then Exit;
  Log(Format('moveresize dir=%d mask=%x', [Dir, Mask]));
  if (Mask and (Button1Mask or Button2Mask or Button3Mask)) = 0 then Exit;
  RaiseClient(C);
  if Dir = 8 then
    BeginDrag(C, dgMove, hkNone, Rx, Ry, CurrentTime)
  else
    BeginDrag(C, dgResize, Dirs[Dir], Rx, Ry, CurrentTime);
  Log(Format('moveresize drag=%d', [Ord(FDrag)]));
end;

{ _NET_REQUEST_FRAME_EXTENTS: a toolkit asks, before mapping, how thick our frame will be }
procedure TWM.ReplyFrameExtents(Win: TWindow);
var
  C: TClient;
  E: TExt;
  Tmp: Boolean;
begin
  C := FindClient(Win);
  Tmp := C = nil;
  if Tmp then
  begin
    C := TClient.Create;
    C.Win := Win;
    C.Decorated := WantsDecorations(Win) and not WindowTypeIs(Win, aTypeSplash);
  end;
  try
    E := Ext(C);
    SetCards(Win, aFrameExtents, [culong(E.L), culong(E.R), culong(E.T), culong(E.B)]);
  finally
    if Tmp then C.Free;
  end;
end;

procedure TWM.OnClientMessage(var Ev: TXClientMessageEvent);
var
  C: TClient;
  Act: clong;
  Want: Boolean;
  K: Integer;
  A: TAtom;
begin
  if Ev.message_type = aCompCube then
  begin
    CheckKeepMapped;
    Exit;
  end;
  if (Ev.message_type = aCurDesktop) and (Ev.window = FRoot) then
  begin
    SwitchDesktop(Integer(Ev.data.l[0]), CurrentTime);
    Exit;
  end;
  if Ev.message_type = aReqExtents then
  begin
    ReplyFrameExtents(Ev.window);
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
  if (Ev.message_type = aProtocols) and (TAtom(Ev.data.l[0]) = aPing) then
    C.PingSent := 0      { the app answered }
  else if Ev.message_type = aActive then
    Activate(C, CurrentTime)
  else if Ev.message_type = aMoveResize then
    OnMoveResize(C, Ev)
  else if Ev.message_type = aMoveResizeWin then
    OnMoveResizeWindow(C, Ev)
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
      else if A = aModal then
      begin
        case Act of
          0: Want := False;
          1: Want := True;
        else
          Want := not C.Modal;
        end;
        C.Modal := Want;
        UpdateNetState(C);
        if Want then FocusClient(C, CurrentTime);
      end
      else if (A = aSkipTaskbar) or (A = aSkipPager) or (A = aDemandsAttn) then
      begin
        case Act of
          0: Want := False;
          1: Want := True;
        else
          Want := not ExtraHas(C, A);
        end;
        ExtraSet(C, A, Want);
        UpdateNetState(C);
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
  else if Ev.atom = aNetWmIcon then
  begin
    ReadIcon(C);
    if C.Decorated then Repaint(C, True);
  end
  else if Ev.atom = aMotif then
  begin
    if C.DecorUser = 0 then SetDecorated(C, WantsDecorations(C.Win));
  end
  else if (Ev.atom = XA_WM_NORMAL_HINTS) or (Ev.atom = XA_WM_HINTS) or (Ev.atom = aProtocols) or
          (Ev.atom = XA_WM_TRANSIENT_FOR) then
    ReadHints(C);
end;

{ Moves a window to the monitor on its right (Dir = 1) or left, keeping its place relative to the
  monitor's corner; maximized and fullscreen windows refit to the new monitor. }
procedure TWM.MoveToMonitor(C: TClient; Dir: Integer);
begin
  MoveToMonitorIndex(C, MonitorOf(C) + Dir);    { monitors are ordered left to right; no wrapping round }
end;

procedure TWM.MoveToMonitorIndex(C: TClient; Dst: Integer);
var
  Src, AX, AY, AW, AH, NX, NY, NW, NH: Integer;
begin
  if (Length(FMon) < 2) or C.Iconic then Exit;
  Src := MonitorOf(C);
  if (Dst < 0) or (Dst >= Length(FMon)) or (Dst = Src) then Exit;
  if C.Fullscreen then
  begin
    C.X := FMon[Dst].X; C.Y := FMon[Dst].Y; C.W := FMon[Dst].W; C.H := FMon[Dst].H;
    XMoveResizeWindow(FDpy, C.Frame, C.X, C.Y, C.W, C.H);
    XMoveResizeWindow(FDpy, C.Win, 0, 0, C.W, C.H);
    SendConfigure(C);
    Exit;
  end;
  WorkAreaOf(Dst, AX, AY, AW, AH);
  if C.Maximized then
  begin
    SetFrameGeometry(C, AX, AY, AW, AH);
    Exit;
  end;
  NW := C.W; NH := C.H;
  if C.Shaded then NH := C.H else
  begin
    if NW > AW then NW := AW;
    if NH > AH then NH := AH;
  end;
  NX := FMon[Dst].X + (C.X - FMon[Src].X);
  NY := FMon[Dst].Y + (C.Y - FMon[Src].Y);
  if NX + NW > AX + AW then NX := AX + AW - NW;
  if NY + NH > AY + AH then NY := AY + AH - NH;
  if NX < AX then NX := AX;
  if NY < AY then NY := AY;
  SetFrameGeometry(C, NX, NY, NW, NH);
  RaiseClient(C);
end;

{ RandR says the screen layout changed (monitor plugged or unplugged, resolution changed):
  refresh the monitor list, refit fullscreen and maximized windows, and pull windows that are
  now off every monitor back onto the nearest one }
procedure TWM.OnScreenChange(var Ev: TXEvent);
begin
  if Ev._type = FRandrBase + RRScreenChangeNotify then XRRUpdateConfiguration(@Ev);
  ApplyScreenChange;
end;

{ servers send no event when a client defines monitors (xrandr --setmonitor), so the main
  loop also looks every couple of seconds }
procedure TWM.PollMonitors;
var
  Now: Int64;
begin
  if FRandrBase < 0 then Exit;
  Now := GetTickCount64;
  if Now - FLastPoll < 2000 then Exit;
  FLastPoll := Now;
  ApplyScreenChange;
end;

procedure TWM.ApplyScreenChange;
var
  I, Mn, AX, AY, AW, AH, NX, NY: Integer;
  C: TClient;
  CW, CH, OldW, OldH: Integer;
  Old: TMonitorList;
  Same: Boolean;
begin
  OldW := FScrW; OldH := FScrH;
  Old := FMon;
  FScrW := DisplayWidth(FDpy, FScr);
  FScrH := DisplayHeight(FDpy, FScr);
  FMon := nil;
  RefreshMonitors;
  Same := (OldW = FScrW) and (OldH = FScrH) and (Length(Old) = Length(FMon));
  if Same then
    for I := 0 to High(Old) do
      if (Old[I].X <> FMon[I].X) or (Old[I].Y <> FMon[I].Y) or (Old[I].W <> FMon[I].W) or (Old[I].H <> FMon[I].H) then
        Same := False;
  if Same then Exit;
  LogMonitors;
  SetCards(FRoot, aDeskGeom, [culong(FScrW), culong(FScrH)]);
  UpdateWorkarea;
  for I := 0 to FClients.Count - 1 do
  begin
    C := TClient(FClients[I]);
    Mn := MonitorOf(C);
    if C.Fullscreen then
    begin
      C.X := FMon[Mn].X; C.Y := FMon[Mn].Y; C.W := FMon[Mn].W; C.H := FMon[Mn].H;
      XMoveResizeWindow(FDpy, C.Frame, C.X, C.Y, C.W, C.H);
      XMoveResizeWindow(FDpy, C.Win, 0, 0, C.W, C.H);
      SendConfigure(C);
    end
    else if C.Maximized then
    begin
      WorkAreaOf(Mn, AX, AY, AW, AH);
      SetFrameGeometry(C, AX, AY, AW, AH);
    end
    else if not InsideAnyMonitor(C.X + C.W div 2, C.Y + C.H div 2) then
    begin
      WorkAreaOf(Mn, AX, AY, AW, AH);
      NX := C.X; NY := C.Y;
      if NX + C.W > AX + AW then NX := AX + AW - C.W;
      if NY + C.H > AY + AH then NY := AY + AH - C.H;
      if NX < AX then NX := AX;
      if NY < AY then NY := AY;
      SetFrameGeometry(C, NX, NY, C.W, C.H);
      Log(Format('0x%x was off every monitor: moved to %d,%d', [C.Win, NX, NY]));
    end;
  end;
  Restack;
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
  if (FRandrBase >= 0) and ((Ev._type = FRandrBase + RRScreenChangeNotify) or (Ev._type = FRandrBase + RRNotify)) then
  begin
    OnScreenChange(Ev);
    Exit;
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
    EnterNotify: OnEnter(Ev.xcrossing);
    LeaveNotify: OnLeave(Ev.xcrossing);
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
  CheckKeepMapped;    { a compositor may have been running before us }
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
      FCfg.Rules := NewCfg.Rules;
      GrabKeys;
      Log(Format('reloaded key bindings from %s (%d bindings, %d warnings)',
        [FCfg.Path, Length(FCfg.Keys), Length(NewCfg.Warnings)]));
    end;
    PollMonitors;
    PollFocusFollow;
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
  XDeleteProperty(FDpy, FRoot, aKeepsMapped);
  XDeleteProperty(FDpy, FRoot, aSupported);
  XDestroyWindow(FDpy, FCheckWin);
  XSetInputFocus(FDpy, FRoot, RevertToPointerRoot, CurrentTime);
  XSync(FDpy, 0);
end;

end.
