import Reef.Gpu
import Reef.Shaders

/-!
# Tiles: textures baked at the start

The sand's finer layers are textures: one tile of each, baked once at the
start, repeating over the floor. A tile has every mip level, each the
mean of the one before (`shaders/mipmap.wgsl`, since WebGPU makes none),
so that a pixel far off, over many of the tile's features, gets their
average and not one of them. Each bake is a few passes, one triangle over
a texture each; what is here is what the bakes share: the format, the
pipelines, the mip levels, and the sampler the sand reads a tile with.
-/

open WebGPU.Raw

namespace Reef

/-- A tile, baked: with its mip levels, and the sampler it is read with. -/
structure Tile where
  texture : Texture
  view    : TextureView
  sampler : Sampler

/-- A tile's format: four bytes a texel, and what every device filters
and draws into. -/
def tileFormat : TextureFormat := .rgba8Unorm

/-- A pipeline drawing one triangle with `module`'s `vs` and `fragment`
into a target of `format` (a tile's), with no depth. -/
def tilePipeline (device : Device) (label : String) (module : ShaderModule)
    (fragment : String) (format : TextureFormat := tileFormat) :
    IO RenderPipeline :=
  device.createRenderPipeline {
    label    := label
    vertex   := { module := module, entryPoint := some "vs" }
    fragment := some {
      module     := module
      entryPoint := some fragment
      targets    := #[{ format := format }]
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

/-- A texture `texels` a side, of `tileFormat`, to bake a tile into: with
every mip level if `mips`, to be drawn into, read, and read back. -/
def createTile (device : Device) (label : String) (texels : Nat)
    (mips : Bool := true) (layers : Nat := 1) : IO Texture :=
  device.createTexture {
    label  := label
    usage  := .renderAttachment ||| .textureBinding ||| .copySrc
    size   := { width := texels.toUInt32, height := texels.toUInt32,
                depthOrArrayLayers := layers.toUInt32 }
    format := tileFormat
    mipLevelCount := if mips then (Nat.log2 texels + 1).toUInt32 else 1
  }

/-- `texture`'s view of its mip level `level` alone, of its layer `layer`,
as a plain 2D texture. -/
def levelView (texture : Texture) (level : Nat) (layer : Nat := 0) : IO TextureView :=
  texture.createView (some {
    dimension := .«2d», baseMipLevel := level.toUInt32, mipLevelCount := 1,
    baseArrayLayer := layer.toUInt32, arrayLayerCount := 1 })

/-- Encode, on `encoder`, `texture`'s mip levels after the first, each
from the one before; `texels` a side at the first. -/
def mipmaps (device : Device) (encoder : CommandEncoder) (texture : Texture)
    (texels : Nat) (layer : Nat := 0) : IO Unit := do
  let module ← createShader device "mipmap" Shaders.mipmap
  let pipeline ← tilePipeline device "mipmap" module "fs"
  let layout ← pipeline.getBindGroupLayout 0
  let between ← device.createSampler (some {
    label := "mipmap", magFilter := .linear, minFilter := .linear })
  for level in [1:Nat.log2 texels + 1] do
    let data ← device.createBindGroup {
      label   := "mipmap"
      layout  := layout
      entries := #[
        { binding := 0, textureView := some (← levelView texture (level - 1) layer) },
        { binding := 1, sampler := some between }]
    }
    drawInto encoder pipeline data (← levelView texture level layer)

/-- `texture`, baked, as a tile: with its view of every level (and every
layer, as an array, if `layered`), and the sampler it is read with,
repeating, filtered between texels and levels, and along a slanting
view. -/
def Tile.of (device : Device) (label : String) (texture : Texture)
    (layered : Bool := false) : IO Tile :=
  return {
    texture
    view    := ← texture.createView
      (if layered then some { dimension := .«2dArray» } else none)
    sampler := ← device.createSampler (some {
      label         := label
      addressModeU  := .repeat
      addressModeV  := .repeat
      magFilter     := .linear
      minFilter     := .linear
      mipmapFilter  := .linear
      maxAnisotropy := 16
    })
  }

end Reef
