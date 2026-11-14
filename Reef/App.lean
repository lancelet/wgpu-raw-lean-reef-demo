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
back where it started; 1 shows the wireframe, or hides it, 2 the grid, and
3 the bommies' envelope meshes in place of the rock;
`[` and `]` halve and double the detail, how finely every mesh is made;
`,` and `.` swing the sun round, `-` and `=` lower and raise it; F fills
the screen, or leaves it; Escape ends the demo, natively.
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
  function's (`shaders/frame.wgsl`): 1 as designed. The sand waves and
  hummocks on it are not scaled with it. -/
  amplitude : Float := 1
  deriving Repr, Inhabited

/-- How far above and below 0 the floor may reach, for culling: the
height's octaves' amplitudes summed, and some; the sand waves' and
hummocks' are not scaled by the amplitude. -/
def Floor.relief (f : Floor) : Float := 1.7 * f.amplitude + 0.2

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
  sharpness  : Float := 0.5
  /-- How much of the wavelength the gentle rise to a crest takes, the
  steep fall down its lee the rest: 0.5 symmetric. -/
  asymmetry  : Float := 0.65
  /-- The small ripples' height, riding on the ripples, as a fraction of
  theirs: 0 none. -/
  fine       : Float := 0.08
  /-- The scour pits: how many a wavelength's square where they run, 0
  none to 1 one each; and how deep at most, as a fraction of the ripples'
  height. -/
  pits       : Float := 0.35
  pitDepth   : Float := 0.4
  /-- The slip faces: sand carried over a crest comes to rest at its
  angle of repose, a straight face down the lee, in radians (30 degrees
  under water); and how much of the field has them, 0 none to 1 all. -/
  repose     : Float := 0.52
  slipFaces  : Float := 0.7
  /-- The tile's texels a side: a power of two. -/
  texels     : Nat   := 2048
  /-- Ripples across the tile: even. -/
  perTile    : Nat   := 32
  /-- Within this distance of the eye, in metres, the ripples lift the
  mesh itself (as far as its cells can carry them); beyond the next, the
  normal map alone carries them. -/
  fadeFrom   : Float := 8
  fadeTo     : Float := 16
  /-- How much the troughs darken, for the sky they cannot see: 0 not at
  all, 1 as the tile says. -/
  cavity     : Float := 0.5
  deriving Repr, Inhabited

/-- The tile's width, in metres. -/
def Ripples.tile (r : Ripples) : Float := r.perTile.toFloat * r.wavelength

/-- The wave number, in radians a metre, of a water wave of `period`
seconds in water `depth` metres deep, by the dispersion relation
(the frequency squared is gravity times the wave number times the
hyperbolic tangent of the wave number times the depth), iterated from
the deep-water wave number. -/
def waveNumber (period depth : Float) : Float := Id.run do
  let omega := 2 * 3.14159265 / period
  let deep := omega * omega / 9.81
  let mut k := deep
  for _ in [0:12] do
    k := deep / (k * depth).tanh
  return k

/-- The periods of the swell's three waves, as fractions of its own
(`shaders/frame.wgsl` has the same). -/
def swellPeriodFractions : Array Float := #[1, 1.21, 0.83, 1.55]

/--
The sand's grains, as `shaders/sand.wgsl` draws them from the tile
`Reef/Grains.lean` bakes (`shaders/grains.wgsl`): medium sand, with
fragments of shell and the like among the grains.
-/
structure Grains where
  /-- The tile's width, in metres: a few centimetres, the grains within
  having no pattern to show its repeating. -/
  tile      : Float := 0.04
  /-- The tile's texels a side: a power of two. -/
  texels    : Nat   := 1024
  /-- A grain's diameter, in metres. -/
  grain     : Float := 0.0005
  /-- A fragment's diameter, in metres, and how many of the fragments'
  cells (a diameter wide) hold one, 0 none to 1 all. -/
  fragment  : Float := 0.003
  fragments : Float := 0.12
  /-- How much the grains tilt the normal, and speckle the colour: 1 as
  designed, 0 none. -/
  relief    : Float := 1
  speckle   : Float := 1
  deriving Repr, Inhabited

/-- The tile's height from its lowest to its highest, in metres: the
ripples' trough to crest (the steepness of the wavelength), and the small
ripples' and the pits' on top, as the bake sums them. -/
def Ripples.height (r : Ripples) : Float :=
  r.steepness * r.wavelength * r.amplitude * (1 + r.fine + r.pitDepth)

/-- The sun, as `shaders/sand.wgsl` lights by it: where it is in the sky.
Under water the sun is never lower than about 41 degrees up, the surface
bending even a setting sun that high: 41 is a sun on the horizon. By
default 55 degrees, a sun 40 degrees up in the air, mid-morning: in the
sky through the window, and low enough that the ripples' shade shows
(lower still is allowed, for the look). -/
structure Sun where
  /-- Round from the x axis, in radians. -/
  azimuth   : Float := 0.36
  /-- Up from the horizon, in radians. -/
  elevation : Float := 0.96
  deriving Repr, Inhabited

/-- The direction the sun's light comes from: unit, up. -/
def Sun.direction (s : Sun) : Vec3 :=
  ⟨s.elevation.cos * s.azimuth.cos, s.elevation.sin, s.elevation.cos * s.azimuth.sin⟩

/--
The water, as `shaders/frame.wgsl` colours by it: a warm tropical reef's
as an animated film paints it, clear, the water a deep gradient from a
bright cerulean toward the surface through turquoise level to a cobalt
blue far and below, the sun's light warm and the sky's a cool blue, so
that the sand is cream in the sun and blue in its shade. Colours are
linear. The water takes each colour at its own rate with distance, red
first; what it scatters in along the way is its own colour, by the
direction looked in.
-/
structure Water where
  /-- The surface's height above the floor's zero, in metres. -/
  depth      : Float := 4
  /-- How fast the water takes red, green and blue, per metre. -/
  extinction : Vec3  := ⟨0.1, 0.045, 0.025⟩
  /-- Its colour seen level, far off; up, toward the surface; down: a deep
  saturated teal, dark against the sand, as a photograph exposed for the
  sand has it. -/
  horizon    : Vec3  := ⟨0.0, 0.1, 0.23⟩
  zenith     : Vec3  := ⟨0.04, 0.3, 0.55⟩
  deep       : Vec3  := ⟨0.0, 0.03, 0.14⟩
  /-- The sun's light at the floor, warm, and the sky's from all above,
  dim and blue. -/
  sunlight   : Vec3  := ⟨1.7, 1.4, 1.0⟩
  skylight   : Vec3  := ⟨0.08, 0.17, 0.3⟩
  /-- The caustics' strength, 0 none to 1 as the surface makes them; and
  their fringes of colour, how far the water's index for red and for blue
  lie either side of green's: 0.006 in truth (1.331 at 656 nm, 1.343 at
  486 nm, about 1.333 at 550), 0 no fringes. -/
  focus      : Float := 1
  dispersion : Float := 0.006
  /-- The sea's surface (`shaders/ocean.wgsl`): one tile of it, this wide,
  in metres, repeating; the wind that makes its waves, in metres a second
  (a breeze of four by default; whitecaps from about seven), and its
  direction, in radians from the x axis; how high the chop is at a wind
  of four, a factor, growing with the wind's square; the shortest wave
  kept, in metres. -/
  tile          : Float := 8
  wind          : Float := 4.0
  windDirection : Float := 0.5
  amplitude     : Float := 0.0006
  shortest      : Float := 0.12
  /-- The caustics' loop (`Reef/Caustics.lean`): its length, in seconds,
  and its moments, baked as the layers of a texture this many texels a
  side; the grid of the surface drawn into each, quads a side, and its
  margin beyond the tile, in metres. -/
  loop          : Float := 3
  frames        : Nat   := 72
  texels        : Nat   := 512
  grid          : Nat   := 512
  margin        : Float := 0.6
  /-- The surface as drawn from below (`shaders/surface.wgsl`): its grid,
  cells a side, and how far from the camera it reaches, in metres. -/
  surfaceGrid   : Nat   := 192
  surfaceReach  : Float := 400
  /-- The light in the water (`shaders/shafts.wgsl`): the sun's light
  scattered toward the camera by what the water holds, in shafts under
  the surface's bright filaments: its strength, 0 none; the steps a pixel
  marches its ray; and how far, in metres. -/
  shafts        : Float := 0.85
  shaftSteps    : Nat   := 12
  shaftReach    : Float := 30
  /-- The marine snow (`Reef/Snow.lean`): how many flecks, and the
  half-width of the box about the camera they are kept in, in metres. -/
  snow          : Nat   := 32000
  snowReach     : Float := 6
  /-- The frame's exposure (`shaders/resolve.wgsl`): the light multiplied
  before the filmic curve. -/
  exposure      : Float := 0.6
  /-- The swell (`shaders/frame.wgsl`): the long waves under the chop, a
  heave of the surface that passes overhead. Its height, trough to crest,
  in metres; its period, in seconds, which with the depth fixes its
  length (`waveNumber`): the ocean's swell, 8 to 14 seconds, is 60 m long
  here and felt rather than seen, a lagoon's wind sea of three or four
  seconds is 15 to 20 m and seen; how far its waves' headings spread
  about the ripples', in radians. -/
  swellHeight   : Float := 0.5
  swellPeriod   : Float := 3.5
  swellSpread   : Float := 0.25
  deriving Repr, Inhabited

/-- How much rougher the sea is than at a breeze of four metres a second:
the wind's square over that wind's. -/
def Water.rougher (w : Water) : Float := (w.wind / 4) * (w.wind / 4)

/-- The chop's amplitude at this wind. -/
def Water.chopAmplitude (w : Water) : Float := w.amplitude * w.rougher

/-- The swell's height at this wind: the design's, growing with the
wind's square too (a wind sea, which the swell here is). -/
def Water.swellAtWind (w : Water) : Float := w.swellHeight * w.rougher

/-- What is shown of the scene besides itself: the development overlays. -/
structure Overlays where
  /-- Every mesh's edges, as lines over it. -/
  wireframe : Bool := false
  /-- The grid, a line a metre at the floor's height. -/
  grid      : Bool := false
  /-- The bommies' envelope meshes alone, faceted, in place of the rock
  marched in from them (`shaders/bommie.wgsl`). -/
  envelope  : Bool := false
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
  grains   : Grains        := {}
  sun      : Sun           := {}
  water    : Water         := {}
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

/-- Radians the sun swings round, and rises or sets, a key press: 10 and
5 degrees. -/
def sunSwing : Float := 0.1745
def sunLift : Float := 0.0873

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
    else if code == keyOf '3' then
      ({ a with overlays.envelope := !a.overlays.envelope }, [])
    else if code == keyOf '[' then
      ({ a with detail := max 0.25 (a.detail / 2) }, [.remesh])
    else if code == keyOf ']' then
      ({ a with detail := min 4 (a.detail * 2) }, [.remesh])
    else if code == keyOf ',' then
      ({ a with sun.azimuth := a.sun.azimuth - sunSwing }, [])
    else if code == keyOf '.' then
      ({ a with sun.azimuth := a.sun.azimuth + sunSwing }, [])
    else if code == keyOf '-' then
      ({ a with sun.elevation := max 0.09 (a.sun.elevation - sunLift) }, [])
    else if code == keyOf '=' then
      ({ a with sun.elevation := min 1.57 (a.sun.elevation + sunLift) }, [])
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
