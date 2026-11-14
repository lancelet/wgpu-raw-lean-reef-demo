// The grid: a square at the world's height 0, as far as the grid's extent, with a grid
// of lines on it, a line every spacing and a brighter one every major
// lines, the x and z axes in colour, fading with distance from the camera.
// Drawn as two triangles over the floor, the lines found in the fragment
// shader, a pixel wide whatever the distance, and blended over by their
// coverage: nothing but the lines shows.

struct Out {
  @builtin(position) position : vec4f,
  @location(0)       relative : vec3f,  // to the camera
}

// The square around the camera, at the world's height 0.
@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  var corners = array<vec2f, 6>(
    vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(-1.0, 1.0),
    vec2f(-1.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0));
  let c = corners[i] * frame.grid.z;
  var out : Out;
  out.relative = vec3f(c.x, -frame.camera.y, c.y);
  out.position = frame.viewProj * vec4f(out.relative, 1.0);
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
  let world = toWorld(in.relative);
  let p = world.xz / frame.grid.x;
  let minor = line(p);
  let major = line(p / frame.grid.y);
  let x = axis(world.z);
  let z = axis(world.x);
  var color = vec3f(0.22, 0.30, 0.38);
  color = mix(color, vec3f(0.45, 0.60, 0.70), major);
  // The axes: x in red, z in blue.
  color = mix(color, vec3f(0.9, 0.3, 0.3), x);
  color = mix(color, vec3f(0.3, 0.5, 1.0), z);
  let coverage = max(max(minor * 0.7, major), max(x, z));
  let fade = visible(length(in.relative));
  return vec4f(color, coverage * fade);
}
