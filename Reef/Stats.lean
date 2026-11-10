/-!
# How fast it draws

The frames counted, and the time each took to prepare (to record and submit
its commands, on the CPU), over half a second at a time; at the end of each,
a summary: frames a second, the time between them, and the preparation's,
on average and at worst.
-/

namespace Reef

/-- The frames since `since`, the last summary's end, in nanoseconds. -/
structure Stats where
  since  : Nat
  frames : Nat := 0
  /-- Their preparation, in all, in nanoseconds. -/
  busy   : Nat := 0
  /-- The longest of it. -/
  worst  : Nat := 0

/-- How long each summary is over, in nanoseconds: half a second. -/
def Stats.period : Nat := 500000000

/-- `x` with `places` decimal places. -/
def fixed (x : Float) (places : Nat) : String :=
  let scale := (10 : Float) ^ places.toFloat
  let n := (x * scale).round.toUInt64.toNat
  let whole := toString (n / 10 ^ places)
  if places == 0 then whole
  else
    let frac := toString (n % 10 ^ places)
    whole ++ "." ++ "".pushn '0' (places - frac.length) ++ frac

/-- `s`, spaces before it to make it `width` long. -/
def padLeft (s : String) (width : Nat) : String :=
  "".pushn ' ' (width - s.length) ++ s

/--
A frame, at `now`, prepared in `busy` nanoseconds: counted, and, if a period
has passed, the period's summary, and the stats begun again.
-/
def Stats.frame (s : Stats) (now busy : Nat) : Stats × Option String :=
  let s := { s with frames := s.frames + 1, busy := s.busy + busy,
                    worst := max s.worst busy }
  if now < s.since + Stats.period then (s, none)
  else
    let elapsed := (now - s.since).toFloat
    let frames := s.frames.toFloat
    let ms (ns : Float) := ns / 1e6
    let text :=
      s!"{padLeft (fixed (frames * 1e9 / elapsed) 1) 5} fps \
        {padLeft (fixed (ms (elapsed / frames)) 2) 6} ms\n\
        cpu {padLeft (fixed (ms (s.busy.toFloat / frames)) 2) 5} ms \
        max {padLeft (fixed (ms s.worst.toFloat) 2) 5}"
    ({ since := now }, some text)

end Reef
