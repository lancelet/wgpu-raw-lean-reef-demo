// A texture's next mip level from the one before it (`Reef/Ripples.lean`):
// each texel the mean of the four it covers, by one linear sample at
// their meeting point. WebGPU makes no mip levels itself.

@group(0) @binding(0) var source  : texture_2d<f32>;
@group(0) @binding(1) var between : sampler;

struct Out {
  @builtin(position) position : vec4f,
}

// One triangle over the whole target; the fragment's position says where.
@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  let xy = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
  var out : Out;
  out.position = vec4f(xy * 2.0 - 1.0, 0.0, 1.0);
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let size = vec2f(textureDimensions(source)) * 0.5;
  return textureSampleLevel(source, between, in.position.xy / size, 0.0);
}
