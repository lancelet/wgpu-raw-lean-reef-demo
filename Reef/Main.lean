import Reef.Platform
import Reef.Render

/-!
# The demo

A window, a surface on it, and the reef drawn in every frame, till the
window closes (or, given `--frames N`, for `N` frames). The surface is
configured again when the window is resized, or the surface says it must be.

A frame ends the program by returning `false`, never by `IO.Process.exit`,
which in a browser would hang it: the program then ends with `main`'s code.
-/

open WebGPU.Raw WebGPU.Window

namespace Reef

/-- How many creatures glow. -/
def creatureCount : Nat := 120

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
  run fun time => do
    for event in ← window.poll do
      match event with
      | .quit       => return false
      | .resized .. => reconfigure
      | _           => pure ()
    let (width, height) ← size.get
    let aspect := width.toFloat / (max height 1).toFloat
    -- No texture: outdated, by a resize not yet seen, or lost, configure
    -- again; timed out, try again; and draw in the next frame.
    match ← surface.presentFrame (renderer.draw time aspect) with
    | none => drawn.modify (· + 1)
    | some (.ok .outdated) | some (.ok .lost) => reconfigure
    | some (.ok .timeout) => pure ()
    | some status =>
      throw (IO.userError s!"no texture to draw in: {repr status}")
    let n ← drawn.get
    if options.frames == some n then
      IO.println s!"Drew {n} frames."
    return options.frames.all (n < ·)

end Reef

open Reef in
/-- The demo: `reef [--frames N] [--headless]`. -/
def main (args : List String) : IO UInt32 := do
  match Options.parse args with
  | .error message => IO.eprintln message; return 2
  | .ok options =>
    withDevice (start options)
    return 0
