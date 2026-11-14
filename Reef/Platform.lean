import WebGPUWindow

/-!
# Where the demo runs

Its options, from the command line natively (none in a browser), and its
window: natively, one of SDL's, filling the screen unless asked not to, or,
with no display (as on macOS's CI runners), a headless one; in a browser,
the page's canvas, filling the page.
-/

open WebGPU.Window

namespace Reef

/-- How the demo runs. -/
structure Options where
  /-- End after this many frames, if any; else when the window closes. -/
  frames   : Option Nat := none
  /-- Draw with no display, in a headless window (macOS only). -/
  headless : Bool       := false
  /-- Draw in a window, not filling the screen (natively). -/
  windowed : Bool       := false
  /-- Draw one frame into this file, as a PPM image, and end. -/
  screenshot : Option String := none
  /-- Where the camera starts, if not where the demo puts it: `x,y,z` in
  metres, and `yaw,pitch` in degrees. -/
  camera     : Option (Float × Float × Float × Float × Float) := none
  /-- Whether the wireframe, and the grid, show at the start, if said. -/
  wireframe  : Option Bool := none
  grid       : Option Bool := none
  /-- The window's size, in pixels, if said: for a screenshot or a timing
  at the size of the screen. -/
  size       : Option (Nat × Nat) := none
  /-- Where the sun is, if said: round from the x axis, and up from the
  horizon, in degrees. -/
  sun        : Option (Float × Float) := none
  /-- The wind over the sea, in metres a second, and the water's depth,
  in metres, if said. -/
  wind       : Option Float := none
  depth      : Option Float := none
  /-- The floor's relief, as a factor of its design, if said. -/
  relief     : Option Float := none
  /-- The ripples' height, as a factor of their design, if said. -/
  ripples    : Option Float := none
  /-- Which way the waves run, in degrees from the x axis, if said. -/
  waves      : Option Float := none
  /-- Write the ripples' tile, or the grains', as baked, to this file, a
  PPM image, and end (for looking at the bake). -/
  tile        : Option String := none
  grainTile   : Option String := none
  /-- Write the caustics' first moment, as baked, likewise. -/
  causticTile : Option String := none

/-- How to run the demo. -/
def usage : String :=
  "usage: reef [--frames N] [--windowed] [--headless] [--screenshot FILE] \
    [--camera X,Y,Z,YAW,PITCH] [--wireframe on|off] [--grid on|off] \
    [--size WIDTHxHEIGHT] [--sun AZIMUTH,ELEVATION] [--relief FACTOR] [--ripples FACTOR] \
    [--waves DEGREES] [--wind SPEED] [--depth METRES] [--tile FILE] \
    [--grain-tile FILE] [--caustic-tile FILE]"

/-- `s` as a switch, if it is one. -/
def parseSwitch (s : String) : Option Bool :=
  if s == "on" then some true else if s == "off" then some false else none

/-- `s` as a float, if it is one (`Float` has no parser of its own). -/
def parseFloat (s : String) : Option Float := do
  let (sign, s) := if s.startsWith "-" then (-1.0, (s.drop 1).toString)
    else (1.0, s)
  let parts := s.splitOn "."
  let whole ← parts[0]?.bind String.toNat?
  let frac := parts[1]?.getD ""
  guard (parts.length ≤ 2 && (frac.isEmpty || frac.toNat?.isSome))
  let fracValue := (frac.toNat?.getD 0).toFloat / (10 : Float) ^ frac.length.toFloat
  return sign * (whole.toFloat + fracValue)

/-- The options `args` give, as `usage` says. -/
def Options.parse : List String → Except String Options
  | [] => pure {}
  | "--frames" :: n :: rest => do
    let some frames := n.toNat? | throw s!"not a number of frames: {n}"
    return { ← Options.parse rest with frames }
  | "--headless" :: rest => do
    return { ← Options.parse rest with headless := true }
  | "--windowed" :: rest => do
    return { ← Options.parse rest with windowed := true }
  | "--screenshot" :: file :: rest => do
    return { ← Options.parse rest with screenshot := some file }
  | "--camera" :: spec :: rest => do
    let some [x, y, z, yaw, pitch] := (spec.splitOn ",").mapM parseFloat
      | throw s!"not a camera: {spec} (X,Y,Z,YAW,PITCH)"
    return { ← Options.parse rest with camera := some (x, y, z, yaw, pitch) }
  | "--wind" :: speed :: rest => do
    let some speed := parseFloat speed | throw s!"not a speed: {speed}"
    return { ← Options.parse rest with wind := some speed }
  | "--depth" :: metres :: rest => do
    let some metres := parseFloat metres | throw s!"not a depth: {metres}"
    return { ← Options.parse rest with depth := some metres }
  | "--size" :: spec :: rest => do
    let some [w, h] := (spec.splitOn "x").mapM String.toNat?
      | throw s!"not a size: {spec} (WIDTHxHEIGHT)"
    return { ← Options.parse rest with size := some (w, h) }
  | "--sun" :: spec :: rest => do
    let some [azimuth, elevation] := (spec.splitOn ",").mapM parseFloat
      | throw s!"not a sun: {spec} (AZIMUTH,ELEVATION, in degrees)"
    return { ← Options.parse rest with sun := some (azimuth, elevation) }
  | "--wireframe" :: on :: rest => do
    let some on := parseSwitch on | throw s!"not on or off: {on}"
    return { ← Options.parse rest with wireframe := some on }
  | "--grid" :: on :: rest => do
    let some on := parseSwitch on | throw s!"not on or off: {on}"
    return { ← Options.parse rest with grid := some on }
  | "--relief" :: factor :: rest => do
    let some factor := parseFloat factor | throw s!"not a factor: {factor}"
    return { ← Options.parse rest with relief := some factor }
  | "--ripples" :: factor :: rest => do
    let some factor := parseFloat factor | throw s!"not a factor: {factor}"
    return { ← Options.parse rest with ripples := some factor }
  | "--waves" :: degrees :: rest => do
    let some degrees := parseFloat degrees | throw s!"not degrees: {degrees}"
    return { ← Options.parse rest with waves := some degrees }
  | "--tile" :: file :: rest => do
    return { ← Options.parse rest with tile := some file }
  | "--grain-tile" :: file :: rest => do
    return { ← Options.parse rest with grainTile := some file }
  | "--caustic-tile" :: file :: rest => do
    return { ← Options.parse rest with causticTile := some file }
  | arg :: _ => throw s!"unknown option: {arg}\n{usage}"

/--
The window to draw in, as `options` say: filling the screen (natively) or
the page (in a browser), unless `windowed`, when it is `width` by `height`,
as it is when it leaves the screen.
-/
def Options.window (options : Options) (width height : UInt32) : IO Window :=
  if options.headless then Window.createHeadless width height
  else Window.create "A bioluminescent reef" width height
    (fullscreen := !options.windowed)

end Reef
