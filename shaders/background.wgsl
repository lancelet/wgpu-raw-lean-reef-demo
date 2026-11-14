// The water behind everything: one triangle over the whole target,
// each pixel the water's colour along its own direction (`water`, in
// shaders/frame.wgsl), drawn first, under the floor, where nothing else
// is. For the time being the surface is not drawn: looking up shows the
// water brightening toward it.

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
  let ndc = (in.position.xy / frame.screen.xy) * 2.0 - 1.0;
  let dir = normalize(frame.forward.xyz + frame.right.xyz * (ndc.x * frame.right.w)
                      - frame.up.xyz * (ndc.y * frame.up.w));
  return vec4f(water(dir), 1.0);
}
