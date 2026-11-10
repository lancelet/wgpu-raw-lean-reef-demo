import Reef.Platform
import Reef.Render
import Reef.Stats

/-!
# The demo

A window, a surface on it, and the reef drawn in every frame, till the
window closes (or, given `--frames N`, for `N` frames), with how fast it
draws in the bottom right. The surface is configured again when the window
is resized, or the surface says it must be.

F fills the screen, or leaves it; natively, Escape ends the demo (in a
browser, it leaves the screen, and the browser keeps it).

A frame ends the program by returning `false`, never by `IO.Process.exit`,
which in a browser would hang it: the program then ends with `main`'s code.
-/

open WebGPU.Raw WebGPU.Window

namespace Reef

/-- How many creatures glow. -/
def creatureCount : Nat := 120

/-- The overlay's text size, in pixels, for a target `height` high. -/
def textSize (height : UInt32) : UInt32 := max 16 (height / 54)

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

/-- The window, the surface, and the frames, on `device`. -/
def start (options : Options) (wgpu : Instance) (adapter : Adapter)
    (device : Device) : IO Unit := do
  let window ← options.window 960 540
  let surface ← window.createSurface wgpu
  let (status, capabilities) ← surface.getCapabilities adapter
  let some format := capabilities.formats[0]?
    | throw (IO.userError s!"the surface has no format: {repr status}")
  let alpha := capabilities.alphaModes.getD 0 .auto
  let renderer ← Renderer.create device format (creatures creatureCount)
  let size ← IO.mkRef (← configure window surface device format alpha)
  let reconfigure := do
    size.set (← configure window surface device format alpha)
  let drawn ← IO.mkRef 0
  let stats ← IO.mkRef ({ since := ← IO.monoNanosNow } : Stats)
  let busy ← IO.mkRef 0
  run fun time => do
    for event in ← window.poll do
      match event with
      | .quit => return false
      | .resized .. => reconfigure
      -- F, or with Shift (as a browser gives it).
      | .key 102 true false | .key 70 true false => toggleFullscreen window
      | .key 27 true _ => if !onWeb then return false
      | _ => pure ()
    let (width, height) ← size.get
    -- No texture: outdated, by a resize not yet seen, or lost, configure
    -- again; timed out, try again; and draw in the next frame.
    let draw (texture : Texture) : IO Unit := do
      let begun ← IO.monoNanosNow
      renderer.draw time width height texture
      busy.set ((← IO.monoNanosNow) - begun)
    match ← surface.presentFrame draw with
    | none => drawn.modify (· + 1)
    | some (.ok .outdated) | some (.ok .lost) => reconfigure
    | some (.ok .timeout) => pure ()
    | some status =>
      throw (IO.userError s!"no texture to draw in: {repr status}")
    let (next, summary) := (← stats.get).frame (← IO.monoNanosNow) (← busy.get)
    stats.set next
    if let some text := summary then
      renderer.overlay.show text (textSize height)
    let n ← drawn.get
    if options.frames == some n then
      IO.println s!"Drew {n} frames."
    return options.frames.all (n < ·)

end Reef

open Reef in
/-- The demo: `reef [--frames N] [--windowed] [--headless]`. -/
def main (args : List String) : IO UInt32 := do
  match Options.parse args with
  | .error message => IO.eprintln message; return 2
  | .ok options =>
    withDevice (start options)
    return 0
