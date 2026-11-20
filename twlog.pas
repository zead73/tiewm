unit twlog;

{ Tiny file logger. Under LXQt a window manager's stderr goes nowhere, so tiewm
  keeps its own log (default ~/.local/state/tiewm/tiewm.log). Every line is
  flushed at once so the log is useful after a crash; at start a file larger
  than 512 KiB is moved to <file>.1 (one generation kept). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TLogLevel = (llOff, llInfo, llDebug);

{ Opens (appends to) Path. Mirror also writes every line to stderr. An empty
  path or llOff means no file. }
procedure LogOpen(const Path: string; Level: TLogLevel; Mirror: Boolean);
procedure LogInfo(const Msg: string);
procedure LogDebug(const Msg: string);
procedure LogClose;
function LogFilePath: string;
function DefaultLogPath: string;
function ParseLogLevel(const S: string; out Level: TLogLevel): Boolean;

implementation

var
  GFile: TextFile;
  GOpen: Boolean = False;
  GPath: string = '';
  GLevel: TLogLevel = llOff;
  GMirror: Boolean = False;

function DefaultLogPath: string;
var
  Base: string;
begin
  Base := GetEnvironmentVariable('XDG_STATE_HOME');
  if Base = '' then Base := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.local/state';
  Result := IncludeTrailingPathDelimiter(Base) + 'tiewm/tiewm.log';
end;

function ParseLogLevel(const S: string; out Level: TLogLevel): Boolean;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  Result := True;
  if (L = 'off') or (L = 'none') or (L = 'false') then Level := llOff
  else if (L = 'info') or (L = 'normal') then Level := llInfo
  else if (L = 'debug') or (L = 'verbose') then Level := llDebug
  else Result := False;
end;

function FileSize64(const Path: string): Int64;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(Path, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end;
end;

procedure LogClose;
begin
  if GOpen then
  begin
    try
      CloseFile(GFile);
    except
    end;
    GOpen := False;
  end;
end;

procedure LogOpen(const Path: string; Level: TLogLevel; Mirror: Boolean);
begin
  LogClose;
  GLevel := Level;
  GMirror := Mirror;
  GPath := Path;
  if (Path = '') or (Level = llOff) then Exit;
  try
    ForceDirectories(ExtractFileDir(Path));
    if FileSize64(Path) > 512 * 1024 then
    begin
      DeleteFile(Path + '.1');
      RenameFile(Path, Path + '.1');
    end;
    AssignFile(GFile, Path);
    if FileExists(Path) then Append(GFile) else Rewrite(GFile);
    GOpen := True;
  except
    GOpen := False;     { an unwritable log must never stop the window manager }
  end;
end;

procedure Emit(const Msg: string);
var
  Line: string;
begin
  Line := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ' + Msg;
  if GOpen then
  begin
    try
      WriteLn(GFile, Line);
      Flush(GFile);
    except
      GOpen := False;
    end;
  end;
  if GMirror then
  begin
    WriteLn(StdErr, 'tiewm: ', Msg);
    Flush(StdErr);
  end;
end;

procedure LogInfo(const Msg: string);
begin
  if GLevel >= llInfo then Emit(Msg);
end;

procedure LogDebug(const Msg: string);
begin
  if GLevel >= llDebug then Emit(Msg);
end;

function LogFilePath: string;
begin
  Result := GPath;
end;

end.
