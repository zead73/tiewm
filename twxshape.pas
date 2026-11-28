unit twxshape;

{ Minimal binding to the X Shape extension (libXext). FPC ships no XShape
  unit, and a window manager needs it to cut frame corners. Only what the
  frame code uses is declared. }

{$mode objfpc}{$H+}

interface

uses
  ctypes, x, xlib;

const
  ShapeSet = 0;
  ShapeUnion = 1;
  ShapeBounding = 0;
  ShapeClip = 1;
  ShapeInput = 2;

function XShapeQueryExtension(dpy: PDisplay; EventBase, ErrorBase: pcint): cint; cdecl;
  external 'Xext' name 'XShapeQueryExtension';
procedure XShapeCombineRectangles(dpy: PDisplay; Dest: TWindow; DestKind, XOff, YOff: cint;
  Rects: PXRectangle; Count, Op, Ordering: cint); cdecl; external 'Xext' name 'XShapeCombineRectangles';
procedure XShapeCombineMask(dpy: PDisplay; Dest: TWindow; DestKind, XOff, YOff: cint;
  Src: TPixmap; Op: cint); cdecl; external 'Xext' name 'XShapeCombineMask';

{ True if the server has the extension }
function HaveShape(dpy: PDisplay): Boolean;

implementation

function HaveShape(dpy: PDisplay): Boolean;
var
  Ev, Er: cint;
begin
  Result := XShapeQueryExtension(dpy, @Ev, @Er) <> 0;
end;

end.
