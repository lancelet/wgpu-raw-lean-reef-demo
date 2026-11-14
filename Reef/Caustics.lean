import Reef.App
import Reef.Floor
import Reef.Tile

/-!
# The caustics

The sun's light through the surface's waves, as it lands on the floor:
drawn each frame into a texture over one tile of the surface
(`shaders/caustics.wgsl`), with its mip levels, which the sand reads
along the sun's slant (`shaders/sand.wgsl`). The pass has the frame's
uniforms alone, in a bind group of its own: the texture it draws into
cannot be bound to be read in the same pass. Then the texture is
blurred by the sun's own width (`shaders/blur.wgsl`), through a second
texture and back, and its mip levels made.
-/

open WebGPU.Raw

namespace Reef

/-- The caustics' texture format: floats, for light many times even. -/
def causticFormat : TextureFormat := .rgba16Float

/-- What drawing the caustics each frame needs, made once. -/
structure Caustics where
  texture  : Texture
  /-- The view of every level, for the sand to read. -/
  view     : TextureView
  /-- The first level, drawn into. -/
  target   : TextureView
  pipeline : RenderPipeline
  data     : BindGroup
  /-- The grid's triangles, indexed, and how many indices. -/
  indices  : Buffer
  count    : UInt32
  /-- The blur: across into the second texture, then down back into the
  first; each a pipeline and a bind group reading the other. -/
  blurX    : RenderPipeline × BindGroup
  blurY    : RenderPipeline × BindGroup
  pong     : TextureView
  /-- The mip levels' pipeline, and each level's bind group, reading the
  level before, and its view. -/
  mips     : RenderPipeline
  levels   : Array (BindGroup × TextureView)

/-- Light added to light: the triangles pile up. -/
def addBlend : BlendState := {
  color := { operation := .add, srcFactor := .one, dstFactor := .one }
  alpha := { operation := .add, srcFactor := .one, dstFactor := .one }
}

/--
The caustics for `water`, their pass drawing with `module` (the frame's
uniforms and `shaders/caustics.wgsl`) under `layout`, whose one bind
group is `frameLayout`'s with the frame's buffer `frame`.
-/
def Caustics.create (device : Device) (water : Water) (module : ShaderModule)
    (layout : PipelineLayout) (frameLayout : BindGroupLayout) (frame : Buffer) :
    IO Caustics := do
  let texels := water.texels
  let texture ← device.createTexture {
    label  := "caustics"
    usage  := .renderAttachment ||| .textureBinding
    size   := { width := texels.toUInt32, height := texels.toUInt32 }
    format := causticFormat
    mipLevelCount := (Nat.log2 texels + 1).toUInt32
  }
  let pipeline ← device.createRenderPipeline {
    label    := "caustics"
    layout   := some layout
    vertex   := { module := module, entryPoint := some "vs" }
    fragment := some {
      module     := module
      entryPoint := some "fs"
      targets    := #[{ format := causticFormat, blend := some addBlend }]
    }
    primitive := { topology := .triangleList, cullMode := .none }
  }
  let data ← device.createBindGroup {
    label   := "caustics"
    layout  := frameLayout
    entries := #[{ binding := 0, buffer := some frame }]
  }
  let lattice := latticeIndices water.grid
  let indices ← createBuffer device "caustic grid" .index
    (lattice.foldl pushU32 ByteArray.empty)
  -- The blur, through a second texture of the first level's size.
  let pong ← device.createTexture {
    label  := "caustics blur"
    usage  := .renderAttachment ||| .textureBinding
    size   := { width := texels.toUInt32, height := texels.toUInt32 }
    format := causticFormat
  }
  let pongView ← pong.createView none
  let level0 ← levelView texture 0
  let blurModule ← createShader device "blur" Shaders.blur
  let wrap ← device.createSampler (some {
    label := "blur", addressModeU := .repeat, addressModeV := .repeat,
    magFilter := .linear, minFilter := .linear })
  let blurPipeline (fragment : String) (source : TextureView) :
      IO (RenderPipeline × BindGroup) := do
    let pipeline ← tilePipeline device "caustic blur" blurModule fragment causticFormat
    let data ← device.createBindGroup {
      label   := "caustic blur"
      layout  := ← pipeline.getBindGroupLayout 0
      entries := #[{ binding := 0, textureView := some source },
                   { binding := 1, sampler := some wrap }]
    }
    return (pipeline, data)
  let mipModule ← createShader device "mipmap" Shaders.mipmap
  let mips ← tilePipeline device "caustic mipmap" mipModule "fs" causticFormat
  let mipLayout ← mips.getBindGroupLayout 0
  let between ← device.createSampler (some {
    label := "mipmap", magFilter := .linear, minFilter := .linear })
  let mut levels := #[]
  for level in [1:Nat.log2 texels + 1] do
    let data ← device.createBindGroup {
      label   := "caustic mipmap"
      layout  := mipLayout
      entries := #[
        { binding := 0, textureView := some (← levelView texture (level - 1)) },
        { binding := 1, sampler := some between }]
    }
    levels := levels.push (data, ← levelView texture level)
  return {
    texture, pipeline, data, mips, levels, indices
    view   := ← texture.createView none
    target := level0
    count  := lattice.size.toUInt32
    blurX  := ← blurPipeline "fs_x" level0
    blurY  := ← blurPipeline "fs_y" pongView
    pong   := pongView
  }

/-- Encode, on `encoder`, drawing the caustics for this frame (the frame's
uniforms already written), and their mip levels. -/
def Caustics.encode (c : Caustics) (encoder : CommandEncoder) : IO Unit := do
  let pass ← encoder.beginRenderPass {
    colorAttachments := #[{ view := some c.target, loadOp := .clear,
                            storeOp := .store }]
  }
  pass.setPipeline c.pipeline
  pass.setBindGroup 0 (some c.data) #[]
  pass.setIndexBuffer c.indices .uint32 0 (c.count.toUInt64 * 4)
  pass.drawIndexed c.count 3 0 0 0
  pass.«end»
  drawInto encoder c.blurX.1 c.blurX.2 c.pong
  drawInto encoder c.blurY.1 c.blurY.2 c.target
  for (data, target) in c.levels do
    drawInto encoder c.mips data target

end Reef
