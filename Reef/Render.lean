import Reef.App
import Reef.Floor
import Reef.Overlay

/-!
# Drawing

One render pass, with a depth buffer: the sand, the floor's quadtree
(`Reef/Floor.lean`, `shaders/sand.wgsl`), the nodes chosen for the eye
this frame, drawn at once; over it, if shown, its wireframe
(`shaders/wire.wgsl`), and the grid (`shaders/grid.wgsl`), each blended
over; then the overlay's text over all (`Reef/Overlay.lean`). The
background is the colour the floor fades into.

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
  sand     : RenderPipeline
  sandWire : RenderPipeline
  grid     : RenderPipeline
  /-- The frame's uniforms, written each frame. -/
  frame    : Buffer
  /-- The bind group of the frame's uniforms, for every pipeline here. -/
  data     : BindGroup
  /-- The floor's mesh: made again when the detail changes (`remesh`). -/
  floor    : IO.Ref FloorMesh
  /-- How many of the floor's nodes the last frame drew, for the overlay. -/
  drawn    : IO.Ref Nat
  /-- The depth buffer, once a frame has been drawn, for its size. -/
  depth    : IO.Ref (Option Depth)
  /-- The text over it all. -/
  overlay  : Overlay

/-- The camera's field of view, up and down, in radians: 60 degrees. -/
def fovY : Float := 1.0472

/-- The nearest and farthest the camera sees, in metres. -/
def near : Float := 0.05
def far : Float := 2000

/--
The frame's uniforms, as WGSL lays out its `Frame`: the view and projection
as one matrix, where the camera is, the grid, and the floor (a patch's
cells, the leaves' range, the morph fraction): 112 bytes.
-/
def frameBytes (viewProj : Mat4) (camera : Vec3) (grid : Grid)
    (floor : Floor) (cells : Nat) : ByteArray :=
  (viewProj.m.toList ++ [camera.x, camera.y, camera.z, 0]
    ++ [grid.spacing, grid.major, grid.extent, grid.fade]
    ++ [cells.toFloat, floor.range, floor.morph, 0]).foldl
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

/-- A renderer drawing into targets of `format`, the floor `floor`. -/
def Renderer.create (device : Device) (format : TextureFormat)
    (floor : Floor) : IO Renderer := do
  -- One layout for every pipeline here: the frame's uniforms, and the
  -- floor's nodes, so that one bind group serves them all (a pipeline's own
  -- layout is exclusive to it).
  let frameLayout ← device.createBindGroupLayout {
    label   := "frame"
    entries := #[
      { binding := 0, visibility := .vertex ||| .fragment,
        buffer := { type := .uniform } },
      { binding := 1, visibility := .vertex,
        buffer := { type := .readOnlyStorage } }
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
  let sand ← pipeline device "sand" layout sandModule format #[latticeLayout]
  let sandWire ← pipeline device "sand wire" layout sandModule format
    #[latticeLayout] (fragment := "fs_wire")
    (depthCompare := .lessEqual) (depthWrite := false) (blend := some overBlend)
  let grid ← pipeline device "grid" layout gridModule format
    (depthCompare := .always) (depthWrite := false) (blend := some overBlend)
  let frame ← createBuffer device "frame" .uniform
    (frameBytes Mat4.identity Vec3.zero {} floor floor.cells)
  let mesh ← FloorMesh.create device floor.cells
  let data ← device.createBindGroup {
    label   := "frame"
    layout  := frameLayout
    entries := #[
      { binding := 0, buffer := some frame },
      { binding := 1, buffer := some mesh.nodes }
    ]
  }
  return {
    device, format, sand, sandWire, grid, frame, data
    queue   := ← device.getQueue
    floor   := ← IO.mkRef mesh
    drawn   := ← IO.mkRef 0
    depth   := ← IO.mkRef none
    overlay := ← Overlay.create device format depthFormat
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
  let viewProj := Mat4.perspective fovY aspect near far * app.camera.view
  let floor ← r.floor.get
  r.queue.writeBuffer r.frame 0
    (frameBytes viewProj app.camera.position app.grid app.floor floor.cells)
  -- The floor's nodes for this eye and view.
  let nodes := app.floor.quadtree.select app.camera.position
    (Frustum.ofMatrix viewProj)
  r.queue.writeBuffer floor.nodes 0 (Node.bytes nodes)
  r.drawn.set nodes.size
  let count := nodes.size.toUInt32
  let view ← texture.createView (some { format := r.format })
  let depth ← r.depthFor app.width app.height
  let encoder ← r.device.createCommandEncoder none
  let pass ← encoder.beginRenderPass {
    colorAttachments := #[{
      view       := some view
      loadOp     := .clear
      storeOp    := .store
      clearValue := { r := 0.02, g := 0.05, b := 0.09, a := 1 }
    }]
    depthStencilAttachment := some {
      view            := depth.view
      depthLoadOp     := .clear
      depthStoreOp    := .discard
      depthClearValue := some 1
    }
  }
  pass.setBindGroup 0 (some r.data) #[]
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
  r.queue.submit #[← encoder.finish none]

end Reef
