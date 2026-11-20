unit twmenu;

{ A small popup menu drawn with Xlib/Xft (no toolkit). It is an override-redirect
  window that grabs pointer and keyboard while open, like any WM menu:
    - the item under the pointer is highlighted, a release on it selects it
    - Up/Down move the highlight, Return selects, Escape closes
    - a click outside closes
  A menu opened by a click is not selected by that same click's release: a
  release without any pointer movement soon after opening is ignored.
  The WM feeds it events through HandleEvent. }

{$mode objfpc}{$H+}

interface

uses
  ctypes, SysUtils, x, xlib, xutil, keysym, twxft, twxdraw;

type
  TMenuResult = (mrNone, mrConsumed, mrSelected, mrClosed);

  TMenuColors = record
    Back, Border, Text, Disabled, HoverBack, HoverText: LongWord;   { $RRGGBB }
  end;

  TMenuItem = record
    Id: Integer;
    Text: string;
    Checked, Enabled, Separator: Boolean;
  end;

  { TPopupMenu }

  TPopupMenu = class
  private
    FDpy: PDisplay;
    FScr: Integer;
    FRoot: TWindow;
    FVis: PVisual;
    FFont: TTitleFont;
    FColors: TMenuColors;
    FItems: array of TMenuItem;
    FTops: array of Integer;     { y of each row }
    FWin: TWindow;
    FPm: TPixmap;
    FGC: TGC;
    FW, FH, FRowH, FHover: Integer;
    FOpen, FMoved: Boolean;
    FPopX, FPopY: Integer;
    FPopTime: culong;
    procedure Draw;
    function ItemAt(Y: Integer): Integer;
    function NextEnabled(From, Dir: Integer): Integer;
    function GetCount: Integer;
  public
    constructor Create(ADpy: PDisplay; AScr: Integer; AFont: TTitleFont; const AColors: TMenuColors);
    destructor Destroy; override;
    procedure Clear;
    procedure Add(Id: Integer; const Text: string; Checked, Enabled: Boolean);
    procedure AddSeparator;
    { shows the menu with its top-left near X,Y (kept on screen); False if it could not grab }
    function Popup(X, Y: Integer; ATime: culong): Boolean;
    procedure Close;
    function HandleEvent(var Ev: TXEvent; out Id: Integer): TMenuResult;
    property IsOpen: Boolean read FOpen;
    property Win: TWindow read FWin;
    property Count: Integer read GetCount;
  end;

implementation

const
  PadLeft = 22;      { room for the check marker }
  PadRight = 14;
  SepH = 7;
  ClickIgnoreMs = 500;

constructor TPopupMenu.Create(ADpy: PDisplay; AScr: Integer; AFont: TTitleFont; const AColors: TMenuColors);
begin
  inherited Create;
  FDpy := ADpy;
  FScr := AScr;
  FRoot := DefaultRootWindow(ADpy);
  FVis := DefaultVisual(ADpy, AScr);
  FFont := AFont;
  FColors := AColors;
  FHover := -1;
end;

destructor TPopupMenu.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TPopupMenu.GetCount: Integer;
begin
  Result := Length(FItems);
end;

procedure TPopupMenu.Clear;
begin
  SetLength(FItems, 0);
end;

procedure TPopupMenu.Add(Id: Integer; const Text: string; Checked, Enabled: Boolean);
var
  N: Integer;
begin
  N := Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N].Id := Id;
  FItems[N].Text := Text;
  FItems[N].Checked := Checked;
  FItems[N].Enabled := Enabled;
  FItems[N].Separator := False;
end;

procedure TPopupMenu.AddSeparator;
var
  N: Integer;
begin
  N := Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N].Id := 0;
  FItems[N].Text := '';
  FItems[N].Checked := False;
  FItems[N].Enabled := False;
  FItems[N].Separator := True;
end;

function TPopupMenu.ItemAt(Y: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FItems) do
    if (Y >= FTops[I]) and (Y < FTops[I] + (FRowH - Ord(FItems[I].Separator) * (FRowH - SepH))) then
      Exit(I);
end;

function TPopupMenu.NextEnabled(From, Dir: Integer): Integer;
var
  I, N, Start: Integer;
begin
  N := Length(FItems);
  Result := From;
  if N = 0 then Exit;
  if From < 0 then
    if Dir > 0 then Start := -1 else Start := N
  else
    Start := From;
  I := Start;
  repeat
    I := I + Dir;
    if I < 0 then I := N - 1;
    if I >= N then I := 0;
    if FItems[I].Enabled and not FItems[I].Separator then Exit(I);
  until I = Start;
end;

procedure TPopupMenu.Draw;
var
  I, Y, TW, Base: Integer;
  Col: LongWord;
  Hov: Boolean;
begin
  XSetForeground(FDpy, FGC, FColors.Back);
  XFillRectangle(FDpy, FPm, FGC, 0, 0, FW, FH);
  for I := 0 to High(FItems) do
  begin
    Y := FTops[I];
    if FItems[I].Separator then
    begin
      XSetForeground(FDpy, FGC, FColors.Border);
      XDrawLine(FDpy, FPm, FGC, 6, Y + SepH div 2, FW - 7, Y + SepH div 2);
      Continue;
    end;
    Hov := (I = FHover) and FItems[I].Enabled;
    if Hov then
    begin
      XSetForeground(FDpy, FGC, FColors.HoverBack);
      XFillRectangle(FDpy, FPm, FGC, 0, Y, FW, FRowH);
    end;
    if not FItems[I].Enabled then Col := FColors.Disabled
    else if Hov then Col := FColors.HoverText
    else Col := FColors.Text;
    Base := Y + (FRowH - (FFont.Ascent + FFont.Descent)) div 2 + FFont.Ascent;
    FFont.Draw(FPm, FVis, DefaultColormap(FDpy, FScr), PadLeft, Base, FItems[I].Text, Col, smNone, 0);
    if FItems[I].Checked then
    begin
      XSetForeground(FDpy, FGC, Col);
      XFillRectangle(FDpy, FPm, FGC, 8, Y + (FRowH - 6) div 2, 6, 6);
    end;
  end;
  XSetWindowBackgroundPixmap(FDpy, FWin, FPm);
  XClearWindow(FDpy, FWin);
  XFlush(FDpy);
end;

function TPopupMenu.Popup(X, Y: Integer; ATime: culong): Boolean;
var
  I, TW, MaxW, SW, SH, Yy: Integer;
  Attr: TXSetWindowAttributes;
  Rw, Cw: TWindow;
  Rx, Ry, Wx, Wy: cint;
  Mask: cuint;
  Name: string;
begin
  Result := False;
  if FOpen then Close;
  if Length(FItems) = 0 then Exit;
  FRowH := FFont.Ascent + FFont.Descent + 8;
  MaxW := 60;
  SetLength(FTops, Length(FItems));
  Yy := 0;
  for I := 0 to High(FItems) do
  begin
    FTops[I] := Yy;
    if FItems[I].Separator then Inc(Yy, SepH)
    else
    begin
      Inc(Yy, FRowH);
      TW := FFont.Width(FItems[I].Text);
      if TW > MaxW then MaxW := TW;
    end;
  end;
  FW := MaxW + PadLeft + PadRight;
  FH := Yy;
  SW := DisplayWidth(FDpy, FScr);
  SH := DisplayHeight(FDpy, FScr);
  if X + FW + 2 > SW then X := SW - FW - 2;
  if Y + FH + 2 > SH then Y := SH - FH - 2;
  if X < 0 then X := 0;
  if Y < 0 then Y := 0;
  FWin := XCreateSimpleWindow(FDpy, FRoot, X, Y, FW, FH, 1, FColors.Border, FColors.Back);
  Attr.override_redirect := 1;
  XChangeWindowAttributes(FDpy, FWin, CWOverrideRedirect, @Attr);
  Name := 'tiewm-menu';
  XStoreName(FDpy, FWin, PChar(Name));
  XSelectInput(FDpy, FWin, ExposureMask or ButtonPressMask or ButtonReleaseMask or
    PointerMotionMask or KeyPressMask);
  FPm := XCreatePixmap(FDpy, FRoot, FW, FH, DefaultDepth(FDpy, FScr));
  FGC := XCreateGC(FDpy, FPm, 0, nil);
  FHover := -1;
  FMoved := False;
  FPopTime := ATime;
  XMapRaised(FDpy, FWin);
  Draw;
  { we hold both devices while the menu is up }
  if XGrabPointer(FDpy, FWin, 0, ButtonPressMask or ButtonReleaseMask or PointerMotionMask,
       GrabModeAsync, GrabModeAsync, None, None, ATime) <> GrabSuccess then
    if XGrabPointer(FDpy, FWin, 0, ButtonPressMask or ButtonReleaseMask or PointerMotionMask,
         GrabModeAsync, GrabModeAsync, None, None, CurrentTime) <> GrabSuccess then
    begin
      FOpen := True;     { so Close cleans everything up }
      Close;
      Exit;
    end;
  XGrabKeyboard(FDpy, FWin, 0, GrabModeAsync, GrabModeAsync, ATime);
  if XQueryPointer(FDpy, FRoot, @Rw, @Cw, @Rx, @Ry, @Wx, @Wy, @Mask) then
  begin
    FPopX := Rx;
    FPopY := Ry;
  end;
  FOpen := True;
  Result := True;
end;

procedure TPopupMenu.Close;
begin
  if not FOpen then Exit;
  FOpen := False;
  XUngrabPointer(FDpy, CurrentTime);
  XUngrabKeyboard(FDpy, CurrentTime);
  XDestroyWindow(FDpy, FWin);
  XFreePixmap(FDpy, FPm);
  XFreeGC(FDpy, FGC);
  FWin := 0;
  XFlush(FDpy);
end;

function TPopupMenu.HandleEvent(var Ev: TXEvent; out Id: Integer): TMenuResult;
var
  I, MX, MY: Integer;
  Inside: Boolean;
  Ks: TKeySym;
begin
  Id := 0;
  Result := mrNone;
  if not FOpen then Exit;
  case Ev._type of
    MotionNotify:
      begin
        MX := Ev.xmotion.x;
        MY := Ev.xmotion.y;
        if (Abs(Ev.xmotion.x_root - FPopX) > 3) or (Abs(Ev.xmotion.y_root - FPopY) > 3) then FMoved := True;
        if (MX >= 0) and (MX < FW) and (MY >= 0) and (MY < FH) then I := ItemAt(MY) else I := -1;
        if (I >= 0) and not FItems[I].Enabled then I := -1;
        if I <> FHover then
        begin
          FHover := I;
          Draw;
        end;
        Result := mrConsumed;
      end;
    ButtonPress:
      begin
        MX := Ev.xbutton.x;
        MY := Ev.xbutton.y;
        Inside := (MX >= 0) and (MX < FW) and (MY >= 0) and (MY < FH);
        if Inside then
        begin
          I := ItemAt(MY);
          if (I >= 0) and not FItems[I].Enabled then I := -1;
          if I <> FHover then
          begin
            FHover := I;
            Draw;
          end;
          Result := mrConsumed;
        end
        else
        begin
          Close;
          Result := mrClosed;
        end;
      end;
    ButtonRelease:
      begin
        MX := Ev.xbutton.x;
        MY := Ev.xbutton.y;
        if (Abs(Ev.xbutton.x_root - FPopX) > 3) or (Abs(Ev.xbutton.y_root - FPopY) > 3) then FMoved := True;
        { the release of the click that opened the menu must not select anything }
        if (not FMoved) and (Ev.xbutton.time - FPopTime < ClickIgnoreMs) then
          Exit(mrConsumed);
        Inside := (MX >= 0) and (MX < FW) and (MY >= 0) and (MY < FH);
        if Inside then
        begin
          I := ItemAt(MY);
          if (I >= 0) and FItems[I].Enabled and not FItems[I].Separator then
          begin
            Id := FItems[I].Id;
            Close;
            Result := mrSelected;
          end
          else
            Result := mrConsumed;
        end
        else
        begin
          Close;
          Result := mrClosed;
        end;
      end;
    KeyPress:
      begin
        Ks := XLookupKeysym(@Ev.xkey, 0);
        if Ks = XK_Escape then
        begin
          Close;
          Result := mrClosed;
        end
        else if Ks = XK_Up then
        begin
          FHover := NextEnabled(FHover, -1);
          Draw;
          Result := mrConsumed;
        end
        else if Ks = XK_Down then
        begin
          FHover := NextEnabled(FHover, 1);
          Draw;
          Result := mrConsumed;
        end
        else if (Ks = XK_Return) or (Ks = XK_KP_Enter) or (Ks = XK_space) then
        begin
          if (FHover >= 0) and FItems[FHover].Enabled then
          begin
            Id := FItems[FHover].Id;
            Close;
            Result := mrSelected;
          end
          else
            Result := mrConsumed;
        end
        else
          Result := mrConsumed;
      end;
    KeyRelease:
      Result := mrConsumed;
  end;
end;

end.
