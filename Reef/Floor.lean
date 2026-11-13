import Reef.Gpu

/-!
# The floor's mesh: a geometry clipmap

The floor is drawn as nested square rings of grid around the camera, each
ring with twice the vertex spacing of the one inside it (Losasso and Hoppe,
"Geometry Clipmaps", 2004): as many vertices near the camera as far from
it, and a constant count whatever the view. One lattice of vertices serves
every level; the vertex shader (`shaders/sand.wgsl`) places it at the
level's spacing around the camera, snapped to the level's own lattice so
that nothing swims as the camera moves, and lifts it to the floor's height.

A level's lattice has `n` cells a side, `n + 1` vertices. The innermost
level draws all of it; each level outside draws it with a hole of `n / 2`
cells a side where the level inside sits. That level is snapped to a finer
lattice, so the hole is offset by 0 or 1 cell in each axis: four index
buffers, one for each offset, chosen each frame.

For the wireframe, each index buffer has a companion: its triangles with
no indices, every corner its own vertex, so that each can say which corner
it is (`shaders/wire.wgsl`), drawn with the same vertex shader
(`Reef/Render.lean`).
-/

open WebGPU.Raw

namespace Reef

/-- `bytes`, then `x` as 32 bits, little-endian, as WGSL's `u32`. -/
def pushU32 (bytes : ByteArray) (x : UInt32) : ByteArray :=
  bytes |>.push x.toUInt8 |>.push (x >>> 8).toUInt8
    |>.push (x >>> 16).toUInt8 |>.push (x >>> 24).toUInt8

/-- The indices of a triangle list. -/
structure Indices where
  triangles : Array UInt32

/-- `is` as little-endian bytes. -/
def Indices.bytes (is : Array UInt32) : ByteArray := is.foldl pushU32 ByteArray.empty

/-- The triangles' vertices with no indices, each corner its own, from the
vertices `vertices`, `stride` bytes each. -/
def Indices.expanded (is : Array UInt32) (vertices : ByteArray) (stride : Nat) :
    ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity (is.size * stride)
  for i in is do
    out := out ++ vertices.extract (i.toNat * stride) ((i.toNat + 1) * stride)
  return out

/--
The lattice's vertices, `n + 1` a side, as pairs of floats: the lattice
coordinates, `-n / 2` to `n / 2`, row by row (the second coordinate the
slower). Vertex `(i, j)` is at index `j * (n + 1) + i`.
-/
def latticeVertices (n : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.empty
  for j in [0:n + 1] do
    for i in [0:n + 1] do
      out := pushF32 (pushF32 out (i.toFloat - n.toFloat / 2))
        (j.toFloat - n.toFloat / 2)
  return out

/--
The lattice's triangles, two a cell, leaving out the cells of the hole if
`hole` says where it is: `some (dx, dy)` for the `n / 2` by `n / 2` cells
from cell `(n / 4 + dx, n / 4 + dy)`; `none` for no hole, the innermost
level.
-/
def latticeIndices (n : Nat) (hole : Option (Nat × Nat)) : Indices := Id.run do
  let vertex (i j : Nat) : UInt32 := (j * (n + 1) + i).toUInt32
  let inHole (i j : Nat) : Bool := match hole with
    | some (dx, dy) =>
      n / 4 + dx ≤ i && i < 3 * n / 4 + dx && n / 4 + dy ≤ j && j < 3 * n / 4 + dy
    | none => false
  let mut triangles := #[]
  for j in [0:n] do
    for i in [0:n] do
      unless inHole i j do
        triangles := triangles
          |>.push (vertex i j) |>.push (vertex (i + 1) j) |>.push (vertex i (j + 1))
          |>.push (vertex (i + 1) j) |>.push (vertex (i + 1) (j + 1))
          |>.push (vertex i (j + 1))
  return { triangles }

/-- One level's buffers on the GPU: its triangles' indices, and the same
triangles with no indices, for the wireframe. -/
structure LevelMesh where
  triangles     : Buffer
  triangleCount : UInt32
  wire          : Buffer
  wireCount     : UInt32

/-- `indices` as buffers on `device`, the wireframe's from `vertices`. -/
def LevelMesh.create (device : Device) (label : String) (indices : Indices)
    (vertices : ByteArray) : IO LevelMesh := do
  return {
    triangles     := ← createBuffer device s!"{label} triangles" .index
      (Indices.bytes indices.triangles)
    triangleCount := indices.triangles.size.toUInt32
    wire          := ← createBuffer device s!"{label} wire" .vertex
      (Indices.expanded indices.triangles vertices 8)
    wireCount     := indices.triangles.size.toUInt32
  }

/-- The floor's mesh: the lattice, and the index buffers each level uses. -/
structure FloorMesh where
  /-- Cells a side of a level. -/
  n        : Nat
  vertices : Buffer
  /-- The innermost level's, with no hole. -/
  full     : LevelMesh
  /-- The other levels', by the hole's offset: `(dx, dy)` at `dy * 2 + dx`. -/
  rings    : Array LevelMesh

/-- The floor's mesh, `n` cells a side a level (`n` a multiple of 4). -/
def FloorMesh.create (device : Device) (n : Nat) : IO FloorMesh := do
  let lattice := latticeVertices n
  let mut rings := #[]
  for dy in [0:2] do
    for dx in [0:2] do
      rings := rings.push (← LevelMesh.create device s!"ring {dx} {dy}"
        (latticeIndices n (some (dx, dy))) lattice)
  return {
    n, rings
    vertices := ← createBuffer device "lattice" .vertex lattice
    full     := ← LevelMesh.create device "full" (latticeIndices n none) lattice
  }

/--
The hole's offset in level `level`'s lattice, in cells, for the level inside
it: 0 or 1 in each axis. Level `l`'s lattice, spaced `s * 2 ^ l`, is snapped
to twice that (as `shaders/sand.wgsl` snaps it), so the level inside is
offset from this one by 0 or one cell.
-/
def holeOffset (s : Float) (level : Nat) (cx cz : Float) : Nat × Nat :=
  let spacing := s * (2 : Float) ^ level.toFloat
  let snap (x : Float) (step : Float) : Float := (x / step).floor * step
  let dx := (snap cx spacing - snap cx (2 * spacing)) / spacing
  let dz := (snap cz spacing - snap cz (2 * spacing)) / spacing
  ((dx + 0.5).floor.toUInt32.toNat, (dz + 0.5).floor.toUInt32.toNat)

end Reef
