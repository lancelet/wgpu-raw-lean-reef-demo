// The bubbles (`Reef/Bubbles.lean`): the air the waves mix into the
// water, rising. Each is born under the surface where the sea is
// steepest, as a breaking crest would leave it, and rises at the speed
// its size gives it (a millimetre a second for the smallest, a quarter
// of a metre for the biggest), swayed by the surge and shaken by the
// water's turbulence, till it reaches the surface and is born again.
// Stepped in compute each frame, a thread a bubble; drawn as quads
// facing the camera, each a bright rim about a glassy middle (the sun's
// light refracted round the bubble and reflected from it), fogged by
// the water.

struct Bubble {
  // Where, in the world; and its radius, in metres.
  position : vec3f,
  radius   : f32,
  // Its age, in seconds, and its life (to fade out in before being born
  // again); its phase, for the wobble; w unused.
  age      : f32,
  life     : f32,
  phase    : f32,
  pad      : f32,
}

struct Pool {
  // How many bubbles; the step, in seconds; how far from the camera
  // they are kept, in metres; the moment, in seconds.
  count  : f32,
  dt     : f32,
  reach  : f32,
  time   : f32,
}

// Writable for the step, read only for the draw (the vertex stage cannot
// write): `Reef/Bubbles.lean` builds the shader twice, the draw's copy
// with this declaration made `read`.
@group(1) @binding(0) var<storage, read_write> bubbles : array<Bubble>;
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

// A bubble born: about the camera, under the surface, where the sea is
// steep; its size a few millimetres, mostly small.
fn born(i : u32, salt : u32) -> Bubble {
  let seed = i * 0x27d4eb2fu + salt * 0x165667b1u;
  var b : Bubble;
  let reach = pool.reach;
  let xz = frame.camera.xz + (vec2f(rand(seed, 0u), rand(seed, 1u)) - 0.5) * 2.0 * reach;
  // Under the surface, by the sea's steepness there: where it is steep,
  // deeper and more; where flat, few, shallow.
  let sea = seaAt(xz);
  let steep = clamp(length(sea.yz) * 4.0, 0.1, 1.0);
  let depth = (0.1 + 1.5 * steep) * rand(seed, 2u);
  b.position = vec3f(xz.x, frame.water.x - depth, xz.y);
  let size = rand(seed, 3u);
  b.radius = 0.0004 + 0.004 * size * size;
  b.age = 0.0;
  b.life = 4.0 + 8.0 * rand(seed, 4u);
  b.phase = rand(seed, 5u) * 6.2832;
  b.pad = steep;
  return b;
}

// The step: left out of the draw's copy of the shader, which cannot
// write (`Reef/Bubbles.lean` cuts from STEP to END).
// STEP
@compute @workgroup_size(64)
fn step(@builtin(global_invocation_id) id : vec3u) {
  let i = id.x;
  if (f32(i) >= pool.count) { return; }
  var b = bubbles[i];
  let dt = pool.dt;
  let t = pool.time;
  b.age += dt;
  // Rising at its own speed (Stokes for the small, a quarter of a metre
  // a second for the rest), swayed by the surge, and shaken by the
  // water about it.
  let rise = min(0.25, 2.0e5 * b.radius * b.radius);
  let surge = surgeAt(b.position.xz, t);
  let shake = vec3f(sin(t * 3.1 + b.phase), 0.0, cos(t * 2.3 + b.phase * 1.7))
    * 0.02 * (1.0 + 2.0 * (1.0 - b.pad));
  b.position += vec3f(surge.x, rise, surge.y) * dt + shake * dt;
  // At the surface, or spent, or left far behind the camera: born again.
  let gone = b.position.y >= frame.water.x - 0.02 || b.age > b.life
    || length(b.position.xz - frame.camera.xz) > pool.reach * 1.3;
  if (gone) { b = born(i, u32(t * 61.0) + i); }
  bubbles[i] = b;
}
// END

// The draw: left out of the step's copy of the shader (a vertex stage
// may not see a writable buffer, a browser says; `Reef/Bubbles.lean`
// cuts from DRAW to the end).
// DRAW
struct Out {
  @builtin(position) position : vec4f,
  @location(0) uv       : vec2f,
  @location(1) relative : vec3f,
  @location(2) fade     : f32,
}

// Each bubble a quad of two triangles, facing the camera, its size the
// bubble's, a little bigger for the rim.
@vertex fn vs(@builtin(vertex_index) v : u32,
              @builtin(instance_index) instance : u32) -> Out {
  let b = bubbles[instance];
  let corner = vec2f(f32((v << 1u) & 2u), f32(v & 2u)) - 1.0;  // -1 or 1
  let relative = b.position - frame.camera.xyz;
  let dist = length(relative);
  let size = b.radius * 1.4;
  // Never under a pixel and a fifth: a smaller bubble is drawn that big
  // and fainter by as much, a point of light rather than nothing.
  let least = dist * frame.camera.w * 1.2;
  let drawn = max(size, least);
  let coverage = (size * size) / (drawn * drawn);
  let right = frame.right.xyz;
  let up = frame.up.xyz;
  let world = relative + (right * corner.x + up * corner.y) * drawn;
  var out : Out;
  out.position = frame.viewProj * vec4f(world, 1.0);
  out.uv = corner;
  out.relative = relative;
  // Fading in as born, and out at the end of its life.
  out.fade = smoothstep(0.0, 0.5, b.age) * (1.0 - smoothstep(b.life - 1.0, b.life, b.age))
    * max(coverage, 0.15);
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let r = length(in.uv);
  if (r > 1.0) { discard; }
  // A bright rim, a glassy middle that shows the water behind, and a
  // highlight toward the sun.
  let rim = smoothstep(0.55, 0.85, r) * (1.0 - smoothstep(0.85, 1.0, r));
  let middle = 1.0 - smoothstep(0.0, 0.6, r);
  let dist = length(in.relative);
  let view = in.relative / max(dist, 1e-4);
  let sunward = max(dot(normalize(vec3f(in.uv.x, in.uv.y, 0.4)),
                        normalize(vec3f(dot(frame.sun.xyz, frame.right.xyz),
                                        dot(frame.sun.xyz, frame.up.xyz), 0.6))), 0.0);
  let highlight = pow(sunward, 16.0) * 1.5;
  // The light about the bubble: the water's at this depth, the sun's
  // above.
  let depthHere = frame.water.x - (in.relative.y + frame.camera.y);
  let sunlight = frame.sunlight.rgb * exp(-frame.extinct.rgb * depthHere / max(frame.sun.y, 0.1));
  let ambient = water(vec3f(0.0, 1.0, 0.0)) * 2.0;
  let colour = (ambient + sunlight * 0.3) * (rim * 0.9 + middle * 0.08)
    + sunlight * highlight * rim;
  let alpha = min((rim * 0.8 + middle * 0.12 + highlight * rim) * in.fade, 1.0);
  return vec4f(fogged(colour, in.relative) * alpha, alpha);
}
