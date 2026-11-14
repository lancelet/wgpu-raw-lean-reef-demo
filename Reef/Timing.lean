import WebGPU.Raw

/-!
# How long the GPU takes

Timestamps at each pass's beginning and end, when the device can write
them (`timestamp-query`, which the adapter may lack: then there is no
timing, and the overlay says so). Each frame the timestamps are resolved
into a buffer and copied to one of a few the CPU can map; the copy is
mapped as the GPU finishes it, and read when it is, a frame or two on.
The frame's passes' times, in nanoseconds, are then the latest.
-/

open WebGPU.Raw

namespace Reef

/-- The timing, for `passes` passes a frame. -/
structure Timing where
  set     : QuerySet
  resolve : Buffer
  /-- The buffers the CPU maps, used in turn; and which are mapped, or
  being (wgpu-native cannot say). -/
  ring    : Array Buffer
  busy    : IO.Ref (Array Bool)
  passes  : Nat
  /-- The latest frame's passes' times, in nanoseconds, once there are
  any. -/
  latest  : IO.Ref (Option (Array Nat))

/-- Bytes the timestamps of a frame take: two 64-bit stamps a pass. -/
def Timing.size (passes : Nat) : UInt64 := (passes * 16).toUInt64

/-- Timing for `passes` passes a frame, if `device` can stamp time. -/
def Timing.create (device : Device) (can : Bool) (passes : Nat) :
    IO (Option Timing) := do
  unless can do return none
  let set ← device.createQuerySet {
    label := "timing", type := .timestamp, count := (2 * passes).toUInt32 }
  let size := Timing.size passes
  let some resolve ← device.createBuffer
      { label := "timing", size, usage := .queryResolve ||| .copySrc }
    | return none
  let mut ring := #[]
  for _ in [0:3] do
    let some buffer ← device.createBuffer
        { label := "timing readback", size, usage := .mapRead ||| .copyDst }
      | return none
    ring := ring.push buffer
  return some { set, resolve, ring, passes, latest := ← IO.mkRef none
                busy := ← IO.mkRef (Array.replicate ring.size false) }

/-- Where pass `i`'s stamps go. -/
def Timing.writes (t : Timing) (i : Nat) : PassTimestampWrites := {
  querySet                  := t.set
  beginningOfPassWriteIndex := (2 * i).toUInt32
  endOfPassWriteIndex       := (2 * i + 1).toUInt32
}

/-- Stamps written at the ends of `t`'s pass `i`, if there is timing. -/
def Timing.writesFor (t : Option Timing) (i : Nat) :
    Option PassTimestampWrites := t.map (·.writes i)

/-- A 64-bit little-endian number at `i` in `bytes`. -/
def readU64 (bytes : ByteArray) (i : Nat) : Nat := Id.run do
  let mut n := 0
  for j in [0:8] do
    n := n + (bytes[i + j]!.toNat <<< (8 * j))
  return n

/--
After the frame `n`'s passes, on `encoder`: resolve its stamps and copy
them to a ring buffer, if that buffer is free; then, after the submit,
`collect` maps it.
-/
def Timing.resolveInto (t : Timing) (encoder : CommandEncoder) (n : Nat) :
    IO Bool := do
  let i := n % t.ring.size
  let some buffer := t.ring[i]? | return false
  if (← t.busy.get).getD i true then return false
  encoder.resolveQuerySet t.set 0 (2 * t.passes).toUInt32 t.resolve 0
  encoder.copyBufferToBuffer t.resolve 0 buffer 0 (Timing.size t.passes)
  return true

/-- Map frame `n`'s copy; when it is mapped, read the passes' times. -/
def Timing.collect (t : Timing) (n : Nat) : IO Unit := do
  let i := n % t.ring.size
  let some buffer := t.ring[i]? | return
  let size := Timing.size t.passes
  t.busy.modify (·.set! i true)
  let _ ← buffer.mapAsync .read 0 size .allowSpontaneous fun status _ => do
    if status matches .ok .success then
      let bytes ← buffer.readMapped 0 size
      let mut times := #[]
      for j in [0:t.passes] do
        let begun := readU64 bytes (16 * j)
        let ended := readU64 bytes (16 * j + 8)
        times := times.push (if ended ≥ begun then ended - begun else 0)
      t.latest.set (some times)
      buffer.unmap
    t.busy.modify (·.set! i false)

end Reef
