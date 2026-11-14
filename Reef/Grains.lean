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

/-- The bake's uniforms, as `shaders/grains.wgsl` lays out `Bake`: 32
bytes; for the layer with the traces (`traces`) or the one without. -/
def grainBytes (g : Grains) (traces : Bool) : ByteArray :=
  let texel := g.tile / g.texels.toFloat
  [g.texels.toFloat, g.grain / texel, g.fragment / texel, g.fragments,
   if traces then 1 else 0, 0, 0, 0].foldl pushF32 ByteArray.empty

/-- The tile of `g`, baked: two layers, the first with the traces of what
lives in the sand, the second without, for the sand to blend by where the
sand is still (`shaders/sand.wgsl`). -/
def Grains.bake (device : Device) (g : Grains) : IO Tile := do
  let texture ← createTile device "grains" g.texels (layers := 2)
  let module ← createShader device "grains" Shaders.grains
  let pipeline ← tilePipeline device "grains" module "fs"
  let layout ← pipeline.getBindGroupLayout 0
  let encoder ← device.createCommandEncoder none
  for layer in [0:2] do
    let params ← createBuffer device "grain bake" .uniform (grainBytes g (layer == 0))
    let data ← device.createBindGroup {
      label   := "grains"
      layout  := layout
      entries := #[{ binding := 0, buffer := some params }]
    }
    drawInto encoder pipeline data (← levelView texture 0 layer)
    mipmaps device encoder texture g.texels layer
  (← device.getQueue).submit #[← encoder.finish none]
  Tile.of device "grains" texture (layered := true)

end Reef
