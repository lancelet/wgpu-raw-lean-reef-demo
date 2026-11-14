import Reef.App
import Reef.Floor
import Reef.Overlay
import Reef.Grains
import Reef.Ripples
import Reef.Timing

/-!
# Drawing

One render pass, with a depth buffer, timed as a whole (on Metal a
pass's own stamps overlap the next's, so passes cannot be told apart;
what a thing costs is the difference with it off): the water behind,
then the sand, the floor's quadtree
(`Reef/Floor.lean`, `shaders/sand.wgsl`), the nodes chosen for the eye
this frame, drawn at once, its ripples and its grains from their tiles
(`Reef/Ripples.lean`, `Reef/Grains.lean`); over it, if shown, its wireframe
(`shaders/wire.wgsl`), and the grid (`shaders/grid.wgsl`), each blended
over; then the overlay's text over all (`Reef/Overlay.lean`). The
background is the colour the floor fades into.

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

/-- The depth buffer, and the size it is for. -/
structure Depth where
  texture : Texture
  view    : TextureView
  width   : UInt32
  height  : UInt32

/-- What drawing a frame needs, made once. -/
structure Renderer where
  device   : Device
  queue    : Queue
  /-- The format drawn in: the targets' views are of it. -/
  format   : TextureFormat
  /-- The sand's pipeline, and its wireframe's. -/
  water    : RenderPipeline
  sand     : RenderPipeline
  sandWire : RenderPipeline
  grid     : RenderPipeline
  /-- The frame's uniforms, written each frame. -/
  frame    : Buffer
  /-- The ripples' tile, and their horizons', and the grains', baked once. -/
  ripples  : Tile
  horizons : Tile
  grains   : Tile
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
caustics; the extinction; the colours): 368 bytes.
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
    ++ [w.depth, w.caustic, w.focus, w.speed]
    ++ v w.extinction 0 ++ v w.horizon 1 ++ v w.zenith 1 ++ v w.deep 1
    ++ v w.sunlight 1 ++ v w.skylight 1).foldl
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
ripples `ripples` and its grains `grains` (baked here); timing its passes
if `timestamps`. -/
def Renderer.create (device : Device) (format : TextureFormat)
    (floor : Floor) (ripples : Ripples) (grains : Grains)
    (timestamps : Bool := false) : IO Renderer := do
  -- One layout for every pipeline here: the frame's uniforms, the floor's
  -- nodes, and the tiles, so that one bind group serves them all (a
  -- pipeline's own layout is exclusive to it).
  let frameLayout ← device.createBindGroupLayout {
    label   := "frame"
    entries := #[
      { binding := 0, visibility := .vertex ||| .fragment,
        buffer := { type := .uniform } },
      { binding := 1, visibility := .vertex,
        buffer := { type := .readOnlyStorage } },
      { binding := 2, visibility := .vertex ||| .fragment,
        texture := { sampleType := .float, viewDimension := .«2d» } },
      { binding := 3, visibility := .vertex ||| .fragment,
        sampler := { type := .filtering } },
      { binding := 4, visibility := .fragment,
        texture := { sampleType := .float, viewDimension := .«2d» } },
      { binding := 5, visibility := .fragment,
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
  let water ← pipeline device "water" layout waterModule format
    (depthCompare := .always) (depthWrite := false)
  let sand ← pipeline device "sand" layout sandModule format #[latticeLayout]
  let sandWire ← pipeline device "sand wire" layout sandModule format
    #[latticeLayout] (fragment := "fs_wire")
    (depthCompare := .lessEqual) (depthWrite := false) (blend := some overBlend)
  let grid ← pipeline device "grid" layout gridModule format
    (depthCompare := .always) (depthWrite := false) (blend := some overBlend)
  let frame ← createBuffer device "frame" .uniform
    (frameBytes Mat4.identity Camera.initial 1 1 1 1 0 {} floor floor.cells
      ripples grains {} {})
  let mesh ← FloorMesh.create device floor.cells
  let (tile, horizons) ← ripples.bake device
  let grainTile ← grains.bake device
  let data ← device.createBindGroup {
    label   := "frame"
    layout  := frameLayout
    entries := #[
      { binding := 0, buffer := some frame },
      { binding := 1, buffer := some mesh.nodes },
      { binding := 2, textureView := some tile.view },
      { binding := 3, sampler := some tile.sampler },
      { binding := 4, textureView := some grainTile.view },
      { binding := 5, textureView := some horizons.view }
    ]
  }
  return {
    device, format, water, sand, sandWire, grid, frame, data, horizons
    ripples := tile
    grains  := grainTile
    queue   := ← device.getQueue
    floor   := ← IO.mkRef mesh
    drawn   := ← IO.mkRef 0
    depth   := ← IO.mkRef none
    overlay := ← Overlay.create device format depthFormat
    timing  := ← Timing.create device timestamps passes.size
    frames  := ← IO.mkRef 0
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
    usage  := .renderAttachment
    size   := { width, height }
    format := depthFormat
  }
  let d : Depth := { texture, view := ← texture.createView none, width, height }
  r.depth.set (some d)
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
  let view ← texture.createView (some { format := r.format })
  let depth ← r.depthFor app.width app.height
  let encoder ← r.device.createCommandEncoder none
  let n ← r.frames.get
  let pass ← encoder.beginRenderPass {
    colorAttachments := #[{
      view       := some view
      loadOp     := .clear
      storeOp    := .store
      clearValue := { r := 0, g := 0, b := 0, a := 1 }
    }]
    depthStencilAttachment := some {
      view            := depth.view
      depthLoadOp     := .clear
      depthStoreOp    := .discard
      depthClearValue := some 1
    }
    timestampWrites := Timing.writesFor r.timing 0
  }
  pass.setBindGroup 0 (some r.data) #[]
  pass.setPipeline r.water
  pass.draw 3 1 0 0
  pass.setPipeline r.sand
  r.drawFloor pass count (wire := false)
  if app.overlays.wireframe then
    pass.setPipeline r.sandWire
    r.drawFloor pass count (wire := true)
  if app.overlays.grid then
    pass.setPipeline r.grid
    pass.draw 6 1 0 0
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
