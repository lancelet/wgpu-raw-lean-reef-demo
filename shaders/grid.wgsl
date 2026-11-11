// The floor: a square at height 0, as far as the grid's extent, with a grid
// of lines on it, a line every spacing and a brighter one every major
// lines, the x and z axes in colour, fading into the background with
// distance from the camera. Drawn as two triangles; the lines are found in
// the fragment shader, a pixel wide whatever the distance.

// As `Reef.frameBytes` encodes it: 96 bytes.
struct Frame {
  viewProj : mat4x4f,
  camera   : vec4f,  // where the camera is; w unused
  grid     : vec4f,  // spacing, major, extent, fade
}

@group(0) @binding(0) var<uniform> frame : Frame;

struct Out {
  @builtin(position) position : vec4f,
  @location(0)       world    : vec3f,
}

@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  var corners = array<vec2f, 6>(
    vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(-1.0, 1.0),
    vec2f(-1.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0));
  let c = corners[i] * frame.grid.z;
  var out : Out;
  out.world = vec3f(c.x, 0.0, c.y);
  out.position = frame.viewProj * vec4f(out.world, 1.0);
  return out;
}

// How much of a line a pixel at `p` (in units of the lines' spacing) is:
// 1 on a line, 0 off it, smoothed over a pixel either way.
fn line(p : vec2f) -> f32 {
  let d = fwidth(p);
  let g = abs(fract(p - 0.5) - 0.5) / max(d, vec2f(1e-5));
  return 1.0 - min(min(g.x, g.y), 1.0);
}

// How much of an axis line a pixel is, at `x` units from it.
fn axis(x : f32) -> f32 {
  let d = fwidth(x);
  return 1.0 - min(abs(x) / max(d, 1e-5) * 0.7, 1.0);
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let p = in.world.xz / frame.grid.x;
  let minor = line(p);
  let major = line(p / frame.grid.y);
  let background = vec3f(0.02, 0.05, 0.09);
  var color = vec3f(0.05, 0.08, 0.11);
  color = mix(color, vec3f(0.22, 0.30, 0.38), minor * 0.7);
  color = mix(color, vec3f(0.45, 0.60, 0.70), major);
  // The axes: x in red, z in blue.
  color = mix(color, vec3f(0.9, 0.3, 0.3), axis(in.world.z));
  color = mix(color, vec3f(0.3, 0.5, 1.0), axis(in.world.x));
  let dist = length(in.world - frame.camera.xyz);
  let fade = exp(-dist / frame.grid.w);
  return vec4f(mix(background, color, fade), 1.0);
}
