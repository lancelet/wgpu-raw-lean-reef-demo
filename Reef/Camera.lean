import Reef.Math

/-!
# The camera

Where it is, and which way it looks: a yaw (about the vertical) and a pitch,
in radians, and the distance to the point it is looking at, its target,
which orbiting goes around. Orbiting, panning and dollying about the
target, as a modelling program's viewport does; and the camera itself
moved, its target with it, and turned in place.
-/

namespace Reef

structure Camera where
  position : Vec3
  /-- About the vertical: 0 looks down negative `z`; positive turns left. -/
  yaw      : Float
  /-- Up from level; limited short of straight up and down. -/
  pitch    : Float
  /-- To the target, along the look direction. -/
  distance : Float
  deriving Repr, Inhabited

namespace Camera

/-- As high as the pitch goes, either way: just short of a right angle. -/
def pitchLimit : Float := 1.55

/-- As close as the target comes. -/
def nearest : Float := 0.05

def forward (c : Camera) : Vec3 :=
  ⟨-c.yaw.sin * c.pitch.cos, c.pitch.sin, -c.yaw.cos * c.pitch.cos⟩

def right (c : Camera) : Vec3 := ⟨c.yaw.cos, 0, -c.yaw.sin⟩

def up (c : Camera) : Vec3 := c.right.cross c.forward

/-- The point it looks at, and orbits. -/
def target (c : Camera) : Vec3 := c.position + c.distance * c.forward

def view (c : Camera) : Mat4 := Mat4.view c.position c.right c.up (-c.forward)

/-- Turned by `dYaw` and `dPitch`, in place. -/
def turn (c : Camera) (dYaw dPitch : Float) : Camera :=
  { c with yaw := c.yaw + dYaw
           pitch := min pitchLimit (max (-pitchLimit) (c.pitch + dPitch)) }

/-- Turned by `dYaw` and `dPitch` about the target, keeping its distance. -/
def orbit (c : Camera) (dYaw dPitch : Float) : Camera :=
  let t := c.target
  let turned := c.turn dYaw dPitch
  { turned with position := t - c.distance * turned.forward }

/-- Moved `dx` right and `dy` up, in units of the target's distance. -/
def pan (c : Camera) (dx dy : Float) : Camera :=
  { c with position := c.position + (dx * c.distance) * c.right
                                  + (dy * c.distance) * c.up }

/-- Toward the target, or away: its distance scaled by `e ^ -amount`. -/
def dolly (c : Camera) (amount : Float) : Camera :=
  let t := c.target
  let d := max nearest (c.distance * (-amount).exp)
  { c with distance := d, position := t - d * c.forward }

/-- Moved by `v`, in its own axes: right, up, forward; its target too. -/
def fly (c : Camera) (v : Vec3) : Camera :=
  { c with position := c.position + v.x * c.right + v.y * c.up
                                  + v.z * c.forward }

/-- Where it starts: back from the origin, a little up, looking down at it. -/
def initial : Camera :=
  { position := ⟨0, 2, 8⟩, yaw := 0, pitch := -0.24, distance := 8.2 }

end Camera

end Reef
