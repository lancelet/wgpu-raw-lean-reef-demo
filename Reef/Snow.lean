import Reef.App
import Reef.Floor
import Reef.Tile

/-!
# The marine snow

The fine matter every sea holds, drifting: some tens of thousands of
flecks about the camera, each stepped on the GPU every frame
(`shaders/snow.wgsl`, a thread a fleck), swayed by the surge, kept in a
box about the camera; drawn as quads facing the camera, each lit at its
own place by the sky and by the sun through the caustics' loop, blended
over the scene.
-/

open WebGPU.Raw

namespace Reef

/-- What the snow needs, made once. -/
structure Snow where
  /-- The flecks, a storage buffer the compute steps. -/
  buffer   : Buffer
  /-- The pool's uniforms, written each frame. -/
  pool     : Buffer
  /-- The bind group the compute steps the flecks through (the buffer
  writable), and the one they are drawn from (read only: the vertex
  stage cannot write). -/
  stepData : BindGroup
  drawData : BindGroup
  stepper  : ComputePipeline
  pipeline : RenderPipeline
  count    : Nat

/-- The pool's uniforms, as `shaders/snow.wgsl` lays out `Pool`: 16 bytes. -/
def snowPoolBytes (count : Nat) (dt reach time : Float) : ByteArray :=
  [count.toFloat, dt, reach, time].foldl pushF32 ByteArray.empty

/-- Alpha blending with the colour already multiplied by its alpha. -/
def premultipliedBlend : BlendState := {
  color := { operation := .add, srcFactor := .one, dstFactor := .oneMinusSrcAlpha }
  alpha := { operation := .add, srcFactor := .one, dstFactor := .oneMinusSrcAlpha }
}

/-- `source` with the part between the lines `// start` and `// stop`
(and the markers) cut out. -/
def cutBetween (source start stop : String) : String :=
  -- (The markers' lines matched without their ends: a checkout on
  -- Windows may end them with a carriage return too.)
  match source.splitOn s!"// {start}" with
  | [before, rest] =>
    match rest.splitOn s!"// {stop}" with
    | [_, after] => before ++ after
    | _ => before
  | _ => source

/--
The snow for `water`, its shaders built on the frame's `shared` code,
under the frame's bind group layout `frameLayout` (group 0; the snow's own
is group 1), drawing into `format` with the depth buffer of
`depthFormat`, tested but not written.
-/
def Snow.create (device : Device) (water : Water) (shared : String)
    (frameLayout : BindGroupLayout) (format depthFormat : TextureFormat) :
    IO Snow := do
  let count := water.snow
  -- Every fleck unplaced (its radius 0): the first step places them all.
  let buffer ← createBuffer device "snow" .storage
    (ByteArray.mk (Array.replicate (max count 1 * 32) 0))
  let pool ← createBuffer device "snow pool" .uniform (snowPoolBytes count 0 0 0)
  let ownLayout (writable : Bool) : IO BindGroupLayout :=
    device.createBindGroupLayout {
      label   := "snow"
      entries := #[
        { binding := 0
          visibility := if writable then .compute else .vertex
          buffer := { type := if writable then .storage else .readOnlyStorage } },
        { binding := 1, visibility := .compute ||| .vertex ||| .fragment,
          buffer := { type := .uniform } }]
    }
  let stepLayout ← ownLayout true
  let drawLayout ← ownLayout false
  let group (layout : BindGroupLayout) : IO BindGroup :=
    device.createBindGroup {
      label   := "snow"
      layout  := layout
      entries := #[{ binding := 0, buffer := some buffer },
                   { binding := 1, buffer := some pool }]
    }
  let stepData ← group stepLayout
  let drawData ← group drawLayout
  -- The step's module without the draw; the draw's without the step, the
  -- flecks read only.
  let source := Shaders.snow
  let stepSource := cutBetween source "DRAW" "NOTHING"
  let drawSource := (cutBetween source "STEP" "END").replace
    "var<storage, read_write> motes" "var<storage, read> motes"
  let stepModule ← createShader device "snow step" (shared ++ stepSource)
  let drawModule ← createShader device "snow" (shared ++ drawSource)
  let stepper ← device.createComputePipeline {
    label := "snow step"
    layout := some (← device.createPipelineLayout {
      label := "snow step", bindGroupLayouts := #[frameLayout, stepLayout] })
    compute := { module := stepModule, entryPoint := some "step" } }
  let pipeline ← device.createRenderPipeline {
    label    := "snow"
    layout   := some (← device.createPipelineLayout {
      label := "snow", bindGroupLayouts := #[frameLayout, drawLayout] })
    vertex   := { module := drawModule, entryPoint := some "vs" }
    fragment := some {
      module     := drawModule
      entryPoint := some "fs"
      targets    := #[{ format := format, blend := some premultipliedBlend }]
    }
    primitive := { topology := .triangleStrip, cullMode := .none }
    depthStencil := some {
      format            := depthFormat
      depthWriteEnabled := .false
      depthCompare      := .less
    }
  }
  return { buffer, pool, stepData, drawData, stepper, pipeline, count }

/-- Step the flecks by `dt` seconds at `time`, kept within `reach` of the
camera: the pool written (on `queue`, before the encoder's commands are
submitted), the compute encoded on `encoder`. -/
def Snow.step (s : Snow) (queue : Queue) (encoder : CommandEncoder)
    (frameData : BindGroup) (dt reach time : Float) : IO Unit := do
  if s.count == 0 then return
  queue.writeBuffer s.pool 0 (snowPoolBytes s.count dt reach time)
  let pass ← encoder.beginComputePass none
  pass.setBindGroup 0 (some frameData) #[]
  pass.setBindGroup 1 (some s.stepData) #[]
  pass.setPipeline s.stepper
  pass.dispatchWorkgroups ((s.count + 63) / 64).toUInt32 1 1
  pass.«end»

/-- Draw the flecks in `pass` (the frame's bind group set). -/
def Snow.draw (s : Snow) (pass : RenderPassEncoder) : IO Unit := do
  if s.count == 0 then return
  pass.setBindGroup 1 (some s.drawData) #[]
  pass.setPipeline s.pipeline
  pass.draw 4 s.count.toUInt32 0 0

end Reef
