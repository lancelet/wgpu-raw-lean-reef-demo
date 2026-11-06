import Reef.Gpu

/-!
# The scene

What is drawn, as data the shaders read: the frame's time and shape, and the
glowing creatures, each where it drifts, how big, at what phase of its pulse,
and in what color. The creatures are scattered by a fixed sequence of
pseudo-random numbers, so every run draws the same reef.
-/

namespace Reef

/-- One glowing creature, as `shaders/glow.wgsl` reads it. -/
structure Creature where
  /-- Across, a fraction of the width. -/
  x      : Float
  /-- Up, a fraction of the height. -/
  y      : Float
  /-- Its glow's radius, a fraction of the height. -/
  radius : Float
  /-- Where in its bobbing and pulsing it starts, in radians. -/
  phase  : Float
  r      : Float
  g      : Float
  b      : Float
  /-- How bright it is. -/
  a      : Float

/-- `bytes`, then `c` as WGSL lays out its `Creature`: 32 bytes. -/
def Creature.encode (bytes : ByteArray) (c : Creature) : ByteArray :=
  [c.x, c.y, c.radius, c.phase, c.r, c.g, c.b, c.a].foldl
    pushF32 bytes

/-- The frame's uniforms, as WGSL lays out its `Frame`: 16 bytes. -/
def frameBytes (time aspect : Float) : ByteArray :=
  [time, aspect, 0, 0].foldl pushF32 ByteArray.empty

/--
A pseudo-random number generator: the state after `s` (a linear
congruential generator, as Numerical Recipes gives).
-/
def nextState (s : UInt32) : UInt32 := s * 1664525 + 1013904223

/-- The number in [0, 1) the state `s` gives. -/
def unit (s : UInt32) : Float := s.toFloat / 4294967296.0

/-- The colors creatures glow in: cyan, teal, violet, and a pale green. -/
def palette : Array (Float × Float × Float) :=
  #[(0.2, 0.9, 1.0), (0.1, 1.0, 0.7), (0.7, 0.4, 1.0), (0.6, 1.0, 0.5)]

/-- `n` creatures, scattered from the seed `seed`. -/
def creatures (n : Nat) (seed : UInt32 := 2026) : Array Creature := Id.run do
  let mut s := seed
  let mut out := #[]
  for _ in [0:n] do
    let mut u := #[]
    for _ in [0:6] do
      s := nextState s
      u := u.push (unit s)
    let (r, g, b) := palette[(u[5]! * palette.size.toFloat).toUInt32.toNat]!
    -- Smaller and dimmer further down, as if further away.
    let y := 0.05 + 0.9 * u[1]!
    out := out.push {
      x      := u[0]!
      y      := y
      radius := 0.02 + 0.06 * u[2]! * (0.5 + 0.5 * y)
      phase  := 6.2832 * u[3]!
      r, g, b
      a      := 0.5 + 0.5 * u[4]!
    }
  return out

end Reef
