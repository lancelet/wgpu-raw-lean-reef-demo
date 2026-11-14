// The frame, drawn in light (floats, as bright as the sun's disc), made
// colour for the display (`Reef/Render.lean`): a filmic curve (Narkowicz's
// fit of the ACES one) that rolls the brightest light off toward white
// rather than clipping it, at an exposure; the display's own encoding
// (sRGB) is the target's.

@group(1) @binding(0) var scene : texture_2d<f32>;

struct Out {
  @builtin(position) position : vec4f,
}

@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  let xy = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
  var out : Out;
  out.position = vec4f(xy * 2.0 - 1.0, 0.0, 1.0);
  return out;
}

fn filmic(x : vec3f) -> vec3f {
  let a = 2.51; let b = 0.03; let c = 2.43; let d = 0.59; let e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3f(0.0), vec3f(1.0));
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let light = textureLoad(scene, vec2i(in.position.xy), 0).rgb;
  return vec4f(filmic(light * frame.shaft.w), 1.0);
}
