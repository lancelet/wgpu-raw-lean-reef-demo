import Reef.App
import Reef.Tile

/-!
# The grains' tile

The sand's grains are a tile (`Reef/Tile.lean`), baked once at the start
(`shaders/grains.wgsl`), a few centimetres across, which
`shaders/sand.wgsl` tilts its normal by and speckles its colour with. A
texel holds the normal of the grains' surface and its brightness. Far
off, where a pixel covers many grains, the mip levels average the normal
to flat, and shorter (which is the roughness the grains leave, Toksvig's
measure, for the lighting to come), and the brightness to its mean.

Baked in two passes: the surface, then the mip levels.
-/

open WebGPU.Raw

namespace Reef

/-- The bake's uniforms, as `shaders/grains.wgsl` lays out `Bake`:
16 bytes. -/
def grainBytes (g : Grains) : ByteArray :=
  let texel := g.tile / g.texels.toFloat
  [g.texels.toFloat, g.grain / texel, g.fragment / texel, g.fragments].foldl
    pushF32 ByteArray.empty

/-- The tile of `g`, baked. -/
def Grains.bake (device : Device) (g : Grains) : IO Tile := do
  let texture ← createTile device "grains" g.texels
  let module ← createShader device "grains" Shaders.grains
  let pipeline ← tilePipeline device "grains" module "fs"
  let params ← createBuffer device "grain bake" .uniform (grainBytes g)
  let data ← device.createBindGroup {
    label   := "grains"
    layout  := ← pipeline.getBindGroupLayout 0
    entries := #[{ binding := 0, buffer := some params }]
  }
  let encoder ← device.createCommandEncoder none
  drawInto encoder pipeline data (← levelView texture 0)
  mipmaps device encoder texture g.texels
  (← device.getQueue).submit #[← encoder.finish none]
  Tile.of device "grains" texture

end Reef
