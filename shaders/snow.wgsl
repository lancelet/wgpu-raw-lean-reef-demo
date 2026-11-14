// The marine snow (`Reef/Snow.lean`): the fine matter every sea holds,
// flecks of a millimetre or less, drifting. Some tens of thousands about
// the camera, each stepped in compute every frame (a thread a fleck):
// swayed by the surge, sinking a millimetre a second, wandering; kept in
// a box about the camera, wrapping round it, so the water is as full
// wherever the camera goes. Drawn as quads facing the camera, each lit
// at its own place, in its vertex shader, as the sand is: by the sky,
// and by the sun through the caustics' loop where the sun's ray through
// it meets the surface (so a fleck brightens as a bright filament passes
// over it, and the flecks under a caustic make its shaft), through the
// clouds and the litter's shadows, the water taking the light on its way
// down; scattered forward, so that the flecks glow toward the sun. Close
// to the camera, out of focus: wider and fainter.

struct Mote {
  // Where, in the world; its radius, in metres (0 not yet placed).
  position : vec3f,
  radius   : f32,
  // Its phase, for its wandering; the half-width of its shell's box, in
  // metres; its tint, 0 to 1; unused.
  phase    : f32,
  shell    : f32,
  tint     : f32,
  pad2     : f32,
}

struct Pool {
  // How many flecks; the step, in seconds; the box's half-width about the
  // camera, in metres; the moment, in seconds.
  count : f32,
  dt    : f32,
  reach : f32,
  time  : f32,
}

// Writable for the step, read only for the draw (the vertex stage may
// not see a writable buffer): `Reef/Snow.lean` builds the shader twice,
// the step's copy without the draw, the draw's without the step and
// with this made `read`.
@group(1) @binding(0) var<storage, read_write> motes : array<Mote>;
@group(1) @binding(1) var<uniform> pool : Pool;

// A number in [0, 1) from `seed`, the `n`th of its sequence.
fn rand(seed : u32, n : u32) -> f32 {
  var h = seed * 0x9e3779b9u + n * 0x85ebca6bu;
  h = h ^ (h >> 16u);
  h = h * 0x7feb352du;
  h = h ^ (h >> 15u);
  h = h * 0x846ca68bu;
  h = h ^ (h >> 16u);
  return f32(h & 0xffffffu) / 16777216.0;
}

// STEP
// A fleck placed. In one of three shells about the camera, each its own
// box that wraps round it: the near, a quarter of the reach, holds half
// the flecks, small; the middle, half the reach, a third, middling; the
// far, the whole reach, the rest, larger. So the flecks are thick where
// the eye can see them small and thin where only the bigger show. Its
// size spread wide (the log of it), a few flakes of a few millimetres;
// its tint its own.
fn placed(i : u32) -> Mote {
  let seed = i * 0x27d4eb2fu + 0x165667b1u;
  var m : Mote;
  let which = rand(seed, 6u);
  var shell = pool.reach;
  var scale = 1.6;
  if (which < 0.5) { shell = pool.reach * 0.25; scale = 0.6; }
  else if (which < 0.83) { shell = pool.reach * 0.5; scale = 1.0; }
  let xz = frame.camera.xz + (vec2f(rand(seed, 0u), rand(seed, 1u)) - 0.5) * 2.0 * shell;
  let lowest = max(frame.camera.y - shell, 0.0);
  let highest = min(frame.camera.y + shell, frame.water.x - 0.03);
  m.position = vec3f(xz.x, mix(lowest, highest, rand(seed, 2u)), xz.y);
  let spread = exp((rand(seed, 3u) + rand(seed, 7u) - 1.0) * 2.2);
  let flake = select(1.0, 4.0, rand(seed, 8u) < 0.02);
  m.radius = 0.0003 * scale * spread * flake;
  m.phase = rand(seed, 4u) * 6.2832;
  m.shell = shell;
  m.tint = rand(seed, 5u);
  return m;
}

@compute @workgroup_size(64)
fn step(@builtin(global_invocation_id) id : vec3u) {
  let i = id.x;
  if (f32(i) >= pool.count) { return; }
  var m = motes[i];
  if (m.radius <= 0.0) { m = placed(i); }
  let t = pool.time;
  let dt = pool.dt;
  // The surge, a little less near the floor; a slow sinking; a
  // wandering, each its own.
  let surge = surgeAt(m.position.xz, t) * (0.7 + 0.3 * m.position.y / frame.water.x);
  let wander = vec3f(sin(t * 0.7 + m.phase), sin(t * 0.43 + m.phase * 2.1) * 0.5,
                     cos(t * 0.61 + m.phase * 1.3)) * 0.004;
  m.position += (vec3f(surge.x, -0.001, surge.y) + wander) * dt;
  // Kept in its shell's box about the camera, wrapping round it; and
  // between the floor's zero and the surface, wrapping too.
  let reach = m.shell;
  var rel = m.position.xz - frame.camera.xz;
  rel = rel - 2.0 * reach * round(rel / (2.0 * reach));
  m.position = vec3f(frame.camera.x + rel.x, m.position.y, frame.camera.z + rel.y);
  let top = frame.water.x - 0.03;
  if (m.position.y < 0.0) { m.position.y += top; }
  if (m.position.y > top) { m.position.y -= top; }
  motes[i] = m;
}
// END

// DRAW
struct Out {
  @builtin(position) position : vec4f,
  @location(0) uv       : vec2f,
  @location(1) relative : vec3f,
  @location(2) colour   : vec3f,
  @location(3) alpha    : f32,
}

// Henyey and Greenstein's phase: how much light going one way is
// scattered to another at `cosine` between them, `g` the asymmetry.
fn scattered(cosine : f32, g : f32) -> f32 {
  let d = 1.0 + g * g - 2.0 * g * cosine;
  return (1.0 - g * g) / (4.0 * 3.14159265 * d * sqrt(d));
}

@vertex fn vs(@builtin(vertex_index) v : u32,
              @builtin(instance_index) instance : u32) -> Out {
  let m = motes[instance];
  let corner = vec2f(f32((v << 1u) & 2u), f32(v & 2u)) - 1.0;  // -1 or 1
  let relative = m.position - frame.camera.xyz;
  let dist = max(length(relative), 1e-3);
  let view = relative / dist;
  // Out of focus close to the camera: a disc up to a centimetre wide.
  let blur = smoothstep(0.6, 0.08, dist) * 0.008;
  let size = m.radius + blur;
  // Never under a pixel and a half; fainter by as much as it is drawn
  // bigger than it is.
  let least = dist * frame.camera.w * 1.5;
  let drawn = max(size, least);
  let coverage = (m.radius * m.radius) / (drawn * drawn);
  let world = relative + (frame.right.xyz * corner.x + frame.up.xyz * corner.y) * drawn;
  // The light at the fleck: the sun's, through the caustics where its ray
  // meets the surface (as the sand finds it, shaders/sand.wgsl), the
  // swell's drift and bending, the clouds and the litter; taken by the
  // water on its way down; scattered toward the eye, forward most.
  let p = m.position;
  let sun = frame.sun.xyz;
  let t = frame.screen.z;
  let toSurface = max(frame.water.x - p.y, 0.0) / max(sun.y, 0.1);
  var onSurface = p.xz + sun.xz * toSurface;
  let floating = debrisAt(onSurface, swellDriftAt(onSurface, t), t, 0.004 + toSurface * 0.0093).x;
  let bending = swellBending(onSurface, t, toSurface);
  onSurface -= swellDriftAt(onSurface, t) + bending.xy;
  let moments = frame.caustic.z;
  let moment = fract(t / frame.caustic.y) * moments;
  let layer = i32(floor(moment));
  let next = (layer + 1) % i32(moments);
  let uv = onSurface / frame.caustic.x;
  let gathered = mix(textureSampleLevel(caustics, rippleSampler, uv, layer, 1.0).rgb,
                     textureSampleLevel(caustics, rippleSampler, uv, next, 1.0).rgb,
                     fract(moment)) * causticBrightest;
  let focus = mix(vec3f(1.0), gathered, frame.water.y) * bending.z;
  let down = exp(-frame.extinct.rgb * toSurface);
  let shade = cloudShade(p, t) * (1.0 - 0.85 * floating);
  let toward = scattered(dot(sun, -view), 0.6) * 4.0 * 3.14159265;
  let sunlit = frame.sunlight.rgb * focus * down * shade * (0.3 + toward);
  // Its own colour: most a pale grey, some the brown of detritus, some
  // the green of plankton, a few white (shell, or a crystal).
  var albedo = vec3f(0.9, 0.9, 0.86);
  if (m.tint < 0.25) { albedo = vec3f(0.85, 0.7, 0.5); }
  else if (m.tint < 0.4) { albedo = vec3f(0.62, 0.82, 0.55); }
  else if (m.tint > 0.93) { albedo = vec3f(1.1, 1.1, 1.1); }
  let light = (frame.skylight.rgb * 0.9 + sunlit * 1.3) * albedo;
  // Fading at the box's sides, where it wraps; and toward the near plane.
  let rel = abs(p.xz - frame.camera.xz);
  let edge = 1.0 - smoothstep(0.75 * m.shell, m.shell, max(rel.x, rel.y));
  // In drifts: thicker in some water than in other, a metre or two across.
  let drifts = 0.35 + 0.65 * smoothstep(-0.35, 0.45,
    noise(p.xz / 1.4 + vec2f(p.y * 0.8, -p.y * 0.5) + 31.0));
  var out : Out;
  out.position = frame.viewProj * vec4f(world, 1.0);
  out.uv = corner;
  out.relative = relative;
  out.colour = light;
  // Fainter the farther: what is far is many flecks to a pixel's
  // sight of the water, not a point.
  out.alpha = clamp(coverage * 1.5, 0.08, 1.0) * edge * smoothstep(0.05, 0.12, dist)
    * (1.0 - 0.5 * smoothstep(1.5, 6.0, dist)) * drifts;
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let r = length(in.uv);
  if (r > 1.0) { discard; }
  let a = (1.0 - smoothstep(0.35, 1.0, r)) * in.alpha;
  return vec4f(fogged(in.colour, in.relative) * a, a);
}
