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

/-- How to run the demo. -/
def usage : String := "usage: reef [--frames N] [--windowed] [--headless]"

/-- The options `args` give: `[--frames N] [--windowed] [--headless]`. -/
def Options.parse : List String → Except String Options
  | [] => pure {}
  | "--frames" :: n :: rest => do
    let some frames := n.toNat? | throw s!"not a number of frames: {n}"
    return { ← Options.parse rest with frames }
  | "--headless" :: rest => do
    return { ← Options.parse rest with headless := true }
  | "--windowed" :: rest => do
    return { ← Options.parse rest with windowed := true }
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
