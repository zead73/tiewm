unit twconfig;

{ tiewm configuration: ~/.config/tiewm/tiewm.conf (or $TIEWM_CONFIG).

  A bad value never stops the window manager from starting: it is reported
  as a warning and the built-in default is kept.

  Format: "key = value" lines, "#" or ";" at the start of a line = comment,
  sections [general], [colors], [keys]. Everything before the first section
  header is [general].

  [keys]: "action = Combo[, Combo...]". Listing an action replaces ALL of its
  default bindings; "none" removes them. Actions you do not list keep their
  defaults. Combos look like Alt+Tab, Ctrl+Alt+Shift+Left, Super+Return, F11:
  modifiers Ctrl, Alt, Shift, Super (aliases Control, Mod1, Mod4, Meta) and an
  X keysym name (Tab, Return, Left, F4, a, ...).

  Environment overrides (handy for testing): TIEWM_THEME, TIEWM_FONT,
  TIEWM_DESKTOPS. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, StrUtils, Classes, ctypes, BaseUnix, x, xlib, twtheme, twlog;

type
  TKeyAction = (kaClose, kaCycle, kaCycleBack, kaMaximize, kaIconify, kaFullscreen,
    kaDeskLeft, kaDeskRight, kaMoveLeft, kaMoveRight, kaWindowMenu, kaShade, kaMoveWindow, kaResizeWindow, kaGotoDesk, kaMoveToDesk);

  TKeyBinding = record
    Sym: TKeySym;
    Mods: cuint;        { without Caps/Num Lock }
    Kc: cuint;          { filled in when the keys are grabbed }
    Action: TKeyAction;
    Arg: Integer;       { desktop number (1-based) for goto/move_to }
  end;
  TKeyBindings = array of TKeyBinding;

  TRuleMode = (rmRemove, rmTitlebar, rmNoTitlebar);

  { per-application window rule, matched by WM_CLASS (instance or class, case-insensitive) }
  TWinRule = record
    Cls: string;
    Titlebar: Boolean;     { True: always give it a titlebar, False: never }
  end;

  TConfig = record
    Theme, TitleFont, MenuFont, ButtonLayout, TitleAlign: string;
    NumDesktops: Integer;
    ShowAppIcon: Integer;          { -1 = what the theme says, 0 = never, 1 = always }
    UndecoratedBorder: Integer;    { px of resize border around windows without a titlebar, 0 = none }
    FontGreyscale: Boolean;
    FontHinting: Integer;          { 0..3, -1 = leave to fontconfig }
    Palette: TThemePalette;
    Keys: TKeyBindings;
    Rules: array of TWinRule;
    LogFile: string;               { '' = no log file }
    LogLevel: TLogLevel;
    Path: string;
    Loaded: Boolean;
    Warnings: array of string;
  end;

function DefaultConfigPath: string;
function DefaultConfig: TConfig;
{ defaults, then the file (if it exists), then environment overrides }
function LoadConfig(const Path: string): TConfig;
{ the rule for a window with these WM_CLASS strings, if there is one }
function FindWindowRule(const C: TConfig; const Inst, Cls: string; out Titlebar: Boolean): Boolean;
{ keeps the in-memory rules in step with what was written to the file }
procedure SetRuleInMemory(var C: TConfig; const Cls: string; Mode: TRuleMode);
{ Edits the [windows] section of the config file in place: one line is added, changed
  or removed, everything else (comments, other sections, order) is left alone. The file
  and its folder are created if they do not exist. False and Err on failure. }
function WriteWindowRule(const Path, Cls: string; Mode: TRuleMode; out Err: string): Boolean;
function ParseCombo(const S: string; out Sym: TKeySym; out Mods: cuint): Boolean;
function FormatCombo(Sym: TKeySym; Mods: cuint): string;
function ActionName(Action: TKeyAction; Arg: Integer): string;
{ human-readable dump, used by --check-config }
function DescribeConfig(const C: TConfig): string;

implementation

const
  ActionNames: array[TKeyAction] of string = ('close', 'cycle', 'cycle_back', 'maximize',
    'iconify', 'fullscreen', 'desktop_left', 'desktop_right', 'move_left', 'move_right',
    'window_menu', 'shade', 'move_window', 'resize_window', 'goto_desktop_', 'move_to_desktop_');

procedure Warn(var C: TConfig; const Msg: string);
begin
  SetLength(C.Warnings, Length(C.Warnings) + 1);
  C.Warnings[High(C.Warnings)] := Msg;
end;

function DefaultConfigPath: string;
var
  Env, Base: string;
begin
  Env := GetEnvironmentVariable('TIEWM_CONFIG');
  if Env <> '' then Exit(Env);
  Base := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Base = '' then Base := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.config';
  Result := IncludeTrailingPathDelimiter(Base) + 'tiewm/tiewm.conf';
end;

function ActionName(Action: TKeyAction; Arg: Integer): string;
begin
  Result := ActionNames[Action];
  if Action in [kaGotoDesk, kaMoveToDesk] then Result := Result + IntToStr(Arg);
end;

procedure AddBinding(var C: TConfig; Action: TKeyAction; Arg: Integer; const Combo: string);
var
  B: TKeyBinding;
  N: Integer;
begin
  if not ParseCombo(Combo, B.Sym, B.Mods) then Exit;
  B.Kc := 0;
  B.Action := Action;
  B.Arg := Arg;
  N := Length(C.Keys);
  SetLength(C.Keys, N + 1);
  C.Keys[N] := B;
end;

function DefaultConfig: TConfig;
begin
  Result.Theme := 'Daloa';
  Result.TitleFont := 'Sans Bold 11';
  Result.MenuFont := 'Sans 10';
  Result.ButtonLayout := 'O|SHMC';
  Result.TitleAlign := 'left';
  Result.NumDesktops := 4;
  Result.UndecoratedBorder := 0;
  Result.ShowAppIcon := -1;
  Result.FontGreyscale := True;
  Result.FontHinting := 3;
  Result.Palette := DefaultPalette;
  Result.LogFile := DefaultLogPath;
  Result.LogLevel := llInfo;
  Result.Path := '';
  Result.Loaded := False;
  SetLength(Result.Keys, 0);
  SetLength(Result.Rules, 0);
  SetLength(Result.Warnings, 0);
  AddBinding(Result, kaClose, 0, 'Alt+F4');
  AddBinding(Result, kaCycle, 0, 'Alt+Tab');
  AddBinding(Result, kaCycleBack, 0, 'Alt+Shift+Tab');
  AddBinding(Result, kaMaximize, 0, 'Super+Return');
  AddBinding(Result, kaIconify, 0, 'Alt+F9');
  AddBinding(Result, kaFullscreen, 0, 'Alt+F11');
  AddBinding(Result, kaDeskLeft, 0, 'Ctrl+Alt+Left');
  AddBinding(Result, kaDeskRight, 0, 'Ctrl+Alt+Right');
  AddBinding(Result, kaMoveLeft, 0, 'Ctrl+Alt+Shift+Left');
  AddBinding(Result, kaMoveRight, 0, 'Ctrl+Alt+Shift+Right');
  AddBinding(Result, kaWindowMenu, 0, 'Alt+space');
  AddBinding(Result, kaMoveWindow, 0, 'Alt+F7');
  AddBinding(Result, kaResizeWindow, 0, 'Alt+F8');
end;


function FindWindowRule(const C: TConfig; const Inst, Cls: string; out Titlebar: Boolean): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(C.Rules) do
    if ((Cls <> '') and SameText(C.Rules[I].Cls, Cls)) or ((Inst <> '') and SameText(C.Rules[I].Cls, Inst)) then
    begin
      Titlebar := C.Rules[I].Titlebar;
      Exit(True);
    end;
end;

procedure SetRuleInMemory(var C: TConfig; const Cls: string; Mode: TRuleMode);
var
  I, N: Integer;
begin
  for I := 0 to High(C.Rules) do
    if SameText(C.Rules[I].Cls, Cls) then
    begin
      if Mode = rmRemove then
      begin
        for N := I to High(C.Rules) - 1 do C.Rules[N] := C.Rules[N + 1];
        SetLength(C.Rules, Length(C.Rules) - 1);
      end
      else
        C.Rules[I].Titlebar := Mode = rmTitlebar;
      Exit;
    end;
  if Mode = rmRemove then Exit;
  N := Length(C.Rules);
  SetLength(C.Rules, N + 1);
  C.Rules[N].Cls := Cls;
  C.Rules[N].Titlebar := Mode = rmTitlebar;
end;

function WriteWindowRule(const Path, Cls: string; Mode: TRuleMode; out Err: string): Boolean;
var
  L: TStringList;
  I, SecStart, SecEnd, Found, P, Ins: Integer;
  T, Key, NewLine, Tmp, Value: string;
  St: Stat;
  HaveStat: Boolean;
begin
  Result := False;
  Err := '';
  if (Trim(Cls) = '') or (Pos('=', Cls) > 0) or (Pos(#10, Cls) > 0) or (Pos(#13, Cls) > 0) or
     (Cls[1] = '#') or (Cls[1] = ';') or (Cls[1] = '[') then
  begin
    Err := 'class name "' + Cls + '" cannot be written to the config file';
    Exit;
  end;
  L := TStringList.Create;
  try
    HaveStat := False;
    if FileExists(Path) then
    begin
      try
        L.LoadFromFile(Path);
      except
        on E: Exception do
        begin
          Err := 'cannot read ' + Path + ': ' + E.Message;
          Exit;
        end;
      end;
      HaveStat := FpStat(Path, St) = 0;
    end
    else
    begin
      if Mode = rmRemove then Exit(True);      { nothing to remove }
      L.Add('# tiewm configuration (tiewm.conf.example documents every setting)');
      L.Add('');
    end;
    SecStart := -1;
    SecEnd := L.Count;
    for I := 0 to L.Count - 1 do
    begin
      T := Trim(L[I]);
      if (T <> '') and (T[1] = '[') and (T[Length(T)] = ']') then
      begin
        if SecStart < 0 then
        begin
          if LowerCase(Trim(Copy(T, 2, Length(T) - 2))) = 'windows' then SecStart := I;
        end
        else
        begin
          SecEnd := I;
          Break;
        end;
      end;
    end;
    Found := -1;
    if SecStart >= 0 then
      for I := SecStart + 1 to SecEnd - 1 do
      begin
        T := Trim(L[I]);
        if (T = '') or (T[1] = '#') or (T[1] = ';') then Continue;
        P := Pos('=', T);
        if P < 2 then Continue;
        Key := Trim(Copy(T, 1, P - 1));
        if SameText(Key, Cls) then Found := I;
      end;
    if Mode = rmRemove then
    begin
      if Found < 0 then Exit(True);
      L.Delete(Found);
    end
    else
    begin
      if Mode = rmNoTitlebar then Value := 'no_titlebar' else Value := 'titlebar';
      NewLine := Cls + ' = ' + Value;
      if Found >= 0 then L[Found] := NewLine
      else if SecStart >= 0 then
      begin
        Ins := SecEnd;
        while (Ins - 1 > SecStart) and (Trim(L[Ins - 1]) = '') do Dec(Ins);
        L.Insert(Ins, NewLine);
      end
      else
      begin
        if (L.Count > 0) and (Trim(L[L.Count - 1]) <> '') then L.Add('');
        L.Add('[windows]');
        L.Add(NewLine);
      end;
    end;
    try
      ForceDirectories(ExtractFileDir(Path));
      Tmp := Path + '.tmp';
      L.SaveToFile(Tmp);
      if HaveStat then FpChmod(Tmp, St.st_mode and &7777);
      if not RenameFile(Tmp, Path) then
      begin
        DeleteFile(Tmp);
        Err := 'cannot replace ' + Path;
        Exit;
      end;
    except
      on E: Exception do
      begin
        Err := 'cannot write ' + Path + ': ' + E.Message;
        Exit;
      end;
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

{ ---- key combos ---- }

function LookupKeysym(const Name: string): TKeySym;
var
  Cap, Up: string;
begin
  Result := XStringToKeysym(PChar(Name));
  if Result <> 0 then Exit;
  Cap := UpperCase(Copy(Name, 1, 1)) + LowerCase(Copy(Name, 2, MaxInt));   { tab -> Tab }
  Result := XStringToKeysym(PChar(Cap));
  if Result <> 0 then Exit;
  Up := UpperCase(Name);                                                   { f4 -> F4 }
  Result := XStringToKeysym(PChar(Up));
  if Result <> 0 then Exit;
  if Length(Name) = 1 then Result := XStringToKeysym(PChar(LowerCase(Name)));
end;

function ParseCombo(const S: string; out Sym: TKeySym; out Mods: cuint): Boolean;
var
  Parts: TStringList;
  I: Integer;
  T, L: string;
begin
  Result := False;
  Sym := 0;
  Mods := 0;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '+';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Trim(S);
    if Parts.Count = 0 then Exit;
    for I := 0 to Parts.Count - 2 do
    begin
      L := LowerCase(Trim(Parts[I]));
      if (L = 'ctrl') or (L = 'control') then Mods := Mods or ControlMask
      else if (L = 'alt') or (L = 'mod1') then Mods := Mods or Mod1Mask
      else if L = 'shift' then Mods := Mods or ShiftMask
      else if (L = 'super') or (L = 'mod4') or (L = 'meta') or (L = 'win') then Mods := Mods or Mod4Mask
      else Exit;
    end;
    T := Trim(Parts[Parts.Count - 1]);
    if T = '' then Exit;
    Sym := LookupKeysym(T);
    Result := Sym <> 0;
  finally
    Parts.Free;
  end;
end;

function FormatCombo(Sym: TKeySym; Mods: cuint): string;
var
  Nm: PChar;
begin
  Result := '';
  if (Mods and ControlMask) <> 0 then Result := Result + 'Ctrl+';
  if (Mods and Mod1Mask) <> 0 then Result := Result + 'Alt+';
  if (Mods and ShiftMask) <> 0 then Result := Result + 'Shift+';
  if (Mods and Mod4Mask) <> 0 then Result := Result + 'Super+';
  Nm := XKeysymToString(Sym);
  if Nm <> nil then Result := Result + Nm else Result := Result + '?';
end;

{ ---- parsing helpers ---- }

function ParseColor(const S: string; out C: LongWord): Boolean;
var
  H: string;
  V: Int64;
begin
  H := Trim(S);
  if (H <> '') and (H[1] = '#') then H := Copy(H, 2, MaxInt);
  Result := False;
  if Length(H) <> 6 then Exit;
  V := StrToInt64Def('$' + H, -1);
  if V < 0 then Exit;
  C := LongWord(V);
  Result := True;
end;

function ParseBool(const S: string; out B: Boolean): Boolean;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  Result := True;
  if (L = 'true') or (L = 'yes') or (L = '1') or (L = 'on') then B := True
  else if (L = 'false') or (L = 'no') or (L = '0') or (L = 'off') then B := False
  else Result := False;
end;

function KnownAction(const Name: string; out Action: TKeyAction; out Arg: Integer): Boolean;
var
  A: TKeyAction;
  Rest: string;
begin
  Result := False;
  Arg := 0;
  for A := Low(TKeyAction) to High(TKeyAction) do
  begin
    if A in [kaGotoDesk, kaMoveToDesk] then
    begin
      if Pos(ActionNames[A], Name) = 1 then
      begin
        Rest := Copy(Name, Length(ActionNames[A]) + 1, MaxInt);
        Arg := StrToIntDef(Rest, 0);
        if (Arg >= 1) and (Arg <= 20) then
        begin
          Action := A;
          Exit(True);
        end;
      end;
    end
    else if Name = ActionNames[A] then
    begin
      Action := A;
      Exit(True);
    end;
  end;
end;

procedure ClearAction(var C: TConfig; Action: TKeyAction; Arg: Integer);
var
  I, N: Integer;
begin
  N := 0;
  for I := 0 to High(C.Keys) do
    if not ((C.Keys[I].Action = Action) and (C.Keys[I].Arg = Arg)) then
    begin
      C.Keys[N] := C.Keys[I];
      Inc(N);
    end;
  SetLength(C.Keys, N);
end;

procedure SetKeys(var C: TConfig; Line: Integer; const Name, Value: string; var Cleared: TStringList);
var
  Action: TKeyAction;
  Arg, I, J, NValid: Integer;
  Combos: TStringList;
  Syms: array of TKeySym;
  ModsOf: array of cuint;
  Sym: TKeySym;
  Mods: cuint;
  V, Key: string;
begin
  Key := LowerCase(Name);
  if not KnownAction(Key, Action, Arg) then
  begin
    Warn(C, Format('line %d: unknown key action "%s"', [Line, Name]));
    Exit;
  end;
  V := Trim(Value);
  if (V = '') or (LowerCase(V) = 'none') then
  begin
    if Cleared.IndexOf(Key) < 0 then
    begin
      ClearAction(C, Action, Arg);
      Cleared.Add(Key);
    end;
    Exit;
  end;
  Combos := TStringList.Create;
  try
    Combos.Delimiter := ',';
    Combos.StrictDelimiter := True;
    Combos.DelimitedText := V;
    NValid := 0;
    SetLength(Syms, Combos.Count);
    SetLength(ModsOf, Combos.Count);
    for I := 0 to Combos.Count - 1 do
      if ParseCombo(Combos[I], Sym, Mods) then
      begin
        Syms[NValid] := Sym;
        ModsOf[NValid] := Mods;
        Inc(NValid);
      end
      else
        Warn(C, Format('line %d: cannot parse key combination "%s" for %s', [Line, Trim(Combos[I]), Name]));
    { nothing usable on this line: keep the defaults rather than leave the action unbound }
    if NValid = 0 then Exit;
    if Cleared.IndexOf(Key) < 0 then
    begin
      ClearAction(C, Action, Arg);
      Cleared.Add(Key);
    end;
    for I := 0 to NValid - 1 do
    begin
      { the same combination on two actions: the first one wins }
      Sym := Syms[I];
      for J := 0 to High(C.Keys) do
        if (C.Keys[J].Sym = Syms[I]) and (C.Keys[J].Mods = ModsOf[I]) then
        begin
          Warn(C, Format('line %d: %s is already bound to %s, ignoring it for %s',
            [Line, FormatCombo(Syms[I], ModsOf[I]), ActionName(C.Keys[J].Action, C.Keys[J].Arg), Name]));
          Sym := 0;
          Break;
        end;
      if Sym <> 0 then
      begin
        J := Length(C.Keys);
        SetLength(C.Keys, J + 1);
        C.Keys[J].Sym := Syms[I];
        C.Keys[J].Mods := ModsOf[I];
        C.Keys[J].Kc := 0;
        C.Keys[J].Action := Action;
        C.Keys[J].Arg := Arg;
      end;
    end;
  finally
    Combos.Free;
  end;
end;

procedure SetGeneral(var C: TConfig; Line: Integer; const Key, Value: string);
var
  K, V: string;
  N: Integer;
  B: Boolean;
begin
  K := LowerCase(Key);
  V := Trim(Value);
  if K = 'theme' then C.Theme := V
  else if K = 'title_font' then C.TitleFont := V
  else if K = 'menu_font' then C.MenuFont := V
  else if K = 'button_layout' then C.ButtonLayout := V
  else if K = 'title_align' then
  begin
    if (LowerCase(V) = 'left') or (LowerCase(V) = 'center') or (LowerCase(V) = 'right') then
      C.TitleAlign := LowerCase(V)
    else
      Warn(C, Format('line %d: title_align must be left, center or right, not "%s"', [Line, V]));
  end
  else if K = 'desktops' then
  begin
    N := StrToIntDef(V, 0);
    if (N >= 1) and (N <= 20) then C.NumDesktops := N
    else Warn(C, Format('line %d: desktops must be 1..20, not "%s"', [Line, V]));
  end
  else if K = 'show_app_icon' then
  begin
    if (LowerCase(V) = 'auto') or (LowerCase(V) = 'theme') then C.ShowAppIcon := -1
    else if ParseBool(V, B) then C.ShowAppIcon := Ord(B)
    else Warn(C, Format('line %d: show_app_icon must be auto, true or false, not "%s"', [Line, V]));
  end
  else if K = 'undecorated_border' then
  begin
    N := StrToIntDef(V, -1);
    if (N >= 0) and (N <= 16) then C.UndecoratedBorder := N
    else Warn(C, Format('line %d: undecorated_border must be 0..16 pixels, not "%s"', [Line, V]));
  end
  else if K = 'font_greyscale' then
  begin
    if ParseBool(V, B) then C.FontGreyscale := B
    else Warn(C, Format('line %d: font_greyscale must be true or false, not "%s"', [Line, V]));
  end
  else if K = 'log_file' then
  begin
    if (Length(V) >= 2) and (V[1] = '~') and (V[2] = '/') then
      V := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + Copy(V, 3, MaxInt);
    C.LogFile := V;
  end
  else if K = 'log_level' then
  begin
    if not ParseLogLevel(V, C.LogLevel) then
      Warn(C, Format('line %d: log_level must be off, info or debug, not "%s"', [Line, V]));
  end
  else if K = 'font_hinting' then
  begin
    N := StrToIntDef(V, -9);
    if (N >= -1) and (N <= 3) then C.FontHinting := N
    else Warn(C, Format('line %d: font_hinting must be -1..3, not "%s"', [Line, V]));
  end
  else
    Warn(C, Format('line %d: unknown setting "%s"', [Line, Key]));
end;

procedure SetColor(var C: TConfig; Line: Integer; const Key, Value: string);
var
  K: string;
  Col: LongWord;
begin
  K := LowerCase(Key);
  if not ParseColor(Value, Col) then
  begin
    Warn(C, Format('line %d: "%s" is not a colour like #14529E (%s)', [Line, Trim(Value), Key]));
    Exit;
  end;
  if K = 'active_color_1' then C.Palette.Color1[wsActive] := $FF000000 or Col
  else if K = 'inactive_color_1' then C.Palette.Color1[wsInactive] := $FF000000 or Col
  else if K = 'active_color_2' then C.Palette.Color2[wsActive] := $FF000000 or Col
  else if K = 'inactive_color_2' then C.Palette.Color2[wsInactive] := $FF000000 or Col
  else if K = 'active_text_color' then
  begin
    C.Palette.TextColor[wsActive] := $FF000000 or Col;
    C.Palette.Text2Color[wsActive] := $FF000000 or Col;
  end
  else if K = 'active_text_color_2' then C.Palette.Text2Color[wsActive] := $FF000000 or Col
  else if K = 'inactive_text_color' then
  begin
    C.Palette.TextColor[wsInactive] := $FF000000 or Col;
    C.Palette.Text2Color[wsInactive] := $FF000000 or Col;
  end
  else if K = 'active_border_color' then C.Palette.BorderColor[wsActive] := $FF000000 or Col
  else if K = 'inactive_border_color' then C.Palette.BorderColor[wsInactive] := $FF000000 or Col
  else Warn(C, Format('line %d: unknown colour "%s"', [Line, Key]));
end;

procedure SetWindowRule(var C: TConfig; Line: Integer; const Key, Value: string);
var
  V: string;
  Mode: TRuleMode;
begin
  V := LowerCase(Trim(Value));
  if (V = 'no_titlebar') or (V = 'notitlebar') or (V = 'undecorated') then Mode := rmNoTitlebar
  else if (V = 'titlebar') or (V = 'decorated') then Mode := rmTitlebar
  else
  begin
    Warn(C, Format('line %d: window rule for "%s" must be titlebar or no_titlebar, not "%s"', [Line, Key, Trim(Value)]));
    Exit;
  end;
  if Trim(Key) = '' then
  begin
    Warn(C, Format('line %d: window rule without a class name', [Line]));
    Exit;
  end;
  SetRuleInMemory(C, Trim(Key), Mode);
end;

function LoadConfig(const Path: string): TConfig;
var
  SL, Cleared: TStringList;
  I, P, N: Integer;
  Line, Key, Value, Section, Env: string;
begin
  Result := DefaultConfig;
  Result.Path := Path;
  if (Path <> '') and FileExists(Path) then
  begin
    SL := TStringList.Create;
    Cleared := TStringList.Create;
    try
      try
        SL.LoadFromFile(Path);
        Result.Loaded := True;
      except
        on E: Exception do Warn(Result, 'cannot read ' + Path + ': ' + E.Message);
      end;
      Section := 'general';
      for I := 0 to SL.Count - 1 do
      begin
        Line := Trim(SL[I]);
        if (Line = '') or (Line[1] = '#') or (Line[1] = ';') then Continue;
        if (Line[1] = '[') and (Line[Length(Line)] = ']') then
        begin
          Section := LowerCase(Trim(Copy(Line, 2, Length(Line) - 2)));
          if (Section <> 'general') and (Section <> 'colors') and (Section <> 'keys') and (Section <> 'windows') then
            Warn(Result, Format('line %d: unknown section [%s]', [I + 1, Section]));
          Continue;
        end;
        P := Pos('=', Line);
        if P < 2 then
        begin
          Warn(Result, Format('line %d: expected "key = value", got "%s"', [I + 1, Line]));
          Continue;
        end;
        Key := Trim(Copy(Line, 1, P - 1));
        Value := Trim(Copy(Line, P + 1, MaxInt));
        if Section = 'general' then SetGeneral(Result, I + 1, Key, Value)
        else if Section = 'colors' then SetColor(Result, I + 1, Key, Value)
        else if Section = 'keys' then SetKeys(Result, I + 1, Key, Value, Cleared)
        else if Section = 'windows' then SetWindowRule(Result, I + 1, Key, Value);
      end;
    finally
      Cleared.Free;
      SL.Free;
    end;
  end;
  { environment wins over the file }
  Env := GetEnvironmentVariable('TIEWM_THEME');
  if Env <> '' then Result.Theme := Env;
  Env := GetEnvironmentVariable('TIEWM_FONT');
  if Env <> '' then Result.TitleFont := Env;
  Env := GetEnvironmentVariable('TIEWM_LOG');
  if Env <> '' then
  begin
    if LowerCase(Env) = 'none' then Result.LogLevel := llOff else Result.LogFile := Env;
  end;
  if GetEnvironmentVariable('TIEWM_DEBUG') <> '' then Result.LogLevel := llDebug;
  Env := GetEnvironmentVariable('TIEWM_DESKTOPS');
  if Env <> '' then
  begin
    N := StrToIntDef(Env, 0);
    if (N >= 1) and (N <= 20) then Result.NumDesktops := N;
  end;
end;

const
  LogLevelNames: array[TLogLevel] of string = ('off', 'info', 'debug');

function Hex6(C: LongWord): string;
begin
  Result := '#' + IntToHex(C and $FFFFFF, 6);
end;

function DescribeConfig(const C: TConfig): string;
var
  I: Integer;
  A: TKeyAction;
  Any: Boolean;
  Arg: Integer;
begin
  if C.Loaded then Result := 'config file: ' + C.Path + #10
  else Result := 'config file: ' + C.Path + ' (not found, using defaults)' + #10;
  Result := Result + 'theme = ' + C.Theme + #10 + 'title_font = ' + C.TitleFont + #10 + 'menu_font = ' + C.MenuFont + #10 +
    'button_layout = ' + C.ButtonLayout + #10 + 'title_align = ' + C.TitleAlign + #10 +
    'desktops = ' + IntToStr(C.NumDesktops) + #10 +
    'undecorated_border = ' + IntToStr(C.UndecoratedBorder) + #10 +
    'show_app_icon = ' + IfThen(C.ShowAppIcon < 0, 'auto', BoolToStr(C.ShowAppIcon = 1, 'true', 'false')) + #10 +
    'font_greyscale = ' + BoolToStr(C.FontGreyscale, 'true', 'false') + #10 +
    'font_hinting = ' + IntToStr(C.FontHinting) + #10 +
    'log_file = ' + C.LogFile + #10 +
    'log_level = ' + LogLevelNames[C.LogLevel] + #10 +
    'active_color_1 = ' + Hex6(C.Palette.Color1[wsActive]) + #10 +
    'inactive_color_1 = ' + Hex6(C.Palette.Color1[wsInactive]) + #10 +
    'active_color_2 = ' + Hex6(C.Palette.Color2[wsActive]) + #10 +
    'inactive_color_2 = ' + Hex6(C.Palette.Color2[wsInactive]) + #10 +
    'active_text_color = ' + Hex6(C.Palette.TextColor[wsActive]) + #10 +
    'active_text_color_2 = ' + Hex6(C.Palette.Text2Color[wsActive]) + #10 +
    'inactive_text_color = ' + Hex6(C.Palette.TextColor[wsInactive]) + #10 +
    'active_border_color = ' + Hex6(C.Palette.BorderColor[wsActive]) + #10 +
    'inactive_border_color = ' + Hex6(C.Palette.BorderColor[wsInactive]) + #10;
  for I := 0 to High(C.Keys) do
    Result := Result + 'key ' + ActionName(C.Keys[I].Action, C.Keys[I].Arg) + ' = ' +
      FormatCombo(C.Keys[I].Sym, C.Keys[I].Mods) + #10;
  for A := Low(TKeyAction) to High(TKeyAction) do
    if not (A in [kaGotoDesk, kaMoveToDesk]) then
    begin
      Any := False;
      for I := 0 to High(C.Keys) do
        if C.Keys[I].Action = A then Any := True;
      if not Any then Result := Result + 'key ' + ActionNames[A] + ' = (none)' + #10;
    end;
  for I := 0 to High(C.Rules) do
    Result := Result + 'window ' + C.Rules[I].Cls + ' = ' + BoolToStr(C.Rules[I].Titlebar, 'titlebar', 'no_titlebar') + #10;
  Arg := 0;
  for I := 0 to High(C.Warnings) do
  begin
    Inc(Arg);
    Result := Result + 'warning: ' + C.Warnings[I] + #10;
  end;
  if Arg = 0 then Result := Result + 'no problems found' + #10;
end;

end.
