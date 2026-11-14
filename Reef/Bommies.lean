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
def reefCell : Float := 0.1
def reefDims : Nat × Nat × Nat := (384, 72, 384)

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

/-- The bake's uniforms, as `shaders/reefbake.wgsl` lays out `Bake`: 64
bytes. For a grid at `origin` of cells `cell` wide, `dims` points along
each axis; the fine level's octaves if `fine`; the field pass's slab of
`zCount` points along z from `zStart`; and the mesh's buffers' sizes. -/
def reefBakeBytes (origin : Vec3) (cell : Float) (dims : Nat × Nat × Nat)
    (blobCount : Nat) (sun : Vec3) (fine : Bool) (zStart zCount maxVertices maxIndices : Nat) :
    ByteArray :=
  let (nx, ny, nz) := dims
  let bytes := [origin.x, origin.y, origin.z, cell].foldl pushF32 ByteArray.empty
  let bytes := [nx, ny, nz, blobCount].foldl (fun b n => pushU32 b n.toUInt32) bytes
  let bytes := [sun.x, sun.y, sun.z, if fine then 1 else 0].foldl pushF32 bytes
  [zStart, zCount, maxVertices, maxIndices].foldl (fun b n => pushU32 b n.toUInt32) bytes

/-- The rock's detail tile (`shaders/rockdetail.wgsl`): its width, in
metres, and its texels a side (a quarter of a millimetre each). -/
def rockTileWidth : Float := 0.25
def rockTileTexels : Nat := 1024

/-- The rock's detail tile, baked: two layers, the surface (its slope,
cavity and height) and its colour, with their mip levels. -/
def bakeRockDetail (device : Device) : IO Tile := do
  let texture ← createTile device "rock detail" rockTileTexels (layers := 2)
  let module ← createShader device "rock detail" Shaders.rockdetail
  let pipeline ← tilePipeline device "rock detail" module "fs"
  let layout ← pipeline.getBindGroupLayout 0
  let encoder ← device.createCommandEncoder none
  for layer in [0:2] do
    let params ← createBuffer device "rock detail bake" .uniform
      ([rockTileTexels.toFloat, rockTileWidth, layer.toFloat, 0].foldl pushF32 ByteArray.empty)
    let data ← device.createBindGroup {
      label := "rock detail", layout, entries := #[{ binding := 0, buffer := some params }] }
    drawInto encoder pipeline data (← levelView texture 0 layer)
    mipmaps device encoder texture rockTileTexels layer
  (← device.getQueue).submit #[← encoder.finish none]
  Tile.of device "rock detail" texture (layered := true)

/-- A storage buffer of `size` bytes, zeroed, with more uses if said. -/
def storageBuffer (device : Device) (label : String) (size : Nat)
    (more : BufferUsage := .none) : IO Buffer := do
  let some b ← device.createBuffer {
      label, size := size.toUInt64, usage := .storage ||| .copyDst ||| more }
    | throw (IO.userError s!"no buffer for {label}")
  return b

/-- A finer level of the mesh about the camera: its cells' width, in
metres, and its grid's points along each axis; how far the camera may
move from its middle before it is baked again about it; from what
distance from the eye its vertices slide onto its parent's surface, and
where they are the parent's (its reach); and its buffers' sizes. Its box
must hold its reach however far the camera has moved, and the parent's
reach must hold its box. -/
structure FineSpec where
  cell        : Float
  dims        : Nat
  move        : Float
  slideStart  : Float
  slideEnd    : Float
  maxVertices : Nat
  maxIndices  : Nat

/-- The finer levels, coarsest first: four centimetres to two and a half
metres from the eye, two to most of a metre. Below, the shading carries
the rock's bands (shaders/rock.wgsl). -/
def fineSpecs : Array FineSpec := #[
  { cell := 0.04, dims := 160, move := 0.5, slideStart := 1.6, slideEnd := 2.4,
    maxVertices := 600000, maxIndices := 3600000 },
  { cell := 0.02, dims := 128, move := 0.3, slideStart := 0.55, slideEnd := 0.85,
    maxVertices := 300000, maxIndices := 1800000 }
]

/-- How many of a grid's z the fine levels bake a frame. -/
def fineSlab : Nat := 16

/-- What bakes a level of the reef's mesh (`shaders/reefbake.wgsl`): the
four passes' pipelines and their layouts, shared by every level; and what
draws one (`shaders/bommie.wgsl`): its pipeline and its own layout. -/
structure ReefBaker where
  fieldPipe  : ComputePipeline
  vertexPipe : ComputePipeline
  facePipe   : ComputePipeline
  countPipe  : ComputePipeline
  fieldLayout  : BindGroupLayout
  vertexLayout : BindGroupLayout
  faceLayout   : BindGroupLayout
  countLayout  : BindGroupLayout
  drawPipe   : RenderPipeline
  drawLayout : BindGroupLayout

def ReefBaker.create (device : Device) (shared : String)
    (frameLayout : BindGroupLayout) (format depthFormat : TextureFormat) : IO ReefBaker := do
  let module ← createShader device "reef bake" (Shaders.rock ++ Shaders.reefbake)
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
  let pass (entry : String) (entries : Array BindGroupLayoutEntry) :
      IO (ComputePipeline × BindGroupLayout) := do
    let layout ← device.createBindGroupLayout { label := entry, entries }
    let pipeline ← device.createComputePipeline {
      label := entry
      layout := some (← device.createPipelineLayout {
        label := entry, bindGroupLayouts := #[layout] })
      compute := { module, entryPoint := some entry } }
    return (pipeline, layout)
  let (fieldPipe, fieldLayout) ← pass "field" #[uniformEntry, readEntry 1, fieldWrite]
  let (vertexPipe, vertexLayout) ← pass "vertexPass"
    #[uniformEntry, readEntry 1, fieldRead, writeEntry 4, writeEntry 5, writeEntry 6]
  let (facePipe, faceLayout) ← pass "facePass"
    #[uniformEntry, fieldRead, writeEntry 5, writeEntry 6, writeEntry 7]
  let (countPipe, countLayout) ← pass "countPass"
    #[uniformEntry, writeEntry 6, writeEntry 8]
  let drawLayout ← device.createBindGroupLayout {
    label := "bommies"
    entries := #[
      { binding := 0, visibility := .vertex, buffer := { type := .readOnlyStorage } },
      { binding := 1, visibility := .fragment,
        texture := { sampleType := .float, viewDimension := .«2dArray» } },
      { binding := 2, visibility := .fragment, sampler := { type := .filtering } },
      { binding := 3, visibility := .vertex ||| .fragment, buffer := { type := .uniform } },
      { binding := 4, visibility := .vertex,
        texture := { sampleType := .unfilterableFloat, viewDimension := .«3d» } }]
  }
  let drawModule ← createShader device "bommies" (shared ++ Shaders.bommie)
  let drawPipe ← device.createRenderPipeline {
    label    := "bommies"
    layout   := some (← device.createPipelineLayout {
      label := "bommies", bindGroupLayouts := #[frameLayout, drawLayout] })
    vertex   := { module := drawModule, entryPoint := some "vs" }
    fragment := some {
      module := drawModule, entryPoint := some "fs", targets := #[{ format := format }] }
    primitive := { topology := .triangleList, cullMode := .back }
    depthStencil := some {
      format := depthFormat, depthWriteEnabled := .true, depthCompare := .less }
  }
  return { fieldPipe, vertexPipe, facePipe, countPipe, fieldLayout, vertexLayout,
           faceLayout, countLayout, drawPipe, drawLayout }

/-- A level of the reef's mesh: a grid of the field over a box, its
cells `cell` wide, `dims` points along each axis; the field, and the mesh
made of it, with the draw's arguments; and the bind groups that bake and
draw it, the draw's one for each of its parent's fields it may slide
onto. Its box's corner is `origin`, which a finer level moves with the
camera. -/
structure ReefLevel where
  origin   : IO.Ref Vec3
  cell     : Float
  dims     : Nat × Nat × Nat
  maxVertices : Nat
  maxIndices  : Nat
  uniform  : Buffer
  field    : Texture
  fieldView : TextureView
  vertices : Buffer
  indices  : Buffer
  counts   : Buffer
  args     : Buffer
  /-- The draw's own uniforms (`Lod` in shaders/bommie.wgsl). -/
  lod      : Buffer
  fieldData  : BindGroup
  vertexData : BindGroup
  faceData   : BindGroup
  countData  : BindGroup
  drawData   : Array BindGroup

def ReefLevel.create (device : Device) (baker : ReefBaker) (detail : Tile) (blobs : Buffer)
    (label : String) (origin : Vec3) (cell : Float) (dims : Nat × Nat × Nat)
    (maxVertices maxIndices : Nat) (cellIndex : Buffer) (parents : Array TextureView) :
    IO ReefLevel := do
  let (nx, ny, nz) := dims
  let uniform ← createBuffer device s!"{label} bake" .uniform (ByteArray.mk (Array.replicate 64 0))
  let field ← device.createTexture {
    label := s!"{label} field", dimension := .«3d»
    usage := .storageBinding ||| .textureBinding
    size := { width := nx.toUInt32, height := ny.toUInt32, depthOrArrayLayers := nz.toUInt32 }
    format := .r32Float
  }
  let fieldView ← field.createView none
  let vertices ← storageBuffer device s!"{label} vertices" (maxVertices * 32)
  let indices ← storageBuffer device s!"{label} indices" (maxIndices * 4) .index
  let counts ← storageBuffer device s!"{label} counts" 8
  let args ← storageBuffer device s!"{label} draw" 20 .indirect
  let lod ← createBuffer device s!"{label} lod" .uniform (ByteArray.mk (Array.replicate 64 0))
  let group (layout : BindGroupLayout) (entries : Array BindGroupEntry) :=
    device.createBindGroup { label, layout, entries }
  let fieldData ← group baker.fieldLayout
    #[{ binding := 0, buffer := some uniform }, { binding := 1, buffer := some blobs },
      { binding := 2, textureView := some fieldView }]
  let vertexData ← group baker.vertexLayout
    #[{ binding := 0, buffer := some uniform }, { binding := 1, buffer := some blobs },
      { binding := 3, textureView := some fieldView },
      { binding := 4, buffer := some vertices }, { binding := 5, buffer := some cellIndex },
      { binding := 6, buffer := some counts }]
  let faceData ← group baker.faceLayout
    #[{ binding := 0, buffer := some uniform }, { binding := 3, textureView := some fieldView },
      { binding := 5, buffer := some cellIndex }, { binding := 6, buffer := some counts },
      { binding := 7, buffer := some indices }]
  let countData ← group baker.countLayout
    #[{ binding := 0, buffer := some uniform },
      { binding := 6, buffer := some counts }, { binding := 8, buffer := some args }]
  -- (The whole reef's level has no parent: its own field stands in.)
  let parents := if parents.isEmpty then #[fieldView] else parents
  let drawData ← parents.mapM fun parent => group baker.drawLayout
    #[{ binding := 0, buffer := some vertices },
      { binding := 1, textureView := some detail.view },
      { binding := 2, sampler := some detail.sampler },
      { binding := 3, buffer := some lod },
      { binding := 4, textureView := some parent }]
  return { origin := ← IO.mkRef origin, cell, dims, maxVertices, maxIndices, uniform,
           field, fieldView, vertices, indices, counts, args, lod,
           fieldData, vertexData, faceData, countData, drawData }

/-- Workgroups of `size` to cover `n`. -/
def groupsFor (n size : Nat) : UInt32 := ((n + size - 1) / size).toUInt32

/-- Run `pipeline` with `data` over `x` × `y` × `z` workgroups, in `encoder`. -/
def runPass (encoder : CommandEncoder) (pipeline : ComputePipeline) (data : BindGroup)
    (x y z : UInt32) : IO Unit := do
  let c ← encoder.beginComputePass none
  c.setPipeline pipeline
  c.setBindGroup 0 (some data) #[]
  c.dispatchWorkgroups x y z
  c.«end»

/-- Write `l`'s bake uniforms for the slab of `zCount` points along z from
`zStart`, its box at its origin now. -/
def ReefLevel.writeBake (l : ReefLevel) (queue : Queue) (blobCount : Nat) (sun : Vec3)
    (zStart zCount : Nat) : IO Unit := do
  queue.writeBuffer l.uniform 0
    (reefBakeBytes (← l.origin.get) l.cell l.dims blobCount sun false zStart zCount
      l.maxVertices l.maxIndices)

/-- Encode the field pass over `zCount` of `l`'s grid's z (the uniforms
written for that slab). -/
def ReefLevel.encodeField (l : ReefLevel) (baker : ReefBaker) (encoder : CommandEncoder)
    (zCount : Nat) : IO Unit := do
  let (nx, ny, _) := l.dims
  runPass encoder baker.fieldPipe l.fieldData (groupsFor nx 4) (groupsFor ny 4) (groupsFor zCount 4)

/-- Encode the mesh's passes over `l`'s field: its counts cleared, its
vertices, its faces, and the draw's arguments. -/
def ReefLevel.encodeMesh (l : ReefLevel) (baker : ReefBaker) (encoder : CommandEncoder) :
    IO Unit := do
  let (nx, ny, nz) := l.dims
  encoder.clearBuffer l.counts 0 8
  runPass encoder baker.vertexPipe l.vertexData
    (groupsFor (nx - 1) 4) (groupsFor (ny - 1) 4) (groupsFor (nz - 1) 4)
  runPass encoder baker.facePipe l.faceData (groupsFor nx 4) (groupsFor ny 4) (groupsFor nz 4)
  runPass encoder baker.countPipe l.countData 1 1 1

/-- Draw `l` in `pass` (the frame's bind group set), sliding onto its
parent's field `parent` (of its draw bind groups). -/
def ReefLevel.draw (l : ReefLevel) (baker : ReefBaker) (pass : RenderPassEncoder)
    (parent : Nat := 0) : IO Unit := do
  pass.setPipeline baker.drawPipe
  if let some data := l.drawData[parent]? <|> l.drawData[0]? then
    pass.setBindGroup 1 (some data) #[]
  pass.setIndexBuffer l.indices .uint32 0 (l.maxIndices * 4).toUInt64
  pass.drawIndexedIndirect l.args 0

/-- A finer level: its spec, its two copies (one drawn while the other is
baked about where the camera has gone), and which is drawn, if either is
baked yet. -/
structure FineLevel where
  spec  : FineSpec
  sets  : Array ReefLevel
  shown : IO.Ref (Option Nat)

/-- The bommies: the whole reef's level, baked once (its field for the
sand and the light too), and the finer levels about the camera. -/
structure Bommies where
  baker     : ReefBaker
  coarse    : ReefLevel
  levels    : Array FineLevel
  /-- The finer level being baked, its copy, and its next slab. -/
  baking    : IO.Ref (Option (Nat × Nat × Nat))
  sun       : Vec3
  blobCount : Nat
  detail    : Tile

/-- The whole reef's field, for the frame's bind group. -/
def Bommies.fieldView (b : Bommies) : TextureView := b.coarse.fieldView

/--
The bommies, baked for a sun from `sun` (where its light comes from,
under the water), drawn with `shared` code before `shaders/bommie.wgsl`
under the frame's `frameLayout`, into `format` with the depth buffer of
`depthFormat`. The whole reef's level is baked here; the finer ones as
the camera goes (`update`).
-/
def Bommies.create (device : Device) (sun : Vec3) (shared : String)
    (frameLayout : BindGroupLayout) (format depthFormat : TextureFormat) :
    IO Bommies := do
  let queue ← device.getQueue
  let (blobData, blobCount) := blobBytes
  let blobs ← createBuffer device "reef blobs" .storage blobData
  let baker ← ReefBaker.create device (shared ++ Shaders.rock) frameLayout format depthFormat
  let detail ← bakeRockDetail device
  let (cx, cy, cz) := reefDims
  let coarseCells ← storageBuffer device "reef cells" ((cx - 1) * (cy - 1) * (cz - 1) * 4)
  let coarse ← ReefLevel.create device baker detail blobs "reef" reefOrigin reefCell reefDims
    reefMaxVertices reefMaxIndices coarseCells #[]
  let mut levels : Array FineLevel := #[]
  let mut parents := #[coarse.fieldView]
  for h : n in [0:fineSpecs.size] do
    let spec := fineSpecs[n]
    let cells ← storageBuffer device s!"reef {n} cells" ((spec.dims - 1) ^ 3 * 4)
    let sets ← (List.range 2).toArray.mapM fun k =>
      ReefLevel.create device baker detail blobs s!"reef {n}.{k}" reefOrigin spec.cell
        (spec.dims, spec.dims, spec.dims) spec.maxVertices spec.maxIndices cells parents
    levels := levels.push { spec, sets, shown := ← IO.mkRef none }
    parents := sets.map (·.fieldView)
  coarse.writeBake queue blobCount sun 0 cz
  let encoder ← device.createCommandEncoder none
  coarse.encodeField baker encoder cz
  coarse.encodeMesh baker encoder
  queue.submit #[← encoder.finish none]
  return { baker, coarse, levels, baking := ← IO.mkRef none, sun, blobCount, detail }

/-- A finer level's box's corner for an eye at `eye`: the box about it, on
the lattice of its cells (so that two bakes of it, wherever their boxes,
make the same mesh where they overlap). -/
def boxCornerFor (spec : FineSpec) (eye : Vec3) : Vec3 :=
  let half := spec.cell * (spec.dims - 1).toFloat / 2
  let snap (v : Float) := (v / spec.cell).floor * spec.cell
  ⟨snap (eye.x - half), snap (eye.y - half), snap (eye.z - half)⟩

/-- The `Lod` uniforms (shaders/bommie.wgsl) for a level of cells `cell`,
sliding onto its parent's from `slideStart` to `slideEnd` (if it has a
parent: its box's corner, cells and dims); a finer level drawing nearer
than `inner`, this one nearer than `outer`. -/
def lodBytes (cell slideStart slideEnd : Float) (parent : Option (Vec3 × Float × Nat × Nat × Nat))
    (inner outer : Float) : ByteArray :=
  let (po, pc, px, py, pz, has) := match parent with
    | some (o, c, x, y, z) => (o, c, x, y, z, 1.0)
    | none => ((⟨0, 0, 0⟩ : Vec3), 1.0, 1, 1, 1, 0.0)
  [cell, slideStart, slideEnd, has, inner, outer, 0, 0,
   po.x, po.y, po.z, pc, px.toFloat, py.toFloat, pz.toFloat, 0].foldl pushF32 ByteArray.empty

-- (Each finer level draws a little past its reach, where it is wholly
-- its parent's surface already, over its parent's mesh: so that the two
-- overlap, with no crack between.)

/-- A frame's work for the bommies, in `encoder`, for an eye at `eye`: a
slab of the finer level being baked, or its mesh once its field is whole
(and then it is drawn in place of the copy before: the same, where they
overlap); or, the first level the eye has gone far enough from, begun
about it. And every level's `Lod` uniforms. -/
def Bommies.update (b : Bommies) (queue : Queue) (encoder : CommandEncoder) (eye : Vec3) :
    IO Unit := do
  match ← b.baking.get with
  | some (n, k, slab) =>
    let some level := b.levels[n]? | b.baking.set none
    let l := level.sets.getD k b.coarse
    let dims := level.spec.dims
    if slab < dims then
      let count := min fineSlab (dims - slab)
      l.writeBake queue b.blobCount b.sun slab count
      l.encodeField b.baker encoder count
      b.baking.set (some (n, k, slab + count))
    else
      l.writeBake queue b.blobCount b.sun 0 dims
      l.encodeMesh b.baker encoder
      level.shown.set (some k)
      b.baking.set none
  | none =>
    -- The first level, coarsest first, that wants baking about the eye
    -- (and whose parent is drawn).
    let mut parentShown := true
    for h : n in [0:b.levels.size] do
      let level := b.levels[n]
      if !parentShown then break
      let shown ← level.shown.get
      let far ← match shown with
        | none => pure true
        | some k => do
          let corner ← (level.sets.getD k b.coarse).origin.get
          let half := level.spec.cell * (level.spec.dims - 1).toFloat / 2
          pure ((eye.x - (corner.x + half)).abs > level.spec.move
                || (eye.y - (corner.y + half)).abs > level.spec.move
                || (eye.z - (corner.z + half)).abs > level.spec.move)
      if far then
        let k := match shown with
          | some k => 1 - k
          | none => 0
        (level.sets.getD k b.coarse).origin.set (boxCornerFor level.spec eye)
        b.baking.set (some (n, k, 0))
        break
      parentShown := shown.isSome
  -- Every level's uniforms: each drawing between its child's reach and
  -- its own, sliding onto its parent's.
  let reachOf (n : Nat) : IO Float := do
    match b.levels[n]? with
    | some level => if (← level.shown.get).isSome then pure level.spec.slideEnd else pure 0
    | none => pure 0
  queue.writeBuffer b.coarse.lod 0 (lodBytes reefCell 1e6 2e6 none (← reachOf 0) 1e6)
  for h : n in [0:b.levels.size] do
    let level := b.levels[n]
    if let some k ← level.shown.get then
      let parent ← if n == 0 then
          pure (some ((← b.coarse.origin.get), reefCell, reefDims.1, reefDims.2.1, reefDims.2.2))
        else
          match b.levels[n - 1]? with
          | none => pure none
          | some p =>
            match ← p.shown.get with
            | some pk => do
              let o ← (p.sets.getD pk b.coarse).origin.get
              pure (some (o, p.spec.cell, p.spec.dims, p.spec.dims, p.spec.dims))
            | none => pure none
      queue.writeBuffer (level.sets.getD k b.coarse).lod 0
        (lodBytes level.spec.cell level.spec.slideStart level.spec.slideEnd parent
          (← reachOf (n + 1)) (level.spec.slideEnd + 0.1))

/-- Draw the bommies in `pass` (the frame's bind group set): every level,
each within its reach. -/
def Bommies.draw (b : Bommies) (pass : RenderPassEncoder) : IO Unit := do
  b.coarse.draw b.baker pass
  for h : n in [0:b.levels.size] do
    let level := b.levels[n]
    if let some k ← level.shown.get then
      let parentSet ← if n == 0 then pure 0 else
        match b.levels[n - 1]? with
        | some p => pure ((← p.shown.get).getD 0)
        | none => pure 0
      (level.sets.getD k b.coarse).draw b.baker pass parentSet

/-- The bommies as the surge sees them (`shaders/seabed.wgsl`): circles
on the floor about their middles, a little inside their footprints:
x, z, radius, unused. -/
def bommieCircles : ByteArray :=
  bommies.foldl (fun b m => [m.x, m.z, 0.5 * m.width, 0].foldl pushF32 b) ByteArray.empty

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
  /-- The surge's flow about the bommies, for the ripples. -/
  flow     : Texture
  flowView : TextureView
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
  let flow ← device.createTexture {
    label := "seabed flow", usage := .storageBinding ||| .textureBinding
    size := { width := seabedSize.toUInt32, height := seabedSize.toUInt32 }
    format := .rgba16Float }
  let flowView ← flow.createView none
  let circles ← createBuffer device "bommie circles" .storage bommieCircles
  let written (n : UInt32) : BindGroupLayoutEntry :=
    { binding := n, visibility := .compute
      storageTexture := { access := .writeOnly, format := .rgba16Float, viewDimension := .«2d» } }
  let layout ← device.createBindGroupLayout {
    label := "seabed"
    entries := #[written 0, written 1,
                 { binding := 2, visibility := .compute, buffer := { type := .readOnlyStorage } }] }
  let module ← createShader device "seabed" (shared ++ Shaders.seabed)
  let pipeline ← device.createComputePipeline {
    label := "seabed"
    layout := some (← device.createPipelineLayout {
      label := "seabed", bindGroupLayouts := #[frameLayout, layout] })
    compute := { module, entryPoint := some "bakeSeabed" } }
  let data ← device.createBindGroup {
    label := "seabed", layout
    entries := #[{ binding := 0, textureView := some view },
                 { binding := 1, textureView := some flowView },
                 { binding := 2, buffer := some circles }] }
  return { texture, view, flow, flowView, pipeline, frameData, data }

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
