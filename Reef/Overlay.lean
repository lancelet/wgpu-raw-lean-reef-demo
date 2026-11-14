import Reef.Base64
import Reef.Fonts
import Reef.Gpu
import Reef.Shaders
import WebGPUWindow

/-!
# The overlay

Text over the reef, in the bottom right: drawn as pixels by the window
library (`textImage`, in JetBrains Mono, embedded: `fonts/`), written into
a texture, and drawn from it a pixel to a pixel, on a translucent panel,
over the frame. The text is drawn again only when it, or its size, changes;
the texture made again only when its size does.
-/

open WebGPU.Raw WebGPU.Window

namespace Reef

/-- The text's texture, its bind group, and its size in pixels. -/
structure OverlayText where
  texture : Texture
  data    : BindGroup
  width   : UInt32
  height  : UInt32

/-- The overlay: what drawing it needs, and the text, once there is some. -/
structure Overlay where
  device    : Device
  queue     : Queue
  pipeline  : RenderPipeline
  /-- The text's font: JetBrains Mono. -/
  font      : Font
  /-- Where the text goes, written each frame. -/
  placement : Buffer
  /-- The text, as a texture, if any; and what it shows, at what size. -/
  text      : IO.Ref (Option OverlayText × String × UInt32)

/-- Drawn over what is there, as much as it is opaque. -/
def over : BlendState := {
  color := { operation := .add, srcFactor := .srcAlpha,
             dstFactor := .oneMinusSrcAlpha }
  alpha := { operation := .add, srcFactor := .zero, dstFactor := .one }
}

/-- The panel's padding around the text, in pixels, for text `size` high. -/
def padding (size : UInt32) : UInt32 := max 4 (size / 3)

/--
Where the text, `width` by `height`, goes in a target `targetWidth` by
`targetHeight`: in the bottom right, its panel a padding from the edges, as
`shaders/overlay.wgsl` reads it: 32 bytes.
-/
def placementBytes (targetWidth targetHeight width height pad : UInt32) :
    ByteArray :=
  let f (n : UInt32) : Float := n.toFloat
  [f targetWidth, f targetHeight,
   f targetWidth - f width - 2 * f pad, f targetHeight - f height - 2 * f pad,
   f width, f height, f pad, 0].foldl pushF32 ByteArray.empty

/-- An overlay, drawing into targets of `format`, in a pass with a depth
buffer of `depthFormat`, which it neither tests nor writes; no text yet. -/
def Overlay.create (device : Device) (format depthFormat : TextureFormat) :
    IO Overlay := do
  let module ← createShader device "overlay" Shaders.overlay
  let pipeline ← device.createRenderPipeline {
    label    := "overlay"
    vertex   := { module := module, entryPoint := some "vs" }
    fragment := some {
      module     := module
      entryPoint := some "fs"
      targets    := #[{ format := format, blend := some over }]
    }
    depthStencil := some {
      format            := depthFormat
      depthWriteEnabled := .false
      depthCompare      := .always
    }
  }
  return {
    device, pipeline
    queue     := ← device.getQueue
    font      := ← Font.ofBytes (base64Decode Fonts.JetBrainsMono_Regular)
    placement := ← createBuffer device "placement" .uniform
      (placementBytes 1 1 0 0 0)
    text      := ← IO.mkRef (none, "", 0)
  }

/-- A texture for text `width` by `height`, and its bind group. -/
def Overlay.createText (o : Overlay) (width height : UInt32) :
    IO OverlayText := do
  let texture ← o.device.createTexture {
    label  := "overlay text"
    usage  := .textureBinding ||| .copyDst
    size   := { width, height }
    format := .rgba8Unorm
  }
  let data ← o.device.createBindGroup {
    label   := "overlay"
    layout  := ← o.pipeline.getBindGroupLayout 0
    entries := #[
      { binding := 0, buffer := some o.placement },
      { binding := 1, textureView := some (← texture.createView none) }
    ]
  }
  return { texture, data, width, height }

/--
Show `text`, `size` pixels a line (about): drawn as pixels again, and the
texture made again, only if they change.
-/
def Overlay.show (o : Overlay) (text : String) (size : UInt32) : IO Unit := do
  let (current, shown, shownSize) ← o.text.get
  if text == shown && size == shownSize then return
  let image ← textImage o.font text size
  if image.width == 0 then
    o.text.set (none, text, size)
    return
  let current ← match current with
    | some t =>
      if t.width == image.width && t.height == image.height then pure t
      else o.createText image.width image.height
    | none => o.createText image.width image.height
  o.queue.writeTexture { texture := current.texture } image.pixels
    { bytesPerRow := 4 * image.width, rowsPerImage := image.height }
    { width := image.width, height := image.height }
  o.text.set (some current, text, size)

/--
Draw the text, if any, in `pass`, into a target `width` by `height`, in its
bottom right.
-/
def Overlay.draw (o : Overlay) (pass : RenderPassEncoder)
    (width height : UInt32) : IO Unit := do
  let (some t, _, size) ← o.text.get | return
  o.queue.writeBuffer o.placement 0
    (placementBytes width height t.width t.height (padding size))
  pass.setPipeline o.pipeline
  pass.setBindGroup 0 (some t.data) #[]
  pass.draw 6 1 0 0

end Reef
