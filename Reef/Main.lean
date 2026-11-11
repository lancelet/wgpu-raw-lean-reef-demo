import Reef.Platform
import Reef.Render
import Reef.Stats

/-!
# The demo

A window, a surface on it, and the scene drawn in every frame, till the
window closes (or, given `--frames N`, for `N` frames), with how fast it
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

/-- A screenshot's texture format: as a surface's, sRGB. -/
def screenshotFormat : TextureFormat := .rgba8UnormSrgb

/-- Configure `surface` to `window`'s size in pixels; returns that size. -/
def configure (window : Window) (surface : Surface) (device : Device)
    (format : TextureFormat) (alpha : CompositeAlphaMode) :
    IO (UInt32 × UInt32) := do
  let (width, height) ← window.size
  surface.configure {
    device      := device
    format      := format
    width       := width
    height      := height
    presentMode := .fifo
    alphaMode   := alpha
  }
  return (width, height)

/-- Fill the screen, or leave it; if the window cannot, say why. -/
def toggleFullscreen (window : Window) : IO Unit := do
  try window.setFullscreen !(← window.isFullscreen)
  catch e => IO.eprintln s!"{e}"

/-- `x` to `places` decimal places, signed. -/
def signed (x : Float) (places : Nat) : String :=
  (if x < 0 then "-" else "") ++ fixed x.abs places

/-- The camera, for the overlay: the mode, where it is, which way it looks. -/
def describe (a : App) : String :=
  let c := a.camera
  let degrees (r : Float) : String := signed (r * 57.2958) 0
  s!"{if a.mode == .orbit then "orbit" else "fly  "} \
    at {signed c.position.x 1}, {signed c.position.y 1}, \
    {signed c.position.z 1}  yaw {degrees c.yaw} pitch {degrees c.pitch}"

/-- A PPM image (binary, `P6`) of `width` by `height` pixels, from their
RGBA bytes, rows `row` bytes apart. -/
def ppm (width height row : Nat) (pixels : ByteArray) : ByteArray := Id.run do
  let mut out := s!"P6\n{width} {height}\n255\n".toUTF8
  for y in [0:height] do
    for x in [0:width] do
      let i := y * row + x * 4
      out := out.push pixels[i]! |>.push pixels[i + 1]! |>.push pixels[i + 2]!
  return out

/--
Draw `app`'s one frame into a texture `app.width` by `app.height`, read it
back, and write it to `path` as a PPM image: as the frame looks, the
texture's format the surface's kind (sRGB), the file's bytes as shown.
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
  renderer.draw app texture
  -- A row of the copy, a multiple of 256 bytes.
  let row := (width.toNat * 4 + 255) / 256 * 256
  let size := (row * height.toNat).toUInt64
  let some buffer ← device.createBuffer
      { label := "screenshot", size, usage := .mapRead ||| .copyDst }
    | throw (IO.userError "no buffer for the screenshot")
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
    throw (IO.userError "the screenshot was not read back")
  IO.FS.writeBinFile path
    (ppm width.toNat height.toNat row (← buffer.readMapped 0 size))
  IO.println s!"Wrote {path}: {width}x{height}."

/-- The window, the surface, and the frames, on `device`. -/
def start (options : Options) (wgpu : Instance) (adapter : Adapter)
    (device : Device) : IO Unit := do
  let window ← options.window 960 540
  if let some path := options.screenshot then
    let (width, height) ← window.size
    let renderer ← Renderer.create device screenshotFormat
    screenshot wgpu device renderer { width, height } path
    return
  let surface ← window.createSurface wgpu
  let (status, capabilities) ← surface.getCapabilities adapter
  let some format := capabilities.formats[0]?
    | throw (IO.userError s!"the surface has no format: {repr status}")
  let alpha := capabilities.alphaModes.getD 0 .auto
  let renderer ← Renderer.create device format
  let (width, height) ← configure window surface device format alpha
  let app ← IO.mkRef ({ width, height } : App)
  let reconfigure := do
    let (width, height) ← configure window surface device format alpha
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
    -- No texture: outdated, by a resize not yet seen, or lost, configure
    -- again; timed out, try again; and draw in the next frame.
    let draw (texture : Texture) : IO Unit := do
      let begun ← IO.monoNanosNow
      renderer.draw (← app.get) texture
      busy.set ((← IO.monoNanosNow) - begun)
    match ← surface.presentFrame draw with
    | none => drawn.modify (· + 1)
    | some (.ok .outdated) | some (.ok .lost) => reconfigure
    | some (.ok .timeout) => pure ()
    | some status =>
      throw (IO.userError s!"no texture to draw in: {repr status}")
    let (next, text) := (← stats.get).frame (← IO.monoNanosNow) (← busy.get)
    stats.set next
    if let some text := text then summary.set text
    let shown ← app.get
    renderer.overlay.show s!"{← summary.get}\n{describe shown}"
      (textSize shown.height)
    let n ← drawn.get
    if options.frames == some n then
      IO.println s!"Drew {n} frames."
    return options.frames.all (n < ·)

end Reef

open Reef in
/-- The demo: `reef [--frames N] [--windowed] [--headless] [--screenshot FILE]`. -/
def main (args : List String) : IO UInt32 := do
  match Options.parse args with
  | .error message => IO.eprintln message; return 2
  | .ok options =>
    withDevice (start options)
    return 0
