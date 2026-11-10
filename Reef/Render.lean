import Reef.Overlay
import Reef.Scene

/-!
# Drawing

Three passes' worth of drawing in one render pass: the ocean, one triangle
over the whole of the target, then the creatures over it, a quad each,
instanced from a storage buffer, their light added to the ocean's; then
the overlay's text, over all (`Reef/Overlay.lean`).
-/

open WebGPU.Raw

namespace Reef

/-- What drawing a frame needs, made once. -/
structure Renderer where
  device    : Device
  queue     : Queue
  ocean     : RenderPipeline
  glow      : RenderPipeline
  /-- The frame's uniforms, written each frame. -/
  frame     : Buffer
  /-- The ocean's bind group: the uniforms. -/
  oceanData : BindGroup
  /-- The creatures' bind group: the uniforms and the creatures. -/
  glowData  : BindGroup
  count     : UInt32
  /-- The text over it all. -/
  overlay   : Overlay

/-- Light added to what is there: the creatures' glow. -/
def additive : BlendState := {
  color := { operation := .add, srcFactor := .one, dstFactor := .one }
  alpha := { operation := .add, srcFactor := .zero, dstFactor := .one }
}

/-- A pipeline drawing with `module`'s `vs` and `fs` into `format`. -/
def pipeline (device : Device) (label : String) (module : ShaderModule)
    (format : TextureFormat) (blend : Option BlendState) :
    IO RenderPipeline :=
  device.createRenderPipeline {
    label    := label
    vertex   := { module := module, entryPoint := some "vs" }
    fragment := some {
      module     := module
      entryPoint := some "fs"
      targets    := #[{ format := format, blend := blend }]
    }
  }

/-- A renderer drawing `scene`'s creatures into targets of `format`. -/
def Renderer.create (device : Device) (format : TextureFormat)
    (scene : Array Creature) : IO Renderer := do
  let ocean ← pipeline device "ocean"
    (← createShader device "ocean" Shaders.ocean) format none
  let glow ← pipeline device "glow"
    (← createShader device "glow" Shaders.glow) format (some additive)
  let frame ← createBuffer device "frame" .uniform (frameBytes 0 1)
  let creatures ← createBuffer device "creatures" .storage
    (scene.foldl Creature.encode ByteArray.empty)
  -- Each pipeline's layout is the one its shaders imply, so each its own
  -- bind group.
  let oceanData ← device.createBindGroup {
    label   := "ocean"
    layout  := ← ocean.getBindGroupLayout 0
    entries := #[{ binding := 0, buffer := some frame }]
  }
  let glowData ← device.createBindGroup {
    label   := "glow"
    layout  := ← glow.getBindGroupLayout 0
    entries := #[
      { binding := 0, buffer := some frame },
      { binding := 1, buffer := some creatures }
    ]
  }
  return {
    device, ocean, glow, frame, oceanData, glowData
    queue := ← device.getQueue
    count := scene.size.toUInt32
    overlay := ← Overlay.create device format
  }

/-- Draw the frame at `time` seconds into `texture`, `width` by `height`. -/
def Renderer.draw (r : Renderer) (time : Float) (width height : UInt32)
    (texture : Texture) : IO Unit := do
  let aspect := width.toFloat / (max height 1).toFloat
  r.queue.writeBuffer r.frame 0 (frameBytes time aspect)
  let view ← texture.createView none
  let encoder ← r.device.createCommandEncoder none
  let pass ← encoder.beginRenderPass { colorAttachments := #[{
    view       := some view
    loadOp     := .clear
    storeOp    := .store
    clearValue := { r := 0, g := 0, b := 0, a := 1 }
  }] }
  pass.setPipeline r.ocean
  pass.setBindGroup 0 (some r.oceanData) #[]
  pass.draw 3 1 0 0
  pass.setPipeline r.glow
  pass.setBindGroup 0 (some r.glowData) #[]
  pass.draw 6 r.count 0 0
  r.overlay.draw pass width height
  pass.«end»
  r.queue.submit #[← encoder.finish none]

end Reef
