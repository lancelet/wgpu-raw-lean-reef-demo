import Reef.App
import Reef.Floor
import Reef.Overlay
import Reef.Bommies
import Reef.Caustics
import Reef.Snow
import Reef.Grains
import Reef.Ripples
import Reef.Timing

/-!
# Drawing

Before the frame's pass, the sea's surface for the moment, evolved in
compute (`Reef/Caustics.lean`), for the surface drawn from below
(`shaders/surface.wgsl`) over the sand. Three render passes, timed as
a whole from the first's beginning to the last's end (on Metal a
pass's own stamps overlap the next's, so passes cannot be told apart;
what a thing costs is the difference with it off): the water behind,
then the sand, the floor's quadtree
(`Reef/Floor.lean`, `shaders/sand.wgsl`), the nodes chosen for the eye
this frame, drawn at once, its ripples and its grains from their tiles
(`Reef/Ripples.lean`, `Reef/Grains.lean`); over it, if shown, its wireframe
(`shaders/wire.wgsl`), and the grid (`shaders/grid.wgsl`), each blended
over; then the overlay's text over all (`Reef/Overlay.lean`). Between
the scene and the overlays, the light in the water (`shaders/shafts.wgsl`),
a pass of its own that reads the scene's depth and adds to its colour.

Everything is drawn relative to the camera, which the view matrix puts at
the origin: far from the world's origin, the floats the GPU works in would
jitter. The shaders get the camera's place in the world besides, for what
is a function of it (the floor's height, the grid's lines).

## The water

Drawn first, a triangle over the whole target coloured by each pixel's
direction (`shaders/background.wgsl`), so that where nothing else is,
there is water; what is drawn after fades into the same water with
distance (`fogged`, in `shaders/frame.wgsl`). The frame is cleared to
nothing in particular.

## The wireframe

Every material's shader gets the frame's uniforms (`Shaders.frame`) and
the wireframe's fragment entry (`Shaders.wire`) put before its own, and a
second pipeline: the material's vertex shader, that entry, and the mesh's
triangles again with no indices, each corner its own vertex, drawn after
the triangles with a depth test that lets them through where they
coincide. The entry draws each triangle's edges, anti-aliased, from the
corner's barycentric coordinate the vertex shader gives it. So the lines
are the triangles', whatever the vertex shader does to them, and any mesh
with its triangles so expanded gets a wireframe with no shader of its own.
-/

open WebGPU.Raw

namespace Reef

/-- The depth buffer's format. -/
def depthFormat : TextureFormat := .depth24Plus

/-- The light in the water's format, and the scene's: floats, for light
as bright as it is, made colour at the end (`shaders/resolve.wgsl`). -/
def shaftFormat : TextureFormat := .rgba16Float
def sceneFormat : TextureFormat := .rgba16Float

/-- The depth buffer, and the size it is for; with it, the scene's target
in light, and the bind group that resolves it to colour. -/
structure Depth where
  texture : Texture
  view    : TextureView
  width   : UInt32
  height  : UInt32
  scene   : TextureView
  resolve : BindGroup
  /-- The reflection's target and its depth, half the size, and the
  surface's bind group that reads the target. -/
  mirror      : TextureView
  mirrorDepth : TextureView
  mirrorData  : BindGroup

/-- What drawing a frame needs, made once. -/
structure Renderer where
  device   : Device
  queue    : Queue
  /-- The format drawn in: the targets' views are of it. -/
  format   : TextureFormat
  /-- The sand's pipeline, and its wireframe's. -/
  backdrop : RenderPipeline
  surface  : RenderPipeline
  /-- The reef's framework: the bommies. -/
  bommies  : Bommies
  /-- The seabed's map, and its bake: run once, on the first frame, when
  the frame's uniforms hold the floor and the sun. -/
  seabed   : Seabed
  seabedBaked : IO.Ref Bool
  /-- The marine snow, and the last frame's time, for its step. -/
  snow     : Snow
  lastTime : IO.Ref Float
  /-- The reflection: a mirrored frame's uniforms, its own nodes, the bind
  group of them, and the surface's layout for the texture it is drawn
  into. -/
  mirrorFrame  : Buffer
  mirrorNodes  : Buffer
  mirrorData   : BindGroup
  mirrorLayout : BindGroupLayout
  mirrorSampler : Sampler
  shafts   : RenderPipeline
  /-- The shafts' second bind group, the scene's depth: made with the
  depth buffer; their target, half the scene's size, made with it too;
  and the pass adding it over the scene, with its bind group. -/
  shaftLayout : BindGroupLayout
  shaftData   : IO.Ref (Option BindGroup)
  shaftTarget : IO.Ref (Option TextureView)
  shaftBlend  : RenderPipeline
  shaftBlendLayout : BindGroupLayout
  shaftBlendData   : IO.Ref (Option BindGroup)
  shaftSampler     : Sampler
  /-- The scene's light made colour for the display, with its bind group's
  layout (the bind group is made with the scene's target). -/
  resolve       : RenderPipeline
  resolveLayout : BindGroupLayout
  /-- The surface's grid, indexed, and how many indices. -/
  surfaceIndices : Buffer
  surfaceCount   : UInt32
  sand     : RenderPipeline
  sandWire : RenderPipeline
  grid     : RenderPipeline
  /-- The frame's uniforms, written each frame. -/
  frame    : Buffer
  /-- The ripples' tile, and their horizons', and the grains', baked once;
  and the caustics' loop. -/
  ripples  : Tile
  horizons : Tile
  grains   : Tile
  caustics : Caustics
  /-- The bind group of the frame's uniforms, the floor's nodes and the
  tiles, for every pipeline here. -/
  data     : BindGroup
  /-- The floor's mesh: made again when the detail changes (`remesh`). -/
  floor    : IO.Ref FloorMesh
  /-- How many of the floor's nodes the last frame drew, for the overlay. -/
  drawn    : IO.Ref Nat
  /-- The depth buffer, once a frame has been drawn, for its size. -/
  depth    : IO.Ref (Option Depth)
  /-- The text over it all. -/
  overlay  : Overlay
  /-- The frame's time on the GPU, if the device can stamp it. -/
  timing   : Option Timing
  /-- Frames drawn, for the timing's ring. -/
  frames   : IO.Ref Nat

/-- How much wider the reflection's view is than the screen's, so that
the surface's wobble always has picture to pull from (`shaders/surface.wgsl`
has the same). -/
def mirrorOverscan : Float := 1.3

/-- The camera's field of view, up and down, in radians: 60 degrees. -/
def fovY : Float := 1.0472

/-- The nearest and farthest the camera sees, in metres. -/
def near : Float := 0.05
def far : Float := 2000

/--
The frame's uniforms, as WGSL lays out its `Frame`: the view and projection
as one matrix, where the camera is (and the angle a pixel subtends), the grid, the floor (a patch's cells,
the leaves' range, the morph fraction, the height's amplitude), the eye's
place in its leaf cell, with the cell's size, the ripples (the waves'
direction, the wavelength, the height; the tile's width, where the
displacement fades from and to, the cavity's strength), the grains (the
tile's width, the relief, the speckle), the sun's direction, the camera's
basis (with the tangents of half the view's width and height), the
screen (its size, the time), and the water (the surface's height, the
caustics' strength; the extinction; the colours; the caustics' loop; the
surface's grid and reach, with the clip planes; the light in the water;
the swell, with its waves' wave numbers): 448 bytes.
-/
def frameBytes (viewProj : Mat4) (camera : Camera) (tanHalf aspect : Float)
    (width height time : Float) (grid : Grid) (floor : Floor) (cells : Nat)
    (ripples : Ripples) (grains : Grains) (sun : Sun) (water : Water) :
    ByteArray :=
  let light := sun.direction
  let pixel := 2 * tanHalf / max height 1
  let eye := camera.position
  let v (x : Vec3) (w : Float) := [x.x, x.y, x.z, w]
  let cell := floor.leaf / cells.toFloat
  let within (x : Float) := x - (x / cell).floor * cell
  let w := water
  (viewProj.m.toList ++ [eye.x, eye.y, eye.z, pixel]
    ++ [grid.spacing, grid.major, grid.extent, grid.fade]
    ++ [cells.toFloat, floor.range, floor.morph, floor.amplitude]
    ++ [within eye.x, within eye.z, cell, 0]
    ++ [ripples.direction.cos, ripples.direction.sin, ripples.wavelength,
        ripples.height]
    ++ [ripples.tile, ripples.fadeFrom, ripples.fadeTo, ripples.cavity]
    ++ [grains.tile, grains.relief, grains.speckle, 0]
    ++ [light.x, light.y, light.z, 0]
    ++ v camera.right (tanHalf * aspect) ++ v camera.up tanHalf
    ++ v camera.forward 0
    ++ [width, height, time, 0]
    ++ [w.depth, w.focus, 0, 0]
    ++ v w.extinction 0 ++ v w.horizon 1 ++ v w.zenith 1 ++ v w.deep 1
    ++ v w.sunlight 1 ++ v w.skylight 1
    ++ [w.tile, w.loop, w.frames.toFloat, min 1 (w.wind / 8)]
    ++ [w.surfaceGrid.toFloat, w.surfaceReach, near, far]
    ++ [w.shafts, w.shaftSteps.toFloat, w.shaftReach, w.exposure]
    ++ [w.swellAtWind, w.swellPeriod, w.swellSpread, 0]
    ++ (swellPeriodFractions.map fun f => waveNumber (w.swellPeriod * f) w.depth).toList
    ++ [reefOrigin.x, reefOrigin.y, reefOrigin.z, reefCell]
    ++ (let (nx, ny, nz) := reefDims; [nx.toFloat, ny.toFloat, nz.toFloat, 0])).foldl
    pushF32 ByteArray.empty

/-- The floor's quadtree, as `floor` says. -/
def Floor.quadtree (f : Floor) : Quadtree :=
  { leaf := f.leaf, range := f.range, depth := f.depth, morph := f.morph,
    relief := f.relief }

/-- Drawn over what is there, as much as it is opaque: the overlays. -/
def overBlend : BlendState := {
  color := { operation := .add, srcFactor := .srcAlpha,
             dstFactor := .oneMinusSrcAlpha }
  alpha := { operation := .add, srcFactor := .zero, dstFactor := .one }
}

/-- The lattice's vertex layout: two floats a vertex, at location 0. -/
def latticeLayout : VertexBufferLayout := {
  stepMode    := .vertex
  arrayStride := 8
  attributes  := #[{ format := .float32x2, offset := 0, shaderLocation := 0 }]
}

/--
A pipeline drawing with `module`'s `vs` and `fs` (or `fragment`) into
`format`, with the depth buffer: testing against it, and writing it if
`depthWrite`; `topology` as given, blended as `blend` says.
-/
def pipeline (device : Device) (label : String) (layout : PipelineLayout)
    (module : ShaderModule)
    (format : TextureFormat) (buffers : Array VertexBufferLayout := #[])
    (fragment : String := "fs") (topology : PrimitiveTopology := .triangleList)
    (depthCompare : CompareFunction := .less) (depthWrite : Bool := true)
    (blend : Option BlendState := none) :
    IO RenderPipeline :=
  device.createRenderPipeline {
    label     := label
    layout    := some layout
    vertex    := { module := module, entryPoint := some "vs", buffers }
    fragment  := some {
      module     := module
      entryPoint := some fragment
      targets    := #[{ format := format, blend := blend }]
    }
    primitive := { topology, cullMode := .none }
    depthStencil := some {
      format            := depthFormat
      depthWriteEnabled := if depthWrite then .true else .false
      depthCompare
    }
  }

/-- What is timed, in order: the one pass, the frame. -/
def passes : Array String := #["frame"]

/-- A renderer drawing into targets of `format`, the floor `floor`, its
ripples `ripples` and its grains `grains` (baked here), under `water`
(its caustics baked here too); timing its passes if `timestamps`. -/
def Renderer.create (device : Device) (format : TextureFormat)
    (floor : Floor) (ripples : Ripples) (grains : Grains) (water : Water)
    (sun : Sun) (timestamps : Bool := false) : IO Renderer := do
  -- One layout for every pipeline here: the frame's uniforms, the floor's
  -- nodes, and the tiles, so that one bind group serves them all (a
  -- pipeline's own layout is exclusive to it).
  let frameLayout ← device.createBindGroupLayout {
    label   := "frame"
    entries := #[
      { binding := 0, visibility := .vertex ||| .fragment ||| .compute,
        buffer := { type := .uniform } },
      { binding := 1, visibility := .vertex,
        buffer := { type := .readOnlyStorage } },
      { binding := 2, visibility := .vertex ||| .fragment,
        texture := { sampleType := .float, viewDimension := .«2d» } },
      { binding := 3, visibility := .vertex ||| .fragment,
        sampler := { type := .filtering } },
      { binding := 4, visibility := .fragment,
        texture := { sampleType := .float, viewDimension := .«2dArray» } },
      { binding := 5, visibility := .fragment,
        texture := { sampleType := .float, viewDimension := .«2d» } },
      { binding := 6, visibility := .vertex ||| .fragment,
        texture := { sampleType := .float, viewDimension := .«2dArray» } },
      { binding := 7, visibility := .vertex ||| .fragment ||| .compute,
        buffer := { type := .readOnlyStorage } },
      { binding := 8, visibility := .fragment ||| .compute,
        texture := { sampleType := .unfilterableFloat, viewDimension := .«3d» } },
      { binding := 9, visibility := .vertex ||| .fragment,
        texture := { sampleType := .float, viewDimension := .«2d» } }
    ]
  }
  let layout ← device.createPipelineLayout {
    label := "frame", bindGroupLayouts := #[frameLayout]
  }
  -- Each material's module: the frame's uniforms, the wireframe's entry,
  -- then its own.
  let shared := Shaders.frame ++ Shaders.wire
  let sandModule ← createShader device "sand" (shared ++ Shaders.sand)
  let gridModule ← createShader device "grid" (shared ++ Shaders.grid)
  let waterModule ← createShader device "water" (shared ++ Shaders.background)
  let surfaceModule ← createShader device "surface" (shared ++ Shaders.surface)
  let snow ← Snow.create device water shared frameLayout sceneFormat depthFormat
  let bommies ← Bommies.create device sun.direction shared frameLayout sceneFormat depthFormat
  let mirrorLayout ← device.createBindGroupLayout {
    label   := "reflection"
    entries := #[
      { binding := 0, visibility := .fragment,
        texture := { sampleType := .float, viewDimension := .«2d» } },
      { binding := 1, visibility := .fragment, sampler := { type := .filtering } }]
  }
  let surfaceLayout ← device.createPipelineLayout {
    label := "surface", bindGroupLayouts := #[frameLayout, mirrorLayout] }
  let surface ← pipeline device "surface" surfaceLayout surfaceModule sceneFormat
  let mirrorSampler ← device.createSampler (some {
    label := "reflection", addressModeU := .clampToEdge, addressModeV := .clampToEdge,
    magFilter := .linear, minFilter := .linear })
  -- The shafts: the frame's bind group, and the scene's depth in a second.
  let shaftLayout ← device.createBindGroupLayout {
    label   := "shafts"
    entries := #[{ binding := 0, visibility := .fragment,
                   texture := { sampleType := .depth, viewDimension := .«2d» } }]
  }
  let shaftPipelineLayout ← device.createPipelineLayout {
    label := "shafts", bindGroupLayouts := #[frameLayout, shaftLayout] }
  let shaftModule ← createShader device "shafts" (shared ++ Shaders.shafts)
  let shafts ← device.createRenderPipeline {
    label    := "shafts"
    layout   := some shaftPipelineLayout
    vertex   := { module := shaftModule, entryPoint := some "vs" }
    fragment := some {
      module     := shaftModule
      entryPoint := some "fs"
      targets    := #[{ format := shaftFormat }]
    }
  }
  let shaftBlendLayout ← device.createBindGroupLayout {
    label   := "shaft blend"
    entries := #[
      { binding := 0, visibility := .fragment,
        texture := { sampleType := .float, viewDimension := .«2d» } },
      { binding := 1, visibility := .fragment, sampler := { type := .filtering } }]
  }
  let shaftBlendPipelineLayout ← device.createPipelineLayout {
    label := "shaft blend", bindGroupLayouts := #[frameLayout, shaftBlendLayout] }
  let shaftBlendModule ← createShader device "shaft blend" (shared ++ Shaders.shaftblend)
  let shaftBlend ← device.createRenderPipeline {
    label    := "shaft blend"
    layout   := some shaftBlendPipelineLayout
    vertex   := { module := shaftBlendModule, entryPoint := some "vs" }
    fragment := some {
      module     := shaftBlendModule
      entryPoint := some "fs"
      targets    := #[{ format := sceneFormat, blend := some addBlend }]
    }
  }
  let shaftSampler ← device.createSampler (some {
    label := "shafts", addressModeU := .clampToEdge, addressModeV := .clampToEdge,
    magFilter := .linear, minFilter := .linear })
  let resolveLayout ← device.createBindGroupLayout {
    label   := "resolve"
    entries := #[{ binding := 0, visibility := .fragment,
                   texture := { sampleType := .unfilterableFloat, viewDimension := .«2d» } }]
  }
  let resolvePipelineLayout ← device.createPipelineLayout {
    label := "resolve", bindGroupLayouts := #[frameLayout, resolveLayout] }
  let resolveModule ← createShader device "resolve" (shared ++ Shaders.resolve)
  let resolve ← device.createRenderPipeline {
    label    := "resolve"
    layout   := some resolvePipelineLayout
    vertex   := { module := resolveModule, entryPoint := some "vs" }
    fragment := some {
      module     := resolveModule
      entryPoint := some "fs"
      targets    := #[{ format := format }]
    }
    -- In the pass the overlay's text is drawn in, which has the depth
    -- buffer: neither tested nor written here.
    depthStencil := some {
      format            := depthFormat
      depthWriteEnabled := .false
      depthCompare      := .always
    }
  }
  let surfaceLattice := latticeIndices water.surfaceGrid
  let surfaceIndices ← createBuffer device "surface grid" .index
    (surfaceLattice.foldl pushU32 ByteArray.empty)
  let backdrop ← pipeline device "water" layout waterModule sceneFormat
    (depthCompare := .always) (depthWrite := false)
  let sand ← pipeline device "sand" layout sandModule sceneFormat #[latticeLayout]
  let sandWire ← pipeline device "sand wire" layout sandModule sceneFormat
    #[latticeLayout] (fragment := "fs_wire")
    (depthCompare := .lessEqual) (depthWrite := false) (blend := some overBlend)
  let grid ← pipeline device "grid" layout gridModule sceneFormat
    (depthCompare := .always) (depthWrite := false) (blend := some overBlend)
  let frame ← createBuffer device "frame" .uniform
    (frameBytes Mat4.identity Camera.initial 1 1 1 1 0 {} floor floor.cells
      ripples grains {} water)
  let mesh ← FloorMesh.create device floor.cells
  let caustics ← Caustics.bake device water
  let (tile, horizons) ← ripples.bake device
  let grainTile ← grains.bake device
  let frameEntries (seabedView : TextureView) : Array BindGroupEntry := #[
      { binding := 0, buffer := some frame },
      { binding := 1, buffer := some mesh.nodes },
      { binding := 2, textureView := some tile.view },
      { binding := 3, sampler := some tile.sampler },
      { binding := 4, textureView := some grainTile.view },
      { binding := 5, textureView := some horizons.view },
      { binding := 6, textureView := some caustics.view },
      { binding := 7, buffer := some caustics.field },
      { binding := 8, textureView := some bommies.fieldView },
      { binding := 9, textureView := some seabedView }
    ]
  let seabed ← Seabed.create device shared frameLayout
    (← device.createBindGroup {
      label := "frame for the seabed's bake", layout := frameLayout
      entries := frameEntries (← placeholderView device) })
  let data ← device.createBindGroup {
    label   := "frame"
    layout  := frameLayout
    entries := frameEntries seabed.view
  }
  -- The reflection's: the same, but a mirrored frame and its own nodes.
  let mirrorFrame ← createBuffer device "reflection frame" .uniform
    (frameBytes Mat4.identity Camera.initial 1 1 1 1 0 {} floor floor.cells
      ripples grains {} water)
  let mirrorNodes ← createBuffer device "reflection nodes" .storage
    (ByteArray.mk (Array.replicate (maxNodes * 16) 0))
  let mirrorData ← device.createBindGroup {
    label   := "reflection"
    layout  := frameLayout
    entries := #[
      { binding := 0, buffer := some mirrorFrame },
      { binding := 1, buffer := some mirrorNodes },
      { binding := 2, textureView := some tile.view },
      { binding := 3, sampler := some tile.sampler },
      { binding := 4, textureView := some grainTile.view },
      { binding := 5, textureView := some horizons.view },
      { binding := 6, textureView := some caustics.view },
      { binding := 7, buffer := some caustics.field },
      { binding := 8, textureView := some bommies.fieldView },
      { binding := 9, textureView := some seabed.view }
    ]
  }
  return {
    device, format, backdrop, surface, snow, bommies, seabed, mirrorFrame, mirrorNodes, mirrorData, mirrorLayout,
    mirrorSampler, surfaceIndices, shafts, shaftLayout, sand,
    sandWire, grid, frame, data, horizons, caustics, shaftBlend, shaftBlendLayout,
    shaftSampler, resolve, resolveLayout
    shaftData      := ← IO.mkRef none
    shaftTarget    := ← IO.mkRef none
    shaftBlendData := ← IO.mkRef none
    surfaceCount := surfaceLattice.size.toUInt32
    ripples := tile
    grains  := grainTile
    queue   := ← device.getQueue
    floor   := ← IO.mkRef mesh
    drawn   := ← IO.mkRef 0
    depth   := ← IO.mkRef none
    overlay := ← Overlay.create device format depthFormat
    timing  := ← Timing.create device timestamps passes.size
    frames  := ← IO.mkRef 0
    lastTime := ← IO.mkRef 0
    seabedBaked := ← IO.mkRef false
  }

/-- The floor's mesh made again, for `floor` as it is now: its patch; the
nodes' buffer stays, bound as it is. -/
def Renderer.remesh (r : Renderer) (floor : Floor) : IO Unit := do
  let old ← r.floor.get
  let mesh ← FloorMesh.create r.device floor.cells
  r.floor.set { mesh with nodes := old.nodes }

/-- The depth buffer for a target `width` by `height`: made anew if the
size is new. -/
def Renderer.depthFor (r : Renderer) (width height : UInt32) : IO Depth := do
  if let some d ← r.depth.get then
    if d.width == width && d.height == height then return d
  let texture ← r.device.createTexture {
    label  := "depth"
    usage  := .renderAttachment ||| .textureBinding
    size   := { width, height }
    format := depthFormat
  }
  let sceneTexture ← r.device.createTexture {
    label  := "scene"
    usage  := .renderAttachment ||| .textureBinding
    size   := { width, height }
    format := sceneFormat
  }
  let scene ← sceneTexture.createView none
  let resolve ← r.device.createBindGroup {
    label   := "resolve"
    layout  := r.resolveLayout
    entries := #[{ binding := 0, textureView := some scene }]
  }
  let halfSize : Extent3D := { width := max 1 (width / 10), height := max 1 (height / 10) }
  let mirrorTexture ← r.device.createTexture {
    label := "reflection", usage := .renderAttachment ||| .textureBinding
    size := halfSize, format := sceneFormat }
  let mirrorDepthTexture ← r.device.createTexture {
    label := "reflection depth", usage := .renderAttachment
    size := halfSize, format := depthFormat }
  let mirror ← mirrorTexture.createView none
  let mirrorData ← r.device.createBindGroup {
    label   := "reflection"
    layout  := r.mirrorLayout
    entries := #[{ binding := 0, textureView := some mirror },
                 { binding := 1, sampler := some r.mirrorSampler }]
  }
  let d : Depth := { texture, view := ← texture.createView none, width, height,
                     scene, resolve, mirror, mirrorData
                     mirrorDepth := ← mirrorDepthTexture.createView none }
  r.depth.set (some d)
  -- The shafts read it: their bind group made for it; and their target,
  -- half its size, with the bind group that reads that.
  r.shaftData.set (some (← r.device.createBindGroup {
    label   := "shafts"
    layout  := r.shaftLayout
    entries := #[{ binding := 0, textureView := some d.view }]
  }))
  let half ← r.device.createTexture {
    label  := "shafts"
    usage  := .renderAttachment ||| .textureBinding
    size   := { width := max 1 (width / 4), height := max 1 (height / 4) }
    format := shaftFormat
  }
  let halfView ← half.createView none
  r.shaftTarget.set (some halfView)
  r.shaftBlendData.set (some (← r.device.createBindGroup {
    label   := "shaft blend"
    layout  := r.shaftBlendLayout
    entries := #[{ binding := 0, textureView := some halfView },
                 { binding := 1, sampler := some r.shaftSampler }]
  }))
  return d

/-- Draw the floor's `count` nodes, the patch once each: indexed, or, for
the wireframe (`wire`), the same triangles with no indices. -/
def Renderer.drawFloor (r : Renderer) (pass : RenderPassEncoder)
    (count : UInt32) (wire : Bool) : IO Unit := do
  let floor ← r.floor.get
  if wire then
    pass.setVertexBuffer 0 (some floor.wire) 0 (floor.wireCount.toUInt64 * 8)
    pass.draw floor.wireCount count 0 0
  else
    pass.setVertexBuffer 0 (some floor.vertices) 0
      ((floor.cells + 1) * (floor.cells + 1) * 8).toUInt64
    pass.setIndexBuffer floor.triangles .uint32 0
      (floor.triangleCount.toUInt64 * 4)
    pass.drawIndexed floor.triangleCount count 0 0 0

/--
Draw `app`'s scene into `texture`, `app.width` by `app.height`, through a
view in the renderer's format (the texture's own, or one it allows).
-/
def Renderer.draw (r : Renderer) (app : App) (texture : Texture) :
    IO Unit := do
  let aspect := app.width.toFloat / (max app.height 1).toFloat
  -- Everything is drawn relative to the camera, at the origin: far from
  -- the world's origin, floats would jitter.
  let eye := app.camera.position
  let viewProj := Mat4.perspective fovY aspect near far
    * Mat4.view Vec3.zero app.camera.right app.camera.up (-app.camera.forward)
  let floor ← r.floor.get
  r.queue.writeBuffer r.frame 0
    (frameBytes viewProj app.camera (fovY / 2).tan aspect app.width.toFloat
      app.height.toFloat app.time app.grid app.floor floor.cells app.ripples
      app.grains app.sun app.water)
  -- The floor's nodes for this eye and view.
  let nodes := app.floor.quadtree.select eye (Frustum.ofMatrix viewProj)
  r.queue.writeBuffer floor.nodes 0
    (Node.bytes nodes eye (app.floor.leaf / floor.cells.toFloat))
  r.drawn.set nodes.size
  let count := nodes.size.toUInt32
  -- The reflection: the camera's mirror image in the surface, looking as
  -- the camera looks but mirrored in the vertical, drawn at half size:
  -- a point drawn there lands on the screen where the surface shows it.
  let surfaceY := app.water.depth
  let mirrorEye : Vec3 := ⟨eye.x, 2 * surfaceY - eye.y, eye.z⟩
  let flip : Mat4 := ⟨#[1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]⟩
  let tanMirror := (fovY / 2).tan * mirrorOverscan
  let mirrorViewProj := Mat4.perspective (2 * Float.atan tanMirror) aspect near far
    * Mat4.view Vec3.zero app.camera.right app.camera.up (-app.camera.forward) * flip
  let mirrorCamera := { app.camera with position := mirrorEye, pitch := -app.camera.pitch }
  r.queue.writeBuffer r.mirrorFrame 0
    (frameBytes mirrorViewProj mirrorCamera tanMirror aspect
      (app.width / 10).toFloat (app.height / 10).toFloat app.time app.grid app.floor
      floor.cells app.ripples app.grains app.sun app.water)
  let mirrorNodes := app.floor.quadtree.select mirrorEye (Frustum.ofMatrix mirrorViewProj)
  r.queue.writeBuffer r.mirrorNodes 0
    (Node.bytes mirrorNodes mirrorEye (app.floor.leaf / floor.cells.toFloat))
  let view ← texture.createView (some { format := r.format })
  let depth ← r.depthFor app.width app.height
  let encoder ← r.device.createCommandEncoder none
  let n ← r.frames.get
  -- The sea at this moment, for the surface: the same moment the
  -- caustics' loop is at.
  let loop := app.water.loop
  r.caustics.evolve r.queue encoder (app.time - (app.time / loop).floor * loop)
  -- The snow, a step on.
  let last ← r.lastTime.get
  r.lastTime.set app.time
  r.snow.step r.queue encoder r.data (min 0.1 (max 0 (app.time - last)))
    app.water.snowReach app.time
  -- The seabed's map, once.
  unless ← r.seabedBaked.get do
    r.seabed.bake encoder
    r.seabedBaked.set true
  -- The reflection, first: the sand as the surface mirrors it.
  let pass ← encoder.beginRenderPass {
    colorAttachments := #[{ view := some depth.mirror, loadOp := .clear,
                            storeOp := .store, clearValue := { r := 0, g := 0, b := 0, a := 0 } }]
    depthStencilAttachment := some {
      view := depth.mirrorDepth, depthLoadOp := .clear, depthStoreOp := .discard
      depthClearValue := some 1 }
  }
  pass.setBindGroup 0 (some r.mirrorData) #[]
  pass.setPipeline r.sand
  r.drawFloor pass mirrorNodes.size.toUInt32 (wire := false)
  pass.«end»
  -- The scene, in light: the water behind, the sand, the surface; its
  -- depth kept.
  let pass ← encoder.beginRenderPass {
    colorAttachments := #[{
      view       := some depth.scene
      loadOp     := .clear
      storeOp    := .store
      clearValue := { r := 0, g := 0, b := 0, a := 1 }
    }]
    depthStencilAttachment := some {
      view            := depth.view
      depthLoadOp     := .clear
      depthStoreOp    := .store
      depthClearValue := some 1
    }
    timestampWrites := Timing.beginsFor r.timing 0
  }
  pass.setBindGroup 0 (some r.data) #[]
  pass.setPipeline r.backdrop
  pass.draw 3 1 0 0
  -- The bommies before the sand, which they hide much of.
  r.bommies.draw pass
  pass.setBindGroup 0 (some r.data) #[]
  pass.setPipeline r.sand
  r.drawFloor pass count (wire := false)
  pass.setPipeline r.surface
  pass.setBindGroup 1 (some depth.mirrorData) #[]
  pass.setIndexBuffer r.surfaceIndices .uint32 0 (r.surfaceCount.toUInt64 * 4)
  pass.drawIndexed r.surfaceCount 1 0 0 0
  r.snow.draw pass
  pass.«end»
  -- The light in the water, at half size, reading the scene's depth;
  -- then added over the scene, smoothed.
  if let (some data, some target, some blendData) :=
      (← r.shaftData.get, ← r.shaftTarget.get, ← r.shaftBlendData.get) then
    let pass ← encoder.beginRenderPass {
      colorAttachments := #[{ view := some target, loadOp := .clear, storeOp := .store }]
    }
    pass.setBindGroup 0 (some r.data) #[]
    pass.setBindGroup 1 (some data) #[]
    pass.setPipeline r.shafts
    pass.draw 3 1 0 0
    pass.«end»
    let pass ← encoder.beginRenderPass {
      colorAttachments := #[{ view := some depth.scene, loadOp := .load, storeOp := .store }]
    }
    pass.setBindGroup 0 (some r.data) #[]
    pass.setBindGroup 1 (some blendData) #[]
    pass.setPipeline r.shaftBlend
    pass.draw 3 1 0 0
    pass.«end»
  -- The development overlays, in light too, against the scene's depth.
  let pass ← encoder.beginRenderPass {
    colorAttachments := #[{ view := some depth.scene, loadOp := .load, storeOp := .store }]
    depthStencilAttachment := some {
      view            := depth.view
      depthLoadOp     := .load
      depthStoreOp    := .discard
      depthClearValue := some 1
    }
  }
  pass.setBindGroup 0 (some r.data) #[]
  if app.overlays.wireframe then
    pass.setPipeline r.sandWire
    r.drawFloor pass count (wire := true)
  if app.overlays.grid then
    pass.setPipeline r.grid
    pass.draw 6 1 0 0
  pass.«end»
  -- The light made colour, into the target; the text over that.
  let pass ← encoder.beginRenderPass {
    colorAttachments := #[{ view := some view, loadOp := .clear, storeOp := .store }]
    depthStencilAttachment := some {
      view            := depth.view
      depthLoadOp     := .clear
      depthStoreOp    := .discard
      depthClearValue := some 1
    }
    timestampWrites := Timing.endsFor r.timing 0
  }
  pass.setBindGroup 0 (some r.data) #[]
  pass.setBindGroup 1 (some depth.resolve) #[]
  pass.setPipeline r.resolve
  pass.draw 3 1 0 0
  r.overlay.draw pass app.width app.height
  pass.«end»
  let timed ← match r.timing with
    | some t => t.resolveInto encoder n
    | none => pure false
  r.queue.submit #[← encoder.finish none]
  if timed then
    if let some t := r.timing then t.collect n
  r.frames.set (n + 1)

/-- The latest frame's passes' times on the GPU, in nanoseconds, if any. -/
def Renderer.gpuTimes (r : Renderer) : IO (Option (Array Nat)) :=
  match r.timing with
  | some t => t.latest.get
  | none => pure none

end Reef
