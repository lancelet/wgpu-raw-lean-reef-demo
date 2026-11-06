// The ocean behind everything: a full-screen triangle, shaded from the
// lit water near the surface down to the dark of the deep, with shafts of
// light that sway, and a shimmer that drifts.

struct Frame {
  time   : f32,
  aspect : f32,  // width / height
  pad    : vec2f,
}

@group(0) @binding(0) var<uniform> frame : Frame;

struct Out {
  @builtin(position) position : vec4f,
  @location(0)       uv       : vec2f,  // 0..1, y up
}

// One triangle covering the screen: its corners at (-1,-1), (3,-1), (-1,3).
@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  let corner = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
  var out : Out;
  out.position = vec4f(corner * 2.0 - 1.0, 0.0, 1.0);
  out.uv = corner;
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let t = frame.time;
  let depth = 1.0 - in.uv.y;
  // From the surface's teal to the deep's near black.
  let shallow = vec3f(0.012, 0.11, 0.16);
  let deep = vec3f(0.0, 0.002, 0.008);
  var color = mix(shallow, deep, pow(depth, 0.6));
  // Shafts of light from above, swaying, fading with depth.
  let x = in.uv.x * frame.aspect;
  let shafts = 0.5 + 0.5 * sin(x * 7.0 + sin(t * 0.3) * 1.5 + in.uv.y * 2.0)
             * sin(x * 3.1 - t * 0.17);
  color += vec3f(0.04, 0.10, 0.10) * pow(shafts, 6.0) * (1.0 - depth);
  // A shimmer near the surface.
  let shimmer = sin(x * 40.0 + t * 1.3) * sin(in.uv.y * 55.0 - t * 0.9);
  color += vec3f(0.01, 0.025, 0.025) * shimmer * smoothstep(0.7, 1.0, in.uv.y);
  return vec4f(color, 1.0);
}
