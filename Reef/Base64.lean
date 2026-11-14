/-!
# Base64

Decoding, as RFC 4648 (the standard alphabet, `=` padding, no line
breaks): how the build embeds binary files, the font, in Lean
(`Reef/Fonts.lean`), which has string literals and no byte-array ones.
-/

namespace Reef

/-- The six bits a base64 character stands for; none for any other. -/
def base64Digit (c : Char) : Option UInt32 :=
  if 'A' ≤ c && c ≤ 'Z' then some (c.toNat - 'A'.toNat).toUInt32
  else if 'a' ≤ c && c ≤ 'z' then some (c.toNat - 'a'.toNat + 26).toUInt32
  else if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat + 52).toUInt32
  else if c == '+' then some 62
  else if c == '/' then some 63
  else none

/-- The bytes `s` encodes in base64; characters that are no digit, `=`
among them, are skipped. -/
def base64Decode (s : String) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity (s.length * 3 / 4)
  let mut bits : UInt32 := 0
  let mut count := 0
  for c in s.toList do
    if let some d := base64Digit c then
      bits := (bits <<< 6) ||| d
      count := count + 6
      if count >= 8 then
        count := count - 8
        out := out.push ((bits >>> count.toUInt32) &&& 0xFF).toUInt8
  return out

end Reef
