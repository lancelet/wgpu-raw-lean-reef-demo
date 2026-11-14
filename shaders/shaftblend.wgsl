// The light in the water, drawn at half the target's size
// (`shaders/shafts.wgsl`), added over the scene at full size: each
// pixel the mean of the twenty-five half-size pixels about it, which
// smooths the march's grain away and softens the rays
// (`Reef/Render.lean`).

@group(1) @binding(0) var shaftLight : texture_2d<f32>;
@group(1) @binding(1) var shaftSampler : sampler;

struct Out {
  @builtin(position) position : vec4f,
}

@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  let xy = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
  var out : Out;
  out.position = vec4f(xy * 2.0 - 1.0, 0.0, 1.0);
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let size = vec2f(textureDimensions(shaftLight));
  let uv = in.position.xy / frame.screen.xy;
  let texel = 1.0 / size;
  var sum = vec3f(0.0);
  for (var j = -2; j <= 2; j++) {
    for (var i = -2; i <= 2; i++) {
      sum += textureSampleLevel(shaftLight, shaftSampler, uv + vec2f(f32(i), f32(j)) * texel, 0.0).rgb;
    }
  }
  return vec4f(sum / 25.0, 1.0);
}
