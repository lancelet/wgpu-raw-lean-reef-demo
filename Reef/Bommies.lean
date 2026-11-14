import Reef.App
import Reef.Floor
import Reef.Tile

/-!
# The bommies

The reef's framework: bommies, mounds of old reef limestone rising out of
the sand, as a signed distance field over a box of the floor, baked once
at the start on the GPU (`shaders/reefbake.wgsl`): the field into a 3D
texture, then a mesh of its surface by surface nets, with each vertex's
ambient occlusion and sun shadow marched through the field. The mesh is
drawn with its vertices read from a buffer and its count from the bake
(`shaders/bommie.wgsl`); the field stays, for the sand to read the
bommies' occlusion and shadows from, and later for placing coral on the
rock and keeping things out of it.

Each bommie is a cluster of blobs, ellipsoids narrower at their bases,
placed here from a seed: their sizes and heights a lagoon's, a metre or
two across to a few, up to three metres high in four of water.
-/

open WebGPU.Raw

namespace Reef

/-- The box the reef's field covers: its corner, a cell's width, and the
grid's points along x, y and z (`shaders/frame.wgsl` reads them too). -/
def reefOrigin : Vec3 := ⟨-19.2, -3.0, -32⟩
def reefCell : Float := 0.15
def reefDims : Nat × Nat × Nat := (256, 48, 256)

/-- The most vertices and indices the mesh may have
(`shaders/reefbake.wgsl` has the same). -/
def reefMaxVertices : Nat := 1200000
def reefMaxIndices : Nat := 7200000

/-- A bommie: where its middle is on the floor (x, z), how wide, how
high. -/
structure Bommie where
  x      : Float
  z      : Float
  width  : Float
  height : Float

/-- The bommies near where the camera starts. -/
def bommies : Array Bommie := #[
  ⟨-5, -8, 1.6, 2.0⟩,
  ⟨6, -13, 2.4, 2.8⟩,
  ⟨-2, -21, 3.2, 3.1⟩,
  ⟨11, -24, 2.0, 2.3⟩,
  ⟨2.5, -3.5, 0.6, 0.5⟩,
  ⟨-11, -15, 1.3, 1.5⟩,
  ⟨-8, -27, 2.2, 2.6⟩
]

/-- A number in [0, 1), the `n`th from `seed`. -/
def unit (seed n : Nat) : Float :=
  let h := (seed * 2654435761 + n * 40503 + 12345) % 4294967296
  let h := (h ^^^ (h >>> 15)) * 2246822519 % 4294967296
  let h := (h ^^^ (h >>> 13)) * 3266489917 % 4294967296
  (h ^^^ (h >>> 16)).toFloat / 4294967296.0

/-- The bommies' blobs, as `shaders/reefbake.wgsl` reads them: two vec4s
a blob. A bommie's are a crown above a column, and a few heaped about
its foot; each an ellipsoid a little flattened, narrower at its base. -/
def blobBytes : ByteArray × Nat := Id.run do
  let mut out := ByteArray.empty
  let mut count := 0
  for h : b in [0:bommies.size] do
    let m := bommies[b]
    let n := 5 + (unit b 0 * 4).toUInt64.toNat
    for k in [0:n] do
      -- The first a column, narrow; the second its crown, wide and
      -- flattish, overhanging; the rest heaped about, some low at the
      -- foot, some tiers part way up.
      let s := b * 31 + k
      let angle := unit s 1 * 6.2832
      let reach := if k < 2 then 0.1 * m.width * unit s 2
        else m.width * (0.3 + 0.4 * unit s 2)
      let rise := if k == 0 then m.height * 0.3
        else if k == 1 then m.height * 0.72
        else m.height * (0.05 + 0.6 * unit s 3)
      let radius := m.width * (if k == 0 then 0.42 else if k == 1 then 0.6
        else 0.25 + 0.25 * unit s 4)
      let tall := if k == 0 then 1.3 else if k == 1 then 0.5 else 0.55 + 0.35 * unit s 5
      let undercut := if k == 1 then 0.45 else 0.15 + 0.2 * unit s 6
      out := [m.x + reach * angle.cos, rise, m.z + reach * angle.sin, radius,
              tall, undercut, unit s 7, 0].foldl pushF32 out
      count := count + 1
  return (out, count)

/-- The bake's uniforms, as `shaders/reefbake.wgsl` lays out `Bake`: 48
bytes. -/
def reefBakeBytes (sun : Vec3) (blobCount : Nat) : ByteArray :=
  let (nx, ny, nz) := reefDims
  let bytes := [reefOrigin.x, reefOrigin.y, reefOrigin.z, reefCell].foldl pushF32 ByteArray.empty
  let bytes := [nx, ny, nz, blobCount].foldl (fun b n => pushU32 b n.toUInt32) bytes
  [sun.x, sun.y, sun.z, 0].foldl pushF32 bytes

/-- The bommies, baked: the field (for the sand), and the mesh, with the
draw's arguments. -/
structure Bommies where
  field     : Texture
  fieldView : TextureView
  vertices  : Buffer
  indices   : Buffer
  args      : Buffer
  pipeline  : RenderPipeline
  data      : BindGroup

/-- A storage buffer of `size` bytes, zeroed, with more uses if said. -/
def storageBuffer (device : Device) (label : String) (size : Nat)
    (more : BufferUsage := .none) : IO Buffer := do
  let some b ← device.createBuffer {
      label, size := size.toUInt64, usage := .storage ||| .copyDst ||| more }
    | throw (IO.userError s!"no buffer for {label}")
  return b

/--
The bommies, baked for a sun from `sun` (where its light comes from,
under the water), drawn with `shared` code before `shaders/bommie.wgsl`
under the frame's `frameLayout`, into `format` with the depth buffer of
`depthFormat`.
-/
def Bommies.create (device : Device) (sun : Vec3) (shared : String)
    (frameLayout : BindGroupLayout) (format depthFormat : TextureFormat) :
    IO Bommies := do
  let queue ← device.getQueue
  let (nx, ny, nz) := reefDims
  let (blobData, blobCount) := blobBytes
  let uniform ← createBuffer device "reef bake" .uniform (reefBakeBytes sun blobCount)
  let blobs ← createBuffer device "reef blobs" .storage blobData
  let field ← device.createTexture {
    label := "reef field", dimension := .«3d»
    usage := .storageBinding ||| .textureBinding
    size := { width := nx.toUInt32, height := ny.toUInt32, depthOrArrayLayers := nz.toUInt32 }
    format := .r32Float
  }
  let fieldView ← field.createView none
  let vertices ← storageBuffer device "reef vertices" (reefMaxVertices * 32)
  let indices ← storageBuffer device "reef indices" (reefMaxIndices * 4) .index
  let cellIndex ← storageBuffer device "reef cells" ((nx - 1) * (ny - 1) * (nz - 1) * 4)
  let counts ← storageBuffer device "reef counts" 8
  let args ← storageBuffer device "reef draw" 20 .indirect
  let module ← createShader device "reef bake" Shaders.reefbake
  -- Each pass's layout, given (a texture read only by loads is no
  -- filterable float, which a layout inferred might say it is).
  let uniformEntry : BindGroupLayoutEntry :=
    { binding := 0, visibility := .compute, buffer := { type := .uniform } }
  let readEntry (n : UInt32) : BindGroupLayoutEntry :=
    { binding := n, visibility := .compute, buffer := { type := .readOnlyStorage } }
  let writeEntry (n : UInt32) : BindGroupLayoutEntry :=
    { binding := n, visibility := .compute, buffer := { type := .storage } }
  let fieldWrite : BindGroupLayoutEntry :=
    { binding := 2, visibility := .compute
      storageTexture := { access := .writeOnly, format := .r32Float, viewDimension := .«3d» } }
  let fieldRead : BindGroupLayoutEntry :=
    { binding := 3, visibility := .compute
      texture := { sampleType := .unfilterableFloat, viewDimension := .«3d» } }
  let pass (entry : String) (entries : Array BindGroupLayoutEntry)
      (bindings : Array BindGroupEntry) : IO (ComputePipeline × BindGroup) := do
    let layout ← device.createBindGroupLayout { label := entry, entries }
    let pipeline ← device.createComputePipeline {
      label := entry
      layout := some (← device.createPipelineLayout {
        label := entry, bindGroupLayouts := #[layout] })
      compute := { module, entryPoint := some entry } }
    let data ← device.createBindGroup { label := entry, layout, entries := bindings }
    return (pipeline, data)
  let fieldPass ← pass "field" #[uniformEntry, readEntry 1, fieldWrite]
    #[{ binding := 0, buffer := some uniform }, { binding := 1, buffer := some blobs },
      { binding := 2, textureView := some fieldView }]
  let vertexPass ← pass "vertexPass"
    #[uniformEntry, readEntry 1, fieldRead, writeEntry 4, writeEntry 5, writeEntry 6]
    #[{ binding := 0, buffer := some uniform }, { binding := 1, buffer := some blobs },
      { binding := 3, textureView := some fieldView },
      { binding := 4, buffer := some vertices }, { binding := 5, buffer := some cellIndex },
      { binding := 6, buffer := some counts }]
  let facePass ← pass "facePass"
    #[uniformEntry, fieldRead, writeEntry 5, writeEntry 6, writeEntry 7]
    #[{ binding := 0, buffer := some uniform }, { binding := 3, textureView := some fieldView },
      { binding := 5, buffer := some cellIndex }, { binding := 6, buffer := some counts },
      { binding := 7, buffer := some indices }]
  let countPass ← pass "countPass" #[writeEntry 6, writeEntry 8]
    #[{ binding := 6, buffer := some counts }, { binding := 8, buffer := some args }]
  let groups (n size : Nat) : UInt32 := ((n + size - 1) / size).toUInt32
  let encoder ← device.createCommandEncoder none
  let run (p : ComputePipeline × BindGroup) (x y z : UInt32) : IO Unit := do
    let c ← encoder.beginComputePass none
    c.setPipeline p.1
    c.setBindGroup 0 (some p.2) #[]
    c.dispatchWorkgroups x y z
    c.«end»
  run fieldPass (groups nx 4) (groups ny 4) (groups nz 4)
  run vertexPass (groups (nx - 1) 4) (groups (ny - 1) 4) (groups (nz - 1) 4)
  run facePass (groups nx 4) (groups ny 4) (groups nz 4)
  run countPass 1 1 1
  queue.submit #[← encoder.finish none]
  -- The draw: the frame's bind group, and the vertices'.
  let ownLayout ← device.createBindGroupLayout {
    label := "bommies"
    entries := #[{ binding := 0, visibility := .vertex, buffer := { type := .readOnlyStorage } }]
  }
  let data ← device.createBindGroup {
    label := "bommies", layout := ownLayout
    entries := #[{ binding := 0, buffer := some vertices }]
  }
  let drawModule ← createShader device "bommies" (shared ++ Shaders.bommie)
  let pipeline ← device.createRenderPipeline {
    label    := "bommies"
    layout   := some (← device.createPipelineLayout {
      label := "bommies", bindGroupLayouts := #[frameLayout, ownLayout] })
    vertex   := { module := drawModule, entryPoint := some "vs" }
    fragment := some {
      module := drawModule, entryPoint := some "fs", targets := #[{ format := format }] }
    primitive := { topology := .triangleList, cullMode := .back }
    depthStencil := some {
      format := depthFormat, depthWriteEnabled := .true, depthCompare := .less }
  }
  return { field, fieldView, vertices, indices, args, pipeline, data }

/-- Draw the bommies in `pass` (the frame's bind group set). -/
def Bommies.draw (b : Bommies) (pass : RenderPassEncoder) : IO Unit := do
  pass.setBindGroup 1 (some b.data) #[]
  pass.setPipeline b.pipeline
  pass.setIndexBuffer b.indices .uint32 0 (reefMaxIndices * 4).toUInt64
  pass.drawIndexedIndirect b.args 0

/-- How many texels the seabed's map has along each side of the
framework's box: a few centimetres each. -/
def seabedSize : Nat := 1024

/-- A 1×1 texture, to stand in a bind group for one a pass may not read
while it writes it. -/
def placeholderView (device : Device) : IO TextureView := do
  let t ← device.createTexture {
    label := "placeholder", usage := .textureBinding
    size := { width := 1, height := 1 }, format := .rgba16Float }
  t.createView none

/-- The seabed's map over the framework's box (`shaders/seabed.wgsl`), and
what bakes it. -/
structure Seabed where
  texture  : Texture
  view     : TextureView
  pipeline : ComputePipeline
  /-- The frame's bind group as the bake sees it (without the map), and
  the map's, writable. -/
  frameData : BindGroup
  data      : BindGroup

/-- The seabed's map, to be baked with the frame's `shared` code under
its `frameLayout`, `frameData` being the frame's bind group without the
map itself. -/
def Seabed.create (device : Device) (shared : String)
    (frameLayout : BindGroupLayout) (frameData : BindGroup) : IO Seabed := do
  let texture ← device.createTexture {
    label := "seabed", usage := .storageBinding ||| .textureBinding
    size := { width := seabedSize.toUInt32, height := seabedSize.toUInt32 }
    format := .rgba16Float }
  let view ← texture.createView none
  let layout ← device.createBindGroupLayout {
    label := "seabed"
    entries := #[{ binding := 0, visibility := .compute
                   storageTexture := { access := .writeOnly, format := .rgba16Float
                                       viewDimension := .«2d» } }] }
  let module ← createShader device "seabed" (shared ++ Shaders.seabed)
  let pipeline ← device.createComputePipeline {
    label := "seabed"
    layout := some (← device.createPipelineLayout {
      label := "seabed", bindGroupLayouts := #[frameLayout, layout] })
    compute := { module, entryPoint := some "bakeSeabed" } }
  let data ← device.createBindGroup {
    label := "seabed", layout, entries := #[{ binding := 0, textureView := some view }] }
  return { texture, view, pipeline, frameData, data }

/-- Bake the seabed's map, in `encoder`. -/
def Seabed.bake (s : Seabed) (encoder : CommandEncoder) : IO Unit := do
  let pass ← encoder.beginComputePass none
  pass.setPipeline s.pipeline
  pass.setBindGroup 0 (some s.frameData) #[]
  pass.setBindGroup 1 (some s.data) #[]
  let groups := ((seabedSize + 7) / 8).toUInt32
  pass.dispatchWorkgroups groups groups 1
  pass.«end»

end Reef
