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

end Reef
