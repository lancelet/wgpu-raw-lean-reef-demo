import Reef.App
import Reef.Gpu
import Reef.Shaders

/-!
# The ripples' tile

The sand's ripples are a texture: one tile of them, baked once at the
start (`shaders/ripples.wgsl`), repeating over the floor, which
`shaders/sand.wgsl` lifts its mesh by near the eye and takes its normal
from everywhere. A texel holds the height, the slopes and the cavity
(how much of the sky a point sees). The tile has every mip level, each
the mean of the one before (`shaders/mipmap.wgsl`), so that a pixel far
off, over many ripples, gets their average and not one of them: the
slopes average to the floor's own, the cavity to its mean.

Baked in three passes, each one triangle over a texture: the height, from
the ripples' phasor noise; from that, the slopes and the cavity; then
each mip level from the one before.
-/

open WebGPU.Raw

namespace Reef

/-- The tile, baked: with its mip levels, and the sampler the sand reads
it with. -/
structure RippleTile where
  texture : Texture
  view    : TextureView
  sampler : Sampler

/-- The tile's format: four bytes a texel, enough for a height, two
slopes and a cavity, and what every device filters and draws into. -/
def tileFormat : TextureFormat := .rgba8Unorm

/-- The bake's uniforms, as `shaders/ripples.wgsl` lays out `Bake`:
48 bytes. -/
def bakeBytes (r : Ripples) : ByteArray :=
  [r.perTile.toFloat, r.spread, r.disorder, r.sharpness,
   r.steepness, r.texels.toFloat, r.asymmetry, r.fine,
   r.pits, r.pitDepth, 0, 0].foldl pushF32 ByteArray.empty

/-- A pipeline drawing one triangle with `module`'s `vs` and `fragment`
into a `tileFormat` target, with no depth. -/
def tilePipeline (device : Device) (label : String) (module : ShaderModule)
    (fragment : String) : IO RenderPipeline :=
  device.createRenderPipeline {
    label    := label
    vertex   := { module := module, entryPoint := some "vs" }
    fragment := some {
      module     := module
      entryPoint := some fragment
      targets    := #[{ format := tileFormat }]
    }
  }

/-- Draw one triangle with `pipeline` and `data` into `target`. -/
def drawInto (encoder : CommandEncoder) (pipeline : RenderPipeline)
    (data : BindGroup) (target : TextureView) : IO Unit := do
  let pass ← encoder.beginRenderPass {
    colorAttachments := #[{ view := some target, loadOp := .clear,
                            storeOp := .store }]
  }
  pass.setPipeline pipeline
  pass.setBindGroup 0 (some data) #[]
  pass.draw 3 1 0 0
  pass.«end»

/-- The tile of `r`, baked. -/
def Ripples.bake (device : Device) (r : Ripples) : IO RippleTile := do
  let queue ← device.getQueue
  let size : Extent3D := { width := r.texels.toUInt32, height := r.texels.toUInt32 }
  let levels := (Nat.log2 r.texels + 1).toUInt32
  let texture ← device.createTexture {
    label  := "ripples"
    usage  := .renderAttachment ||| .textureBinding ||| .copySrc
    size, format := tileFormat, mipLevelCount := levels
  }
  let heights ← device.createTexture {
    label  := "ripple heights"
    usage  := .renderAttachment ||| .textureBinding
    size, format := tileFormat
  }
  let module ← createShader device "ripples" Shaders.ripples
  let heightPipeline ← tilePipeline device "ripple heights" module "fs_height"
  let finishPipeline ← tilePipeline device "ripples" module "fs_finish"
  let params ← createBuffer device "bake" .uniform (bakeBytes r)
  let heightsView ← heights.createView none
  let heightData ← device.createBindGroup {
    label   := "ripple heights"
    layout  := ← heightPipeline.getBindGroupLayout 0
    entries := #[{ binding := 0, buffer := some params }]
  }
  let finishData ← device.createBindGroup {
    label   := "ripples"
    layout  := ← finishPipeline.getBindGroupLayout 0
    entries := #[{ binding := 0, buffer := some params },
                 { binding := 1, textureView := some heightsView }]
  }
  -- The mip levels, each from the one before.
  let mipModule ← createShader device "mipmap" Shaders.mipmap
  let mipPipeline ← tilePipeline device "mipmap" mipModule "fs"
  let mipLayout ← mipPipeline.getBindGroupLayout 0
  let between ← device.createSampler (some {
    label := "mipmap", magFilter := .linear, minFilter := .linear })
  let levelView (level : UInt32) : IO TextureView :=
    texture.createView (some { baseMipLevel := level, mipLevelCount := 1 })
  let encoder ← device.createCommandEncoder none
  drawInto encoder heightPipeline heightData heightsView
  drawInto encoder finishPipeline finishData (← levelView 0)
  for level in [1:levels.toNat] do
    let data ← device.createBindGroup {
      label   := "mipmap"
      layout  := mipLayout
      entries := #[
        { binding := 0, textureView := some (← levelView (level - 1).toUInt32) },
        { binding := 1, sampler := some between }]
    }
    drawInto encoder mipPipeline data (← levelView level.toUInt32)
  queue.submit #[← encoder.finish none]
  return {
    texture
    view    := ← texture.createView none
    sampler := ← device.createSampler (some {
      label         := "ripples"
      addressModeU  := .repeat
      addressModeV  := .repeat
      magFilter     := .linear
      minFilter     := .linear
      mipmapFilter  := .linear
      maxAnisotropy := 16
    })
  }

end Reef
