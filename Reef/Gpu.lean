import WebGPU.Raw

/-!
# Help with the GPU

Requesting an adapter and a device, each in the last one's callback (as a
browser requires: `main` returns before they come), and making buffers and
shader modules, failing with an error rather than an `Option`.
-/

open WebGPU.Raw

namespace Reef

/--
Request an adapter, then a device on it, with timestamps if the adapter
can write them (`k` is told), then go on with `k`: natively, during this
call; in a browser, after `main` has returned.
-/
def withDevice (k : Instance → Adapter → Device → Bool → IO Unit) : IO Unit := do
  let wgpu ← createInstance none
  let _ ← wgpu.requestAdapter none .allowSpontaneous fun _ adapter message => do
    let some adapter := adapter
      | throw (IO.userError s!"no adapter: {message}")
    let timestamps ← adapter.hasFeature .timestampQuery
    let features := if timestamps then #[FeatureName.timestampQuery] else #[]
    let _ ← adapter.requestDevice (some { requiredFeatures := features })
      .allowSpontaneous fun _ device message => do
        let some device := device
          | throw (IO.userError s!"no device: {message}")
        k wgpu adapter device timestamps

/-- `bytes`, then `x`'s 32 bits as a float, little-endian, as WGSL's `f32`. -/
def pushF32 (bytes : ByteArray) (x : Float) : ByteArray :=
  let bits := x.toFloat32.toBits
  bytes |>.push bits.toUInt8 |>.push (bits >>> 8).toUInt8
    |>.push (bits >>> 16).toUInt8 |>.push (bits >>> 24).toUInt8

/-- A buffer of `usage` (and `copyDst`), holding `data`. -/
def createBuffer (device : Device) (label : String) (usage : BufferUsage)
    (data : ByteArray) : IO Buffer := do
  let some buffer ← device.createBuffer {
    label := label
    usage := usage ||| .copyDst
    size  := data.size.toUInt64
  } | throw (IO.userError s!"no buffer for {label}")
  (← device.getQueue).writeBuffer buffer 0 data
  return buffer

/-- A shader module of the WGSL `code`. -/
def createShader (device : Device) (label code : String) :
    IO ShaderModule :=
  device.createShaderModule {
    label := label
    chain := #[.shaderSourceWGSL { code := code }]
  }

end Reef
