import Reef.Camera
import WebGPUWindow

/-!
# The state, and what changes it

Everything that is not a GPU resource, in one structure: the camera, how it
is driven, the keys held, the mouse, the window's size. Two pure functions
change it: `update`, on an event, which may also ask the program for
something it cannot do itself (a `Command`); and `step`, once a frame, by
the time passed. The program (`Reef/Main.lean`) is the shell around them.

## Driving the camera

As a modelling program's viewport, with no modes: two fingers on a trackpad
(the wheel) orbit the target; with Shift, pan; with Ctrl (or a pinch, in a
browser), dolly; with Alt, turn in place. The main mouse button, dragged,
does the same four. W, A, S, D (or the arrows) move the camera, and its
target with it, Q and E down and up, Shift hurrying. Home puts the camera
back where it started; 1 shows the wireframe, or hides it, and 2 the grid;
`[` and `]` halve and double the detail, how finely every mesh is made;
F fills the screen, or leaves it; Escape ends the demo, natively.
-/

open WebGPU.Window

namespace Reef

/-- The keys held that move the camera. -/
structure Held where
  forward : Bool := false
  back    : Bool := false
  left    : Bool := false
  right   : Bool := false
  up      : Bool := false
  down    : Bool := false
  fast    : Bool := false
  deriving Repr, Inhabited

/-- The grid drawn for the floor, as `shaders/grid.wgsl` reads it. -/
structure Grid where
  /-- Between lines, in metres. -/
  spacing : Float := 1
  /-- A brighter line every this many. -/
  major   : Float := 10
  /-- How far from the origin the floor reaches, in metres. -/
  extent  : Float := 500
  /-- The distance over which it fades into the background, in metres. -/
  fade    : Float := 60
  deriving Repr, Inhabited

/--
How finely every mesh is made, as a factor: 1 as designed, 2 twice as
fine, and so on; the one knob for the hardware at hand. Each mesh scales
its own tessellation by it (`Floor.cellsAt`); the renderer makes the meshes
again when it changes (`Command.remesh`).
-/
def Detail := Float

/-- The floor's quadtree (`Reef/Floor.lean`), as `shaders/sand.wgsl` reads it. -/
structure Floor where
  /-- A leaf patch's width, in metres. -/
  leaf      : Float := 0.4
  /-- Cells a side of a patch at detail 1: even. -/
  cells     : Nat   := 32
  /-- Levels above the leaves: the root is `leaf * 2 ^ depth` wide, around
  the eye. -/
  depth     : Nat   := 12
  /-- How far from the eye the leaves are drawn, in metres: each level up,
  twice as far. -/
  range     : Float := 1.5
  /-- Where a node begins to morph onto its parent: this fraction of its
  level's range out. -/
  morph     : Float := 0.7
  /-- The large-scale elevation's amplitude, as a factor of the height
  function's (`shaders/frame.wgsl`): 1 as designed. -/
  amplitude : Float := 1
  deriving Repr, Inhabited

/-- How far above and below 0 the floor may reach, for culling: the
height's octaves' amplitudes summed, and some. -/
def Floor.relief (f : Floor) : Float := 1.2 * f.amplitude

/-- Cells a side of a patch at `detail`: scaled, even, at least 4. A leaf
stays the width it is; its cells get finer. -/
def Floor.cellsAt (f : Floor) (detail : Float) : Nat :=
  max 4 ((f.cells.toFloat * detail / 2).round.toUInt64.toNat * 2)

/--
The sand's wave ripples, as `shaders/sand.wgsl` draws them from the tile
`Reef/Ripples.lean` bakes (`shaders/ripples.wgsl`). The spacing and the
steepness are those of orbital ripples a few metres down (Wiberg and
Harris, 1994): the wavelength about 0.6 of the waves' orbital diameter at
the bed, the height about a seventh of the wavelength.
-/
structure Ripples where
  /-- Which way the waves run, in radians from the x axis; the crests lie
  across it. -/
  direction  : Float := 0.5
  /-- Crest to crest, in metres. -/
  wavelength : Float := 0.18
  /-- Trough to crest, as a fraction of the wavelength. -/
  steepness  : Float := 0.14
  /-- A factor on the height: 1 as designed, 0 none. -/
  amplitude  : Float := 1
  /-- How far the ripples' direction strays from the waves', in radians,
  here and there: more, and they bend and fork more. -/
  spread     : Float := 0.3
  /-- How far out of step the ripples' kernels are, 0 not at all, 1
  wholly: a little breaks the crests up. -/
  disorder   : Float := 0
  /-- The crests' sharpness: a power, under 1 sharp. -/
  sharpness  : Float := 0.6
  /-- The tile's texels a side: a power of two. -/
  texels     : Nat   := 2048
  /-- Ripples across the tile: even. -/
  perTile    : Nat   := 32
  /-- Within this distance of the eye, in metres, the ripples lift the
  mesh itself; beyond the next, the normal map alone carries them. -/
  fadeFrom   : Float := 4
  fadeTo     : Float := 8
  /-- How much the troughs darken, for the sky they cannot see: 0 not at
  all, 1 as the tile says. -/
  cavity     : Float := 0.5
  deriving Repr, Inhabited

/-- The tile's width, in metres. -/
def Ripples.tile (r : Ripples) : Float := r.perTile.toFloat * r.wavelength

/-- Trough to crest, in metres. -/
def Ripples.height (r : Ripples) : Float :=
  r.steepness * r.wavelength * r.amplitude

/-- What is shown of the scene besides itself: the development overlays. -/
structure Overlays where
  /-- Every mesh's edges, as lines over it. -/
  wireframe : Bool := true
  /-- The grid, a line a metre at the floor's height. -/
  grid      : Bool := false
  deriving Repr, Inhabited

/-- What `update` asks the program to do, which it cannot itself. -/
inductive Command where
  | toggleFullscreen
  /-- The window was resized: configure the surface again. -/
  | reconfigure
  /-- The detail changed: make the meshes again. -/
  | remesh
  deriving Repr

structure App where
  camera   : Camera        := Camera.initial
  held     : Held          := {}
  grid     : Grid          := {}
  floor    : Floor         := {}
  ripples  : Ripples       := {}
  detail   : Float         := 1
  overlays : Overlays      := {}
  /-- The mouse's place, in the window's units, and whether the main button
  is down. -/
  mouse    : Float × Float := (0, 0)
  dragging : Bool          := false
  /-- The window's size in pixels. -/
  width    : UInt32
  height   : UInt32
  /-- The last frame's time, in seconds. -/
  time     : Float         := 0
  quit     : Bool          := false
  deriving Repr, Inhabited

/-- The floor as its mesh is made: its cells at the detail. -/
def App.floorMesh (a : App) : Floor :=
  { a.floor with cells := a.floor.cellsAt a.detail }

/--
How much a wheel event is: a browser's units are pixels, SDL's tenths of
one, so that a finger moves the scene the same on both. The wheel's values
are the scroll's, which with natural scrolling (a Mac's default, assumed)
run against the fingers: negated, they are the fingers' own motion, right
and up, which the scene follows as it follows a drag.
-/
def wheelUnit : Float := if onWeb then -0.05 else -0.5

/-- Radians of orbit, or turn, per wheel unit, and per pixel dragged. -/
def orbitPerUnit : Float := 0.04
def orbitPerPixel : Float := 0.005
/-- Of the target's distance panned, per wheel unit, and per pixel. -/
def panPerUnit : Float := 0.02
def panPerPixel : Float := 0.002
/-- Of the dolly's exponent, per wheel unit, and per pixel. -/
def dollyPerUnit : Float := 0.1
def dollyPerPixel : Float := 0.01
/-- Metres a second the keys move; with Shift, times this again. -/
def moveSpeed : Float := 4
def moveFast : Float := 4

/-- The code of the key `c` names. -/
def keyOf (c : Char) : UInt32 := c.toNat.toUInt32

/-- `a` with its camera moved by `f`. -/
def App.moveCamera (a : App) (f : Camera → Camera) : App :=
  { a with camera := f a.camera }

/-- Orbit, pan, dolly or turn, as the modifiers say, by `dx` and `dy` in
units. -/
def App.viewport (a : App) (mods : Modifiers) (dx dy : Float)
    (orbitK panK dollyK : Float) : App :=
  if mods.alt then a.moveCamera (·.turn (-dx * orbitK) (dy * orbitK))
  else if mods.ctrl then a.moveCamera (·.dolly (dy * dollyK))
  -- Panned, the scene follows the fingers, or the pointer: the camera goes
  -- the other way.
  else if mods.shift then a.moveCamera (·.pan (-dx * panK) (-dy * panK))
  else a.moveCamera (·.orbit (-dx * orbitK) (dy * orbitK))

/-- A key held, or not: the moving keys. -/
def App.hold (a : App) (code : UInt32) (pressed : Bool) : App :=
  let h := a.held
  let h :=
    if code == keyOf 'w' || code == Key.up then { h with forward := pressed }
    else if code == keyOf 's' || code == Key.down then { h with back := pressed }
    else if code == keyOf 'a' || code == Key.left then { h with left := pressed }
    else if code == keyOf 'd' || code == Key.right then { h with right := pressed }
    else if code == keyOf 'q' then { h with down := pressed }
    else if code == keyOf 'e' then { h with up := pressed }
    else if Key.isShift code then { h with fast := pressed }
    else h
  { a with held := h }

/-- The state after `event`, and what the program should do about it. -/
def update (event : Event) (a : App) : App × List Command :=
  match event with
  | .quit => ({ a with quit := true }, [])
  | .resized width height => ({ a with width, height }, [.reconfigure])
  | .mouseMoved x y mods =>
    let (px, py) := a.mouse
    let a := { a with mouse := (x, y) }
    if !a.dragging then (a, [])
    else (a.viewport mods (x - px) (py - y) orbitPerPixel panPerPixel
      dollyPerPixel, [])
  | .mouseButton 1 pressed x y _ =>
    ({ a with dragging := pressed, mouse := (x, y) }, [])
  | .mouseButton .. => (a, [])
  | .wheel x y mods =>
    -- A pinch, or Ctrl and the wheel, dollies by the scroll itself (up, or
    -- spread, is in), not by the fingers' motion.
    if mods.ctrl then
      (a.moveCamera (·.dolly (y * wheelUnit.abs * dollyPerUnit)), [])
    else
      (a.viewport mods (x * wheelUnit) (y * wheelUnit) orbitPerUnit panPerUnit
        dollyPerUnit, [])
  | .key code pressed repeated _ =>
    let a := a.hold code pressed
    if !pressed || repeated then (a, [])
    else if code == keyOf 'f' then (a, [.toggleFullscreen])
    else if code == Key.escape && !onWeb then ({ a with quit := true }, [])
    else if code == Key.home then ({ a with camera := Camera.initial }, [])
    else if code == keyOf '1' then
      ({ a with overlays.wireframe := !a.overlays.wireframe }, [])
    else if code == keyOf '2' then ({ a with overlays.grid := !a.overlays.grid }, [])
    else if code == keyOf '[' then
      ({ a with detail := max 0.25 (a.detail / 2) }, [.remesh])
    else if code == keyOf ']' then
      ({ a with detail := min 4 (a.detail * 2) }, [.remesh])
    else (a, [])

/-- The state `dt` seconds on: the camera moved by the keys held. -/
def step (dt : Float) (a : App) : App :=
  let h := a.held
  let axis (pos neg : Bool) : Float :=
    (if pos then 1 else 0) - (if neg then 1 else 0)
  let speed := moveSpeed * (if h.fast then moveFast else 1) * dt
  let v : Vec3 := ⟨axis h.right h.left, axis h.up h.down,
                   axis h.forward h.back⟩
  if v == Vec3.zero then a else a.moveCamera (·.fly (speed * v))

end Reef
