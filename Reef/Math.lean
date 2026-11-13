/-!
# Vectors and matrices

Three-vectors, and 4 by 4 matrices of floats as WGSL lays them out (column
by column), with the two the camera needs: a perspective projection, for
WebGPU's clip space (depth 0 to 1), and a view, from where the camera is
and which way it looks.
-/

namespace Reef

/-- A vector in three dimensions: `y` is up. -/
structure Vec3 where
  x : Float
  y : Float
  z : Float
  deriving Repr, Inhabited, BEq

namespace Vec3

def zero : Vec3 := ⟨0, 0, 0⟩

instance : Add Vec3 := ⟨fun a b => ⟨a.x + b.x, a.y + b.y, a.z + b.z⟩⟩
instance : Sub Vec3 := ⟨fun a b => ⟨a.x - b.x, a.y - b.y, a.z - b.z⟩⟩
instance : Neg Vec3 := ⟨fun a => ⟨-a.x, -a.y, -a.z⟩⟩
instance : HMul Float Vec3 Vec3 := ⟨fun s v => ⟨s * v.x, s * v.y, s * v.z⟩⟩

def dot (a b : Vec3) : Float := a.x * b.x + a.y * b.y + a.z * b.z

def cross (a b : Vec3) : Vec3 :=
  ⟨a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x⟩

def length (a : Vec3) : Float := (dot a a).sqrt

/-- `a` at length 1; zero stays zero. -/
def normalize (a : Vec3) : Vec3 :=
  let l := a.length
  if l > 0 then (1 / l) * a else zero

end Vec3

/-- A 4 by 4 matrix: 16 floats, column by column, as WGSL's `mat4x4f`. -/
structure Mat4 where
  m : Array Float
  deriving Repr, Inhabited

namespace Mat4

/-- The entry in `row`, `col`. -/
def entry (a : Mat4) (row col : Nat) : Float := a.m.getD (col * 4 + row) 0

def identity : Mat4 := ⟨#[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]⟩

/-- `a` then `b`: the product `a * b`, applied to a column vector right first. -/
def mul (a b : Mat4) : Mat4 := Id.run do
  let mut out := Array.replicate 16 (0 : Float)
  for col in [0:4] do
    for row in [0:4] do
      let mut s := 0
      for k in [0:4] do
        s := s + a.entry row k * b.entry k col
      out := out.set! (col * 4 + row) s
  return ⟨out⟩

instance : Mul Mat4 := ⟨mul⟩

/--
A perspective projection: `fovY` radians tall, `aspect` wide for high, the
depths `near` to `far` to 0 to 1, as WebGPU's clip space has them; the
camera looks down its negative `z`.
-/
def perspective (fovY aspect near far : Float) : Mat4 :=
  let f := 1 / (fovY / 2).tan
  ⟨#[f / aspect, 0, 0, 0,
     0, f, 0, 0,
     0, 0, far / (near - far), -1,
     0, 0, near * far / (near - far), 0]⟩

/--
A view from `eye` with the axes `right`, `up` and `back` (unit, at right
angles: the camera looks down `back`'s negative): world to camera.
-/
def view (eye right up back : Vec3) : Mat4 :=
  ⟨#[right.x, up.x, back.x, 0,
     right.y, up.y, back.y, 0,
     right.z, up.z, back.z, 0,
     -(right.dot eye), -(up.dot eye), -(back.dot eye), 1]⟩

end Mat4

/-- A plane, `normal · p + offset ≥ 0` on its inside. -/
structure Plane where
  normal : Vec3
  offset : Float
  deriving Repr, Inhabited

/-- The view frustum, as its six planes, insides inward. -/
structure Frustum where
  planes : Array Plane
  deriving Repr, Inhabited

namespace Frustum

/-- The frustum of `viewProj`, for WebGPU's clip space (depth 0 to 1): the
matrix's rows added to and taken from its last. -/
def ofMatrix (m : Mat4) : Frustum :=
  let row (i : Nat) : Array Float := #[m.entry i 0, m.entry i 1, m.entry i 2, m.entry i 3]
  let plane (r : Array Float) : Plane :=
    let n : Vec3 := ⟨r[0]!, r[1]!, r[2]!⟩
    let l := n.length
    { normal := (1 / l) * n, offset := r[3]! / l }
  let add (a b : Array Float) := (Array.range 4).map fun i => a[i]! + b[i]!
  let sub (a b : Array Float) := (Array.range 4).map fun i => a[i]! - b[i]!
  let last := row 3
  ⟨#[plane (add last (row 0)), plane (sub last (row 0)),
     plane (add last (row 1)), plane (sub last (row 1)),
     plane (row 2), plane (sub last (row 2))]⟩

/-- Whether the box from `lo` to `hi` is inside, or crosses, the frustum. -/
def intersectsBox (f : Frustum) (lo hi : Vec3) : Bool :=
  f.planes.all fun p =>
    -- The box's corner furthest along the normal: outside if even it is.
    let corner : Vec3 := ⟨if p.normal.x ≥ 0 then hi.x else lo.x,
                          if p.normal.y ≥ 0 then hi.y else lo.y,
                          if p.normal.z ≥ 0 then hi.z else lo.z⟩
    p.normal.dot corner + p.offset ≥ 0

end Frustum

end Reef
