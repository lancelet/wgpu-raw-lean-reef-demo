// A texture blurred a little, in one direction at a time (`Reef/Caustics.lean`):
// the caustics, by the sun's own width, which no point of the surface
// can focus finer than. Five taps, a Gaussian about a texel wide; the
// texture repeating, as the tile does.

@group(0) @binding(0) var source : texture_2d<f32>;
@group(0) @binding(1) var wrap : sampler;

struct Out {
  @builtin(position) position : vec4f,
}

@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  let xy = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
  var out : Out;
  out.position = vec4f(xy * 2.0 - 1.0, 0.0, 1.0);
  return out;
}

fn blurred(uv : vec2f, step : vec2f) -> vec4f {
  return textureSampleLevel(source, wrap, uv, 0.0) * 0.4
    + (textureSampleLevel(source, wrap, uv + step, 0.0)
       + textureSampleLevel(source, wrap, uv - step, 0.0)) * 0.24
    + (textureSampleLevel(source, wrap, uv + 2.0 * step, 0.0)
       + textureSampleLevel(source, wrap, uv - 2.0 * step, 0.0)) * 0.06;
}

@fragment fn fs_x(in : Out) -> @location(0) vec4f {
  let size = vec2f(textureDimensions(source));
  return blurred(in.position.xy / size, vec2f(1.5 / size.x, 0.0));
}

@fragment fn fs_y(in : Out) -> @location(0) vec4f {
  let size = vec2f(textureDimensions(source));
  return blurred(in.position.xy / size, vec2f(0.0, 1.5 / size.y));
}
