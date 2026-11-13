import Reef.Gpu
import Reef.Math

/-!
# The floor's mesh: a quadtree, chosen by distance

The floor is a quadtree of patches: the root a square wherever the eye is,
each node's four children its quarters, down to leaves well under a metre.
Each frame the eye picks the nodes to draw (Strugar, "Continuous
Distance-Dependent Level of Detail", 2009): a node is drawn at its own
level if it lies beyond its level's range, which doubles with each level
up; else its children are tried in turn. Nodes outside the view are
dropped. So the patches under the eye are the finest, and those far from
it coarse, whichever way the eye looks, and however high it is.

Every node is the one lattice patch, `cells` a side, placed and scaled by
the node's record in a storage buffer (`shaders/sand.wgsl`), which draws
them all at once. Near a node's range the vertex shader morphs its lattice
onto its parent's, so that a node and its neighbour at the next level meet
with no crack, and a level changes with no pop.

For the wireframe, the patch has a companion: its triangles with no
indices, every corner its own vertex, so that each can say which corner it
is (`shaders/wire.wgsl`), drawn with the same vertex shader.
-/

open WebGPU.Raw

namespace Reef

/-- `bytes`, then `x` as 32 bits, little-endian, as WGSL's `u32`. -/
def pushU32 (bytes : ByteArray) (x : UInt32) : ByteArray :=
  bytes |>.push x.toUInt8 |>.push (x >>> 8).toUInt8
    |>.push (x >>> 16).toUInt8 |>.push (x >>> 24).toUInt8

/--
The patch's vertices, `cells + 1` a side, as pairs of floats: the lattice
coordinates, `0` to `cells`, row by row (the second coordinate the slower).
Vertex `(i, j)` is at index `j * (cells + 1) + i`.
-/
def latticeVertices (cells : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.empty
  for j in [0:cells + 1] do
    for i in [0:cells + 1] do
      out := pushF32 (pushF32 out i.toFloat) j.toFloat
  return out

/-- The patch's triangles, two a cell, as indices. -/
def latticeIndices (cells : Nat) : Array UInt32 := Id.run do
  let vertex (i j : Nat) : UInt32 := (j * (cells + 1) + i).toUInt32
  let mut triangles := #[]
  for j in [0:cells] do
    for i in [0:cells] do
      triangles := triangles
        |>.push (vertex i j) |>.push (vertex (i + 1) j) |>.push (vertex i (j + 1))
        |>.push (vertex (i + 1) j) |>.push (vertex (i + 1) (j + 1))
        |>.push (vertex i (j + 1))
  return triangles

/-- The triangles' vertices with no indices, each corner its own, from the
vertices `vertices`, `stride` bytes each. -/
def expanded (indices : Array UInt32) (vertices : ByteArray) (stride : Nat) :
    ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity (indices.size * stride)
  for i in indices do
    out := out ++ vertices.extract (i.toNat * stride) ((i.toNat + 1) * stride)
  return out

/-- The floor's mesh on the GPU: the patch, indexed, and expanded for the
wireframe; and the nodes drawn this frame, as the shader reads them. -/
structure FloorMesh where
  /-- Cells a side of the patch. -/
  cells         : Nat
  vertices      : Buffer
  triangles     : Buffer
  triangleCount : UInt32
  wire          : Buffer
  wireCount     : UInt32
  /-- The nodes' records: `origin.x`, `origin.z`, size, level, each. -/
  nodes         : Buffer

/-- As many nodes as the buffer holds. -/
def maxNodes : Nat := 4096

/-- The floor's mesh, `cells` a side of the patch. -/
def FloorMesh.create (device : Device) (cells : Nat) : IO FloorMesh := do
  let lattice := latticeVertices cells
  let indices := latticeIndices cells
  return {
    cells
    vertices      := ← createBuffer device "lattice" .vertex lattice
    triangles     := ← createBuffer device "triangles" .index
      (indices.foldl pushU32 ByteArray.empty)
    triangleCount := indices.size.toUInt32
    wire          := ← createBuffer device "wire" .vertex (expanded indices lattice 8)
    wireCount     := indices.size.toUInt32
    nodes         := ← createBuffer device "nodes" .storage
      (ByteArray.mk (Array.replicate (maxNodes * 16) 0))
  }

/-- A node of the quadtree, drawn: its corner nearest the origin, its size,
and its level, 0 the leaves. -/
structure Node where
  x     : Float
  z     : Float
  size  : Float
  level : Nat
  deriving Repr, Inhabited

/-- `nodes` as the shader reads them, relative to `eye`: four floats each. -/
def Node.bytes (nodes : Array Node) (eye : Vec3) : ByteArray :=
  nodes.foldl
    (fun b n => [n.x - eye.x, n.z - eye.z, n.size, n.level.toFloat].foldl pushF32 b)
    ByteArray.empty

/-- How the quadtree is chosen: the leaves' size and range, how many levels
up the root is, and where morphing begins, as a fraction of a range. -/
structure Quadtree where
  leaf   : Float
  range  : Float
  depth  : Nat
  morph  : Float
  /-- How far above and below 0 the floor may reach, for culling. -/
  relief : Float

/-- The range of level `level`: the leaves' doubled each level up. -/
def Quadtree.rangeOf (q : Quadtree) (level : Nat) : Float :=
  q.range * (2 : Float) ^ level.toFloat

/-- Whether the square from `(x, z)` of `size` comes within `r` of `eye`. -/
def within (eye : Vec3) (x z size r : Float) (relief : Float) : Bool :=
  let clamp (v lo hi : Float) := min hi (max lo v)
  let nearest : Vec3 := ⟨clamp eye.x x (x + size), clamp eye.y (-relief) relief,
                         clamp eye.z z (z + size)⟩
  (nearest - eye).length < r

/--
The nodes to draw, from `eye` inside `frustum` (which is relative to the
eye, as what is drawn is): the quadtree's, from the root, each at its own
level where it lies beyond its level's range, else its children; none
outside the view. The root is wherever the eye is, snapped to half its
width: so every node's lattice is the same wherever the root goes, the
floor has no edge, and the eye is never nearer one than half the root.
-/
def Quadtree.select (q : Quadtree) (eye : Vec3) (frustum : Frustum) :
    Array Node := Id.run do
  let root := q.leaf * (2 : Float) ^ q.depth.toFloat
  let snap (x : Float) : Float := (x / (root / 2)).floor * (root / 2) - root / 2
  let mut out := #[]
  -- Nodes to try: where, how big, which level.
  let mut stack : Array Node := #[⟨snap eye.x, snap eye.z, root, q.depth⟩]
  while !stack.isEmpty do
    let n := stack.back!
    stack := stack.pop
    unless frustum.intersectsBox (⟨n.x, -q.relief, n.z⟩ - eye)
        (⟨n.x + n.size, q.relief, n.z + n.size⟩ - eye) do continue
    -- Beyond the finer range, or a leaf: this node, at its level.
    if n.level == 0 || !within eye n.x n.z n.size (q.rangeOf (n.level - 1)) q.relief
    then
      if out.size < maxNodes then out := out.push n
    else
      let half := n.size / 2
      for (dx, dz) in [(0, 0), (1, 0), (0, 1), (1, 1)] do
        stack := stack.push ⟨n.x + dx.toFloat * half, n.z + dz.toFloat * half,
                             half, n.level - 1⟩
  return out

end Reef
