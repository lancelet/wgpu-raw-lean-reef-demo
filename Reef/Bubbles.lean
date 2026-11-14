import Reef.App
import Reef.Floor
import Reef.Tile

/-!
# The bubbles

The air the waves mix into the water, rising: some thousands of bubbles
about the camera, each stepped on the GPU every frame
(`shaders/bubbles.wgsl`, a thread a bubble) and drawn as a quad facing
the camera, blended over the scene. Born under the surface where the sea
is steep, risen to it, born again. The first particles.
-/

open WebGPU.Raw

namespace Reef

/-- What the bubbles need, made once. -/
structure Bubbles where
  /-- The bubbles themselves, a storage buffer the compute steps. -/
  buffer   : Buffer
  /-- The pool's uniforms, written each frame. -/
  pool     : Buffer
  /-- The bind group the compute steps the bubbles through (the buffer
  writable), and the one they are drawn from (read only: the vertex
  stage cannot write). -/
  stepData : BindGroup
  drawData : BindGroup
  stepper  : ComputePipeline
  pipeline : RenderPipeline
  count    : Nat

/-- The pool's uniforms, as `shaders/bubbles.wgsl` lays out `Pool`: 16
bytes. -/
def poolBytes (count : Nat) (dt reach time : Float) : ByteArray :=
  [count.toFloat, dt, reach, time].foldl pushF32 ByteArray.empty

/-- Alpha blending with the colour already multiplied by its alpha. -/
def premultipliedBlend : BlendState := {
  color := { operation := .add, srcFactor := .one, dstFactor := .oneMinusSrcAlpha }
  alpha := { operation := .add, srcFactor := .one, dstFactor := .oneMinusSrcAlpha }
}

/--
The bubbles for `water`, their shaders built on the frame's `shared`
code, under the frame's bind group layout `frameLayout` (group 0; the
bubbles' own is group 1), drawing into `format` with the depth buffer of
`depthFormat`, tested but not written.
-/
def Bubbles.create (device : Device) (water : Water) (shared : String)
    (frameLayout : BindGroupLayout) (format depthFormat : TextureFormat) :
    IO Bubbles := do
  let count := water.bubbles
  -- Every bubble born at the origin with age past its life: the first
  -- step bears them all.
  let mut initial := ByteArray.empty
  for _ in [0:count] do
    initial := [0, 0, 0, 0.001, 100, 1, 0, 0].foldl pushF32 initial
  let buffer ← createBuffer device "bubbles" .storage initial
  let pool ← createBuffer device "bubble pool" .uniform (poolBytes count 0 0 0)
  let ownLayout (writable : Bool) : IO BindGroupLayout :=
    device.createBindGroupLayout {
      label   := "bubbles"
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
      label   := "bubbles"
      layout  := layout
      entries := #[{ binding := 0, buffer := some buffer },
                   { binding := 1, buffer := some pool }]
    }
  let stepData ← group stepLayout
  let drawData ← group drawLayout
  -- The step's module has no draw (a vertex stage may not see a writable
  -- buffer, a browser says), the draw's no step.
  let source := Shaders.bubbles
  let stepSource := match source.splitOn "// DRAW\n" with
    | [before, _] => before
    | _ => source
  let module ← createShader device "bubbles step" (shared ++ stepSource)
  let stepper ← device.createComputePipeline {
    label := "bubbles step"
    layout := some (← device.createPipelineLayout {
      label := "bubbles step", bindGroupLayouts := #[frameLayout, stepLayout] })
    compute := { module := module, entryPoint := some "step" } }
  -- The draw's module reads the bubbles only: the step cut out, and the
  -- binding made read only.
  let cut := match source.splitOn "// STEP\n", source.splitOn "// END\n" with
    | [before, _], [_, after] => before ++ after
    | _, _ => source
  let drawSource := (shared ++ cut).replace
    "var<storage, read_write> bubbles" "var<storage, read> bubbles"
  let drawModule ← createShader device "bubbles" drawSource
  let pipeline ← device.createRenderPipeline {
    label    := "bubbles"
    layout   := some (← device.createPipelineLayout {
      label := "bubbles", bindGroupLayouts := #[frameLayout, drawLayout] })
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

/-- Step the bubbles by `dt` seconds at `time`, kept within `reach` of the
camera: the pool written (on `queue`, before the encoder's commands are
submitted), the compute encoded on `encoder`. -/
def Bubbles.step (b : Bubbles) (queue : Queue) (encoder : CommandEncoder)
    (frameData : BindGroup) (dt reach time : Float) : IO Unit := do
  queue.writeBuffer b.pool 0 (poolBytes b.count dt reach time)
  let pass ← encoder.beginComputePass none
  pass.setBindGroup 0 (some frameData) #[]
  pass.setBindGroup 1 (some b.stepData) #[]
  pass.setPipeline b.stepper
  pass.dispatchWorkgroups ((b.count + 63) / 64).toUInt32 1 1
  pass.«end»

/-- Draw the bubbles in `pass` (the frame's bind group set). -/
def Bubbles.draw (b : Bubbles) (pass : RenderPassEncoder) : IO Unit := do
  pass.setBindGroup 1 (some b.drawData) #[]
  pass.setPipeline b.pipeline
  pass.draw 4 b.count.toUInt32 0 0

end Reef
