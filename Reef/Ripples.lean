import Reef.App
import Reef.Tile

/-!
# The ripples' tile

The sand's ripples are a tile (`Reef/Tile.lean`), baked once at the
start (`shaders/ripples.wgsl`), which `shaders/sand.wgsl` lifts its mesh
by near the eye and takes its normal from everywhere. A texel holds the
height, the slopes and the cavity (how much of the sky a point sees).
Far off, the mip levels average the slopes to the floor's own and the
cavity to its mean.

Baked in three passes: the height, from the ripples' phasor noise; from
that, the slopes and the cavity; then the mip levels.
-/

open WebGPU.Raw

namespace Reef

/-- The bake's uniforms, as `shaders/ripples.wgsl` lays out `Bake`:
48 bytes. -/
def bakeBytes (r : Ripples) : ByteArray :=
  [r.perTile.toFloat, r.spread, r.disorder, r.sharpness,
   r.steepness, r.texels.toFloat, r.asymmetry, r.fine,
   r.pits, r.pitDepth, 0, 0].foldl pushF32 ByteArray.empty

/-- The tile of `r`, baked. -/
def Ripples.bake (device : Device) (r : Ripples) : IO Tile := do
  let texture ← createTile device "ripples" r.texels
  let heights ← createTile device "ripple heights" r.texels (mips := false)
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
  let encoder ← device.createCommandEncoder none
  drawInto encoder heightPipeline heightData heightsView
  drawInto encoder finishPipeline finishData (← levelView texture 0)
  mipmaps device encoder texture r.texels
  (← device.getQueue).submit #[← encoder.finish none]
  Tile.of device "ripples" texture

end Reef
