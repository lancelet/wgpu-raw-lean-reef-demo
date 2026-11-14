import Reef.Platform
import Reef.Render
import Reef.Stats

/-!
# The demo

A window, a surface on it, and the scene drawn in every frame, till the
window closes (or, given `--frames N`, for `N` frames, drawn or, the
window hidden, waited through), with how fast it
draws, and where the camera is, in the bottom right. The surface is
configured again when the window is resized, or the surface says it must
be.

Each frame is the shell around the state (`Reef/App.lean`): the events
since the last, through `update`; the time passed, through `step`; what
`update` asked for, done; then the state drawn. The program is the only
part that does anything but compute.

A frame ends the program by returning `false`, never by `IO.Process.exit`,
which in a browser would hang it: the program then ends with `main`'s code.
-/

open WebGPU.Raw WebGPU.Window

namespace Reef

/-- The overlay's text size, in pixels, for a target `height` high. -/
def textSize (height : UInt32) : UInt32 := max 16 (height / 54)

/-- The longest a frame counts as, in seconds: after a pause, no leap. -/
def longestStep : Float := 0.1

/-- Frames drawn before a screenshot's, at sixty a second, for what
evolves: three seconds. -/
def warmFrames : Nat := 180

/-- A screenshot's texture format: as a surface's, sRGB. -/
def screenshotFormat : TextureFormat := .rgba8UnormSrgb

/--
The sRGB kind of `format`, where it has one: the frame is drawn in sRGB on
every platform, so that it looks the same on each. Natively the surface's
preferred format is sRGB already; in a browser it is not, and the frame is
drawn through views of this kind instead.
-/
def srgbOf : TextureFormat → TextureFormat
  | .bgra8Unorm => .bgra8UnormSrgb
  | .rgba8Unorm => .rgba8UnormSrgb
  | format      => format

/--
Configure `surface` to `window`'s size in pixels, in `format`, with views
in `viewFormat` allowed where it differs; returns that size.
-/
def configure (window : Window) (surface : Surface) (device : Device)
    (format viewFormat : TextureFormat) (alpha : CompositeAlphaMode) :
    IO (UInt32 × UInt32) := do
  let (width, height) ← window.size
  surface.configure {
    device      := device
    format      := format
    viewFormats := if viewFormat == format then #[] else #[viewFormat]
    width       := width
    height      := height
    presentMode := .fifo
    alphaMode   := alpha
  }
  return (width, height)

/-- The camera the options put, or where the demo does. -/
def Options.camera' (o : Options) : Camera :=
  match o.camera with
  | some (x, y, z, yaw, pitch) =>
    { Camera.initial with position := ⟨x, y, z⟩, yaw := yaw * 0.0174533,
                          pitch := pitch * 0.0174533 }
  | none => Camera.initial

/-- The state at the start, `width` by `height`, as `options` say. -/
def Options.initial (o : Options) (width height : UInt32) : App :=
  let overlays : Overlays := {}
  let floor : Floor := {}
  let ripples : Ripples := {}
  let sun : Sun := {}
  let water : Water := {}
  { width, height, camera := o.camera'
    sun      := match o.sun with
      | some (azimuth, elevation) =>
        { azimuth := azimuth * 0.0174533, elevation := elevation * 0.0174533 }
      | none => sun
    water    := { water with wind  := o.wind.getD water.wind
                             depth := o.depth.getD water.depth }
    overlays := { wireframe := o.wireframe.getD overlays.wireframe
                  grid      := o.grid.getD overlays.grid }
    floor    := { floor with amplitude := o.relief.getD floor.amplitude }
    ripples  := { ripples with
                  amplitude := o.ripples.getD ripples.amplitude
                  direction := (o.waves.map (· * 0.0174533)).getD ripples.direction } }

/-- Fill the screen, or leave it; if the window cannot, say why. -/
def toggleFullscreen (window : Window) : IO Unit := do
  try window.setFullscreen !(← window.isFullscreen)
  catch e => IO.eprintln s!"{e}"

/-- `x` to `places` decimal places, signed. -/
def signed (x : Float) (places : Nat) : String :=
  (if x < 0 then "-" else "") ++ fixed x.abs places

/-- The camera, for the overlay: where it is, and which way it looks. -/
def describe (a : App) : String :=
  let c := a.camera
  let degrees (r : Float) : String := signed (r * 57.2958) 0
  s!"camera {signed c.position.x 1}, {signed c.position.y 1}, \
    {signed c.position.z 1}  yaw {degrees c.yaw} pitch {degrees c.pitch}  \
    sun {degrees a.sun.azimuth},{degrees a.sun.elevation}  \
    detail {signed a.detail 2}"

/-- A PPM image (binary, `P6`) of `width` by `height` pixels, from their
RGBA bytes, rows `row` bytes apart. -/
def ppm (width height row : Nat) (pixels : ByteArray) : ByteArray := Id.run do
  let mut out := s!"P6\n{width} {height}\n255\n".toUTF8
  for y in [0:height] do
    for x in [0:width] do
      let i := y * row + x * 4
      out := out.push pixels[i]! |>.push pixels[i + 1]! |>.push pixels[i + 2]!
  return out

/-- `buffer`'s first `size` bytes, read back. -/
def readbackBuffer (wgpu : Instance) (device : Device) (buffer : Buffer)
    (size : UInt64) : IO ByteArray := do
  let some copy ← device.createBuffer
      { label := "readback", size, usage := .mapRead ||| .copyDst }
    | throw (IO.userError "no buffer to read the buffer back into")
  let encoder ← device.createCommandEncoder none
  encoder.copyBufferToBuffer buffer 0 copy 0 size
  (← device.getQueue).submit #[← encoder.finish none]
  let status ← IO.mkRef none
  let _ ← copy.mapAsync .read 0 size .allowProcessEvents fun s _ =>
    status.set (some (s matches .ok .success))
  for _ in [0:5000] do
    if (← status.get).isSome then break
    wgpu.processEvents
    IO.sleep 1
  unless (← status.get) == some true do
    throw (IO.userError "the buffer was not read back")
  copy.readMapped 0 size

/-- The 32-bit float at byte `i` of `bytes`. -/
def floatAt (bytes : ByteArray) (i : Nat) : Float :=
  (Float32.ofBits (bytes[i]!.toUInt32 ||| (bytes[i + 1]!.toUInt32 <<< 8)
    ||| (bytes[i + 2]!.toUInt32 <<< 16) ||| (bytes[i + 3]!.toUInt32 <<< 24))).toFloat

/--
Say what sea the surface is, from its last moment baked: the waves'
height, as the significant wave height (four times the root mean square
of the surface), the root mean square of its slope, and the steepest.
-/
def describeSea (wgpu : Instance) (device : Device) (c : Caustics) : IO Unit := do
  let count := c.points * c.points
  let bytes ← readbackBuffer wgpu device c.field (count * 16).toUInt64
  let mut h2 := 0.0
  let mut s2 := 0.0
  let mut steepest := 0.0
  for i in [0:count] do
    let h := floatAt bytes (i * 16)
    let sx := floatAt bytes (i * 16 + 4)
    let sz := floatAt bytes (i * 16 + 8)
    h2 := h2 + h * h
    s2 := s2 + sx * sx + sz * sz
    steepest := max steepest (sx * sx + sz * sz)
  let n := count.toFloat
  IO.println s!"The sea: waves {fixed (4 * (h2 / n).sqrt * 100) 0} cm high \
    (significant), slope {fixed (s2 / n).sqrt 3} rms, \
    {fixed steepest.sqrt 2} at steepest."

/--
The pixels of `texture`, `width` by `height`, four bytes each, read back:
with the bytes a row takes, which is a multiple of 256.
-/
def readback (wgpu : Instance) (device : Device) (texture : Texture)
    (width height : UInt32) : IO (Nat × ByteArray) := do
  let row := (width.toNat * 4 + 255) / 256 * 256
  let size := (row * height.toNat).toUInt64
  let some buffer ← device.createBuffer
      { label := "readback", size, usage := .mapRead ||| .copyDst }
    | throw (IO.userError "no buffer to read the texture back into")
  let encoder ← device.createCommandEncoder none
  encoder.copyTextureToBuffer { texture }
    { layout := { bytesPerRow := row.toUInt32, rowsPerImage := height },
      buffer }
    { width, height }
  (← device.getQueue).submit #[← encoder.finish none]
  let status ← IO.mkRef none
  let _ ← buffer.mapAsync .read 0 size .allowProcessEvents fun s _ =>
    status.set (some (s matches .ok .success))
  for _ in [0:5000] do
    if (← status.get).isSome then break
    wgpu.processEvents
    IO.sleep 1
  unless (← status.get) == some true do
    throw (IO.userError "the texture was not read back")
  return (row, ← buffer.readMapped 0 size)

/--
Draw `app`'s one frame into a texture `app.width` by `app.height`, the
overlay with the camera's line over it, read it back, and write it to
`path` as a PPM image: as the frame looks, the texture's format the
surface's kind (sRGB), the file's bytes as shown.
-/
def screenshot (wgpu : Instance) (device : Device) (renderer : Renderer)
    (app : App) (path : String) : IO Unit := do
  let (width, height) := (app.width, app.height)
  let texture ← device.createTexture {
    label  := "screenshot"
    usage  := .renderAttachment ||| .copySrc
    size   := { width, height }
    format := screenshotFormat
  }
  -- Some seconds of frames first, for what evolves (the bubbles rise,
  -- the caustics' loop and the swell are at the moment): then the overlay
  -- too, with the camera's line and the patches drawn, how the text
  -- looks.
  for i in [0:warmFrames] do
    renderer.draw { app with time := app.time + i.toFloat / 60 } texture
  let app := { app with time := app.time + warmFrames.toFloat / 60 }
  renderer.overlay.show s!"{describe app}  patches {← renderer.drawn.get}"
    (textSize height)
  renderer.draw app texture
  let (row, pixels) ← readback wgpu device texture width height
  IO.FS.writeBinFile path (ppm width.toNat height.toNat row pixels)
  IO.println s!"Wrote {path}: {width}x{height}, {← renderer.drawn.get} patches."

/--
Write `tile`, `texels` a side as baked, to `path` as a PPM image, its
first three channels as red, green and blue, and its fourth, as grey, to
`path` with `-alpha` before its extension: for looking at a bake. The
ripples' tile is height, two slopes and cavity; the grains' a normal and
brightness.
-/
def dumpTile (wgpu : Instance) (device : Device) (tile : Tile)
    (texels : Nat) (path : String) : IO Unit := do
  let n := texels.toUInt32
  let (row, pixels) ← readback wgpu device tile.texture n n
  IO.FS.writeBinFile path (ppm texels texels row pixels)
  let alpha := Id.run do
    let mut grey := pixels
    for i in [0:pixels.size / 4] do
      let a := pixels[i * 4 + 3]!
      grey := grey.set! (i * 4) a |>.set! (i * 4 + 1) a |>.set! (i * 4 + 2) a
    return grey
  let stem := (path.splitOn ".").dropLast
  let alphaPath := if stem.isEmpty then path ++ "-alpha"
    else String.intercalate "." stem ++ "-alpha." ++ (path.splitOn ".").getLast!
  IO.FS.writeBinFile alphaPath (ppm texels texels row alpha)
  IO.println s!"Wrote {path} and {alphaPath}: {n}x{n}."

/-- The window, the surface, and the frames, on `device`. -/
def start (options : Options) (wgpu : Instance) (adapter : Adapter)
    (device : Device) (timestamps : Bool) : IO Unit := do
  let window ← options.window 960 540
  if options.screenshot.isSome || options.tile.isSome
      || options.grainTile.isSome || options.causticTile.isSome then
    let (width, height) ← window.size
    let app := options.initial width height
    let renderer ← Renderer.create device screenshotFormat app.floorMesh
      app.ripples app.grains app.water
    if let some path := options.tile then
      dumpTile wgpu device renderer.ripples app.ripples.texels path
      let stem := (path.splitOn ".").dropLast
      let horizonsPath := if stem.isEmpty then path ++ "-horizons"
        else String.intercalate "." stem ++ "-horizons." ++ (path.splitOn ".").getLast!
      dumpTile wgpu device renderer.horizons app.ripples.texels horizonsPath
    if let some path := options.grainTile then
      dumpTile wgpu device renderer.grains app.grains.texels path
    if let some path := options.causticTile then
      dumpTile wgpu device { renderer.caustics with sampler := renderer.grains.sampler
                             : Tile } app.water.texels path
      describeSea wgpu device renderer.caustics
    if let some path := options.screenshot then
      screenshot wgpu device renderer app path
    return
  let surface ← window.createSurface wgpu
  let (status, capabilities) ← surface.getCapabilities adapter
  let some format := capabilities.formats[0]?
    | throw (IO.userError s!"the surface has no format: {repr status}")
  let alpha := capabilities.alphaModes.getD 0 .auto
  let viewFormat := srgbOf format
  let (width, height) ←
    configure window surface device format viewFormat alpha
  let initial := options.initial width height
  let renderer ← Renderer.create device viewFormat initial.floorMesh
    initial.ripples initial.grains initial.water timestamps
  let app ← IO.mkRef initial
  let reconfigure := do
    let (width, height) ←
      configure window surface device format viewFormat alpha
    app.modify fun a => { a with width, height }
  let drawn ← IO.mkRef 0
  let stats ← IO.mkRef ({ since := ← IO.monoNanosNow } : Stats)
  let busy ← IO.mkRef 0
  let summary ← IO.mkRef ""
  run fun now => do
    let mut a ← app.get
    let mut commands := []
    for event in ← window.poll do
      let (next, more) := update event a
      a := next
      commands := commands ++ more
    a := step (min (now - a.time) longestStep) { a with time := now }
    app.set a
    if a.quit then return false
    for command in commands do
      match command with
      | .toggleFullscreen => toggleFullscreen window
      | .reconfigure => reconfigure
      | .remesh => renderer.remesh a.floorMesh
    -- No texture: outdated, by a resize not yet seen, or lost, configure
    -- again; timed out, or hidden, try again; and draw in the next frame.
    let draw (texture : Texture) : IO Unit := do
      let begun ← IO.monoNanosNow
      renderer.draw (← app.get) texture
      busy.set ((← IO.monoNanosNow) - begun)
    match ← surface.presentFrame draw with
    | none => drawn.modify (· + 1)
    | some (.ok .outdated) | some (.ok .lost) => reconfigure
    | some (.ok .timeout) => pure ()
    -- Hidden, behind other windows or not yet shown: nothing to draw in
    -- till it shows; wait a little rather than spin. It counts as a frame,
    -- so that `--frames N` ends where no window ever shows.
    | some (.error code) =>
      unless code == occluded do
        throw (IO.userError s!"no texture to draw in: {code}")
      IO.sleep 16
      drawn.modify (· + 1)
    | some status =>
      throw (IO.userError s!"no texture to draw in: {repr status}")
    let (next, text) := (← stats.get).frame (← IO.monoNanosNow) (← busy.get)
      passes (← renderer.gpuTimes)
    stats.set next
    if let some text := text then summary.set text
    let shown ← app.get
    renderer.overlay.show
      s!"{← summary.get}\n{describe shown}  patches {← renderer.drawn.get}"
      (textSize shown.height)
    let n ← drawn.get
    if options.frames == some n then
      IO.println s!"Drew {n} frames.\n{← summary.get}"
    return options.frames.all (n < ·)

end Reef

open Reef in
/-- The demo: `reef [--frames N] [--windowed] [--headless] [--screenshot FILE]
[--camera X,Y,Z,YAW,PITCH] [--wireframe on|off] [--grid on|off]
[--sun AZIMUTH,ELEVATION] [--relief FACTOR] [--ripples FACTOR]
[--waves DEGREES] [--wind SPEED] [--depth METRES] [--tile FILE]
[--grain-tile FILE] [--caustic-tile FILE]`. -/
def main (args : List String) : IO UInt32 := do
  match Options.parse args with
  | .error message => IO.eprintln message; return 2
  | .ok options =>
    withDevice (start options)
    return 0
