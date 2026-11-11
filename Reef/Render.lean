import Reef.App
import Reef.Overlay

/-!
# Drawing

One render pass: the floor's grid (`shaders/grid.wgsl`), from the camera,
then the overlay's text over it (`Reef/Overlay.lean`). The background is
the colour the grid fades into.
-/

open WebGPU.Raw

namespace Reef

/-- What drawing a frame needs, made once. -/
structure Renderer where
  device   : Device
  queue    : Queue
  grid     : RenderPipeline
  /-- The frame's uniforms, written each frame. -/
  frame    : Buffer
  /-- The grid's bind group: the uniforms. -/
  gridData : BindGroup
  /-- The text over it all. -/
  overlay  : Overlay

/-- The camera's field of view, up and down, in radians: 60 degrees. -/
def fovY : Float := 1.0472

/-- The nearest and farthest the camera sees, in metres. -/
def near : Float := 0.05
def far : Float := 2000

/--
The frame's uniforms, as WGSL lays out its `Frame`: the view and projection
as one matrix, where the camera is, and the grid: 96 bytes.
-/
def frameBytes (viewProj : Mat4) (camera : Vec3) (grid : Grid) : ByteArray :=
  (viewProj.m.toList ++ [camera.x, camera.y, camera.z, 0]
    ++ [grid.spacing, grid.major, grid.extent, grid.fade]).foldl
    pushF32 ByteArray.empty

/-- A pipeline drawing with `module`'s `vs` and `fs` into `format`. -/
def pipeline (device : Device) (label : String) (module : ShaderModule)
    (format : TextureFormat) : IO RenderPipeline :=
  device.createRenderPipeline {
    label    := label
    vertex   := { module := module, entryPoint := some "vs" }
    fragment := some {
      module     := module
      entryPoint := some "fs"
      targets    := #[{ format := format }]
    }
  }

/-- A renderer drawing into targets of `format`. -/
def Renderer.create (device : Device) (format : TextureFormat) :
    IO Renderer := do
  let grid ← pipeline device "grid"
    (← createShader device "grid" Shaders.grid) format
  let frame ← createBuffer device "frame" .uniform
    (frameBytes Mat4.identity Vec3.zero {})
  let gridData ← device.createBindGroup {
    label   := "grid"
    layout  := ← grid.getBindGroupLayout 0
    entries := #[{ binding := 0, buffer := some frame }]
  }
  return {
    device, grid, frame, gridData
    queue   := ← device.getQueue
    overlay := ← Overlay.create device format
  }

/-- Draw `app`'s scene into `texture`, `app.width` by `app.height`. -/
def Renderer.draw (r : Renderer) (app : App) (texture : Texture) :
    IO Unit := do
  let aspect := app.width.toFloat / (max app.height 1).toFloat
  let viewProj := Mat4.perspective fovY aspect near far * app.camera.view
  r.queue.writeBuffer r.frame 0
    (frameBytes viewProj app.camera.position app.grid)
  let view ← texture.createView none
  let encoder ← r.device.createCommandEncoder none
  let pass ← encoder.beginRenderPass { colorAttachments := #[{
    view       := some view
    loadOp     := .clear
    storeOp    := .store
    clearValue := { r := 0.02, g := 0.05, b := 0.09, a := 1 }
  }] }
  pass.setPipeline r.grid
  pass.setBindGroup 0 (some r.gridData) #[]
  pass.draw 6 1 0 0
  r.overlay.draw pass app.width app.height
  pass.«end»
  r.queue.submit #[← encoder.finish none]

end Reef
