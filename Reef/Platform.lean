import WebGPUWindow

/-!
# Where the demo runs

Its options, from the command line natively (none in a browser), and its
window: natively, one of SDL's, or, with no display (as on macOS's CI
runners), a headless one; in a browser, the page's canvas.
-/

open WebGPU.Window

namespace Reef

/-- How the demo runs. -/
structure Options where
  /-- End after this many frames, if any; else when the window closes. -/
  frames   : Option Nat := none
  /-- Draw with no display, in a headless window (macOS only). -/
  headless : Bool       := false

/-- The options `args` give: `[--frames N] [--headless]`. -/
def Options.parse : List String → Except String Options
  | [] => pure {}
  | "--frames" :: n :: rest => do
    let some frames := n.toNat? | throw s!"not a number of frames: {n}"
    return { ← Options.parse rest with frames }
  | "--headless" :: rest => do
    return { ← Options.parse rest with headless := true }
  | arg :: _ => throw s!"unknown option: {arg}\n\
      usage: reef [--frames N] [--headless]"

/-- The window to draw in, `width` by `height`, as `options` say. -/
def Options.window (options : Options) (width height : UInt32) : IO Window :=
  if options.headless then Window.createHeadless width height
  else Window.create "A bioluminescent reef" width height

end Reef
