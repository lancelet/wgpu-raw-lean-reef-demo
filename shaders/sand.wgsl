// The sand: the floor, a geometry clipmap (`Reef/Floor.lean`) placed around
// the camera by the vertex shader, flat for now (`height` is 0), lit by
// a sun from above, fading into the background with distance as the grid
// does.

struct Out {
  @builtin(position) position : vec4f,
  @location(0)       world    : vec3f,
  @location(7)       bary     : vec3f,  // the wireframe's (shaders/wire.wgsl)
}

// The floor's height at `xz`: flat, for now.
fn height(xz : vec2f) -> f32 {
  return 0.0;
}

// `x` to the lattice of `step`, below.
fn snap(x : vec2f, step : f32) -> vec2f {
  return floor(x / step) * step;
}

// A lattice vertex of level `level` (the instance): placed at the level's
// spacing around the camera, the level snapped to twice its spacing so that
// its vertices stay on one lattice as the camera moves.
@vertex fn vs(@location(0) lattice : vec2f,
              @builtin(vertex_index) index : u32,
              @builtin(instance_index) level : u32) -> Out {
  let spacing = frame.floor.x * exp2(f32(level));
  let center = snap(frame.camera.xz, 2.0 * spacing);
  let xz = center + lattice * spacing;
  var out : Out;
  out.world = vec3f(xz.x, height(xz), xz.y);
  out.position = frame.viewProj * vec4f(out.world, 1.0);
  out.bary = barycentric(index);
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let normal = vec3f(0.0, 1.0, 0.0);
  let sun = normalize(vec3f(0.3, 1.0, 0.2));
  let sand = vec3f(0.55, 0.47, 0.30);
  let light = 0.25 + 0.75 * max(dot(normal, sun), 0.0);
  let color = sand * light;
  let dist = length(in.world - frame.camera.xyz);
  let fade = visible(dist);
  return vec4f(mix(background, color, fade), 1.0);
}
