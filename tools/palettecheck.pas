program palettecheck;

{ Compares the palette derived by tiewm (shade 1.3 / 0.7 / mid) with the colours real xfwm4 produced
  for the same base colours (read back from a probe theme, 2026-11-20, GTK theme Adwaita-dark). }

{$mode objfpc}{$H+}

uses
  SysUtils, twtheme;

type
  TRow = record
    Name: string;
    Base: LongWord;       { the _color_N value this one derives from }
    Kind: Integer;        { 1 = hilight, 2 = shadow, 3 = mid }
    Want: LongWord;
  end;

const
  Rows: array[0..11] of TRow = (
    (Name: 'active_hilight_1';   Base: $15539E; Kind: 1; Want: $0069E8),
    (Name: 'active_shadow_1';    Base: $15539E; Kind: 2; Want: $1D3B60),
    (Name: 'active_mid_1';       Base: $15539E; Kind: 3; Want: $0E52A4),
    (Name: 'active_hilight_2';   Base: $353535; Kind: 1; Want: $444444),
    (Name: 'active_shadow_2';    Base: $353535; Kind: 2; Want: $252525),
    (Name: 'active_mid_2';       Base: $353535; Kind: 3; Want: $343434),
    (Name: 'inactive_hilight_1'; Base: $323232; Kind: 1; Want: $414141),
    (Name: 'inactive_shadow_1';  Base: $323232; Kind: 2; Want: $222222),
    (Name: 'inactive_mid_1';     Base: $323232; Kind: 3; Want: $313131),
    (Name: 'inactive_hilight_2'; Base: $353535; Kind: 1; Want: $444444),
    (Name: 'inactive_shadow_2';  Base: $353535; Kind: 2; Want: $252525),
    (Name: 'inactive_mid_2';     Base: $353535; Kind: 3; Want: $343434));
var
  I, Bad: Integer;
  Got, L, D: LongWord;
begin
  Bad := 0;
  for I := 0 to High(Rows) do
  begin
    L := ShadeColor($FF000000 or Rows[I].Base, 1.3);
    D := ShadeColor($FF000000 or Rows[I].Base, 0.7);
    case Rows[I].Kind of
      1: Got := L;
      2: Got := D;
    else
      Got := MidColor(L, D);
    end;
    Got := Got and $FFFFFF;
    if Got = Rows[I].Want then WriteLn(Format('ok    %-20s %.6x', [Rows[I].Name, Got]))
    else
    begin
      WriteLn(Format('DIFF  %-20s ours %.6x  xfwm4 %.6x', [Rows[I].Name, Got, Rows[I].Want]));
      Inc(Bad);
    end;
  end;
  WriteLn(Bad, ' of ', Length(Rows), ' differ');
  if Bad > 0 then Halt(1);
end.
