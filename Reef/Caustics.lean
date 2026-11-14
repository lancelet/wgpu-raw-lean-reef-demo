import Reef.App
import Reef.Floor
import Reef.Tile

/-!
# The caustics

The sun's light through the sea's surface, as it lands on the floor,
baked once at the start as a loop: for each of some dozens of moments
round a few seconds, the surface for that moment, one tile of it
(`shaders/ocean.wgsl`, a spectrum of waves summed by a fast Fourier
transform in compute, periodic in time as in space), is drawn down the
sun's rays into one layer of a texture array (`shaders/caustics.wgsl`),
blurred by the sun's own width (`shaders/blur.wgsl`), and given its mip
levels. The sand reads the layer for the moment, and the next, blended
(`shaders/sand.wgsl`): one fetch or two a pixel, whatever the surface
cost to make.
-/

open WebGPU.Raw

namespace Reef

/-- The caustics' texture format: the light over its brightest, 0 to 1. -/
def causticFormat : TextureFormat := .rgba8Unorm

/-- The caustics, baked: the texture array, and its view of every layer
and level, for the sand; and the sea, its surface at a moment, the
height and the slopes at each point of its grid (`field`), with what
evolves it to another moment each frame (`evolve`), for the surface
drawn from below. -/
structure Caustics where
  texture  : Texture
  view     : TextureView
  field    : Buffer
  points   : Nat
  /-- A uniform buffer and bind group for each of the sea's three fields. -/
  seas     : Array (Buffer × BindGroup)
  spectrum : ComputePipeline
  rows     : ComputePipeline
  columns  : ComputePipeline
  water    : Water

/-- The sea's uniforms, as `shaders/ocean.wgsl` lays out `Sea`: 48
bytes, for the moment `time` and the field `component`. -/
def seaBytes (w : Water) (time : Float) (component : Nat) : ByteArray :=
  let bytes := [w.tile, time, w.loop].foldl pushF32 ByteArray.empty
  let bytes := pushU32 bytes component.toUInt32
  [w.wind, w.windDirection.cos, w.windDirection.sin, w.chopAmplitude, w.shortest,
   0, 0, 0].foldl pushF32 bytes

/-- The bake's uniforms, as `shaders/caustics.wgsl` lays out `Bake`: 32
bytes. -/
def causticBakeBytes (w : Water) : ByteArray :=
  let bytes := [w.tile, w.depth].foldl pushF32 ByteArray.empty
  [w.margin, w.dispersion, 0, 0, 0].foldl pushF32 (pushU32 bytes w.grid.toUInt32)

/-- Light added to light: the triangles pile up. -/
def addBlend : BlendState := {
  color := { operation := .add, srcFactor := .one, dstFactor := .one }
  alpha := { operation := .add, srcFactor := .one, dstFactor := .one }
}

/-- Encode, on `encoder`, the sea's surface at `time` into `field`: the
three fields' spectra and transforms, their uniforms written first (on
`queue`, before the encoder's commands are submitted). -/
def Caustics.evolve (c : Caustics) (queue : Queue) (encoder : CommandEncoder)
    (time : Float) : IO Unit := do
  let n := c.points
  for component in [0:3] do
    if let some (uniform, _) := c.seas[component]? then
      queue.writeBuffer uniform 0 (seaBytes c.water time component)
  for (_, data) in c.seas do
    let pass ← encoder.beginComputePass none
    pass.setBindGroup 0 (some data) #[]
    pass.setPipeline c.spectrum
    pass.dispatchWorkgroups (n / 16).toUInt32 (n / 16).toUInt32 1
    pass.setPipeline c.rows
    pass.dispatchWorkgroups n.toUInt32 1 1
    pass.setPipeline c.columns
    pass.dispatchWorkgroups n.toUInt32 1 1
    pass.«end»

/-- `texture`'s view of layer `layer`'s level `level` alone, as a plain
2D texture. -/
def layerView (texture : Texture) (layer level : Nat) : IO TextureView :=
  texture.createView (some {
    dimension := .«2d», baseArrayLayer := layer.toUInt32, arrayLayerCount := 1,
    baseMipLevel := level.toUInt32, mipLevelCount := 1 })

/-- The caustics for `water`, baked. -/
def Caustics.bake (device : Device) (water : Water) : IO Caustics := do
  let queue ← device.getQueue
  let n := 256
  let texels := water.texels
  let frames := water.frames
  -- The sea: its buffers, and a uniform buffer for each field, the moment
  -- written to each before every frame.
  let complexes := (n * n * 8).toUInt64
  let some spec ← device.createBuffer
      { label := "sea spectrum", size := complexes, usage := .storage }
    | throw (IO.userError "no buffer for the sea")
  let some tmp ← device.createBuffer
      { label := "sea transform", size := complexes, usage := .storage }
    | throw (IO.userError "no buffer for the sea")
  let some field ← device.createBuffer
      { label := "sea surface", size := (n * n * 16).toUInt64,
        usage := .storage ||| .copySrc }
    | throw (IO.userError "no buffer for the sea")
  let oceanModule ← createShader device "ocean" Shaders.ocean
  -- One layout for the three kernels, which use the buffers between them
  -- (a kernel's own layout would have only those it uses).
  let seaLayout ← device.createBindGroupLayout {
    label   := "sea"
    entries := #[
      { binding := 0, visibility := .compute, buffer := { type := .uniform } },
      { binding := 1, visibility := .compute, buffer := { type := .storage } },
      { binding := 2, visibility := .compute, buffer := { type := .storage } },
      { binding := 3, visibility := .compute, buffer := { type := .storage } }]
  }
  let seaPipelineLayout ← device.createPipelineLayout {
    label := "sea", bindGroupLayouts := #[seaLayout] }
  let kernel (entry : String) : IO ComputePipeline :=
    device.createComputePipeline {
      label := entry, layout := some seaPipelineLayout
      compute := { module := oceanModule, entryPoint := some entry } }
  let spectrum ← kernel "spectrum"
  let rows ← kernel "rows"
  let columns ← kernel "columns"
  let mut seas := #[]
  for component in [0:3] do
    let uniform ← createBuffer device "sea" .uniform (seaBytes water 0 component)
    let data ← device.createBindGroup {
      label   := "sea"
      layout  := seaLayout
      entries := #[{ binding := 0, buffer := some uniform },
                   { binding := 1, buffer := some spec },
                   { binding := 2, buffer := some tmp },
                   { binding := 3, buffer := some field }]
    }
    seas := seas.push (uniform, data)
  -- The texture array, a layer a moment, and its sampler.
  let texture ← device.createTexture {
    label  := "caustics"
    usage  := .renderAttachment ||| .textureBinding ||| .copySrc
    size   := { width := texels.toUInt32, height := texels.toUInt32,
                depthOrArrayLayers := frames.toUInt32 }
    format := causticFormat
    mipLevelCount := (Nat.log2 texels + 1).toUInt32
  }
  -- The splat: the surface's grid drawn down the rays into a layer.
  let splatModule ← createShader device "caustics" Shaders.caustics
  let splat ← device.createRenderPipeline {
    label    := "caustics"
    vertex   := { module := splatModule, entryPoint := some "vs" }
    fragment := some {
      module     := splatModule
      entryPoint := some "fs"
      targets    := #[{ format := causticFormat, blend := some addBlend }]
    }
    primitive := { topology := .triangleList, cullMode := .none }
  }
  let bakeUniform ← createBuffer device "bake" .uniform (causticBakeBytes water)
  let splatData ← device.createBindGroup {
    label   := "caustics"
    layout  := ← splat.getBindGroupLayout 0
    entries := #[{ binding := 0, buffer := some bakeUniform },
                 { binding := 1, buffer := some field }]
  }
  let lattice := latticeIndices water.grid
  let indices ← createBuffer device "caustic grid" .index
    (lattice.foldl pushU32 ByteArray.empty)
  -- The blur, through a second texture of a layer's size, and back.
  let pong ← device.createTexture {
    label  := "caustics blur"
    usage  := .renderAttachment ||| .textureBinding
    size   := { width := texels.toUInt32, height := texels.toUInt32 }
    format := causticFormat
  }
  let pongView ← pong.createView none
  let blurModule ← createShader device "blur" Shaders.blur
  let wrap ← device.createSampler (some {
    label := "blur", addressModeU := .repeat, addressModeV := .repeat,
    magFilter := .linear, minFilter := .linear })
  let blurX ← tilePipeline device "caustic blur" blurModule "fs_x" causticFormat
  let blurY ← tilePipeline device "caustic blur" blurModule "fs_y" causticFormat
  let blurYData ← device.createBindGroup {
    label   := "caustic blur"
    layout  := ← blurY.getBindGroupLayout 0
    entries := #[{ binding := 0, textureView := some pongView },
                 { binding := 1, sampler := some wrap }]
  }
  let blurXLayout ← blurX.getBindGroupLayout 0
  -- The mip levels, each from the one before, a layer at a time.
  let mipModule ← createShader device "mipmap" Shaders.mipmap
  let mips ← tilePipeline device "caustic mipmap" mipModule "fs" causticFormat
  let mipLayout ← mips.getBindGroupLayout 0
  let between ← device.createSampler (some {
    label := "mipmap", magFilter := .linear, minFilter := .linear })
  let c : Caustics := {
    texture, field, points := n, seas, spectrum, rows, columns, water
    view := ← texture.createView (some { dimension := .«2dArray» }) }
  for frame in [0:frames] do
    let time := frame.toFloat / frames.toFloat * water.loop
    let encoder ← device.createCommandEncoder none
    c.evolve queue encoder time
    -- Drawn down the rays into this moment's layer.
    let level0 ← layerView texture frame 0
    let pass ← encoder.beginRenderPass {
      colorAttachments := #[{ view := some level0, loadOp := .clear,
                              storeOp := .store }]
    }
    pass.setPipeline splat
    pass.setBindGroup 0 (some splatData) #[]
    pass.setIndexBuffer indices .uint32 0 (lattice.size.toUInt64 * 4)
    pass.drawIndexed lattice.size.toUInt32 3 0 0 0
    pass.«end»
    -- Blurred, across and back.
    let blurXData ← device.createBindGroup {
      label   := "caustic blur"
      layout  := blurXLayout
      entries := #[{ binding := 0, textureView := some level0 },
                   { binding := 1, sampler := some wrap }]
    }
    drawInto encoder blurX blurXData pongView
    drawInto encoder blurY blurYData level0
    -- Its mip levels.
    for level in [1:Nat.log2 texels + 1] do
      let data ← device.createBindGroup {
        label   := "caustic mipmap"
        layout  := mipLayout
        entries := #[
          { binding := 0, textureView := some (← layerView texture frame (level - 1)) },
          { binding := 1, sampler := some between }]
      }
      drawInto encoder mips data (← layerView texture frame level)
    queue.submit #[← encoder.finish none]
  return c

end Reef
