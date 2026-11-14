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

// A bubble born: about the camera, under the surface, in a plume where
// the sea is steep, as a breaking crest leaves one: the plumes a few
// metres apart, each a cloud a metre or so across and a metre deep,
// born over a second or two; between them, a few strays. Its size a few
// millimetres, mostly small, the plume's bigger.
fn born(i : u32, salt : u32) -> Bubble {
  let seed = i * 0x27d4eb2fu + salt * 0x165667b1u;
  var b : Bubble;
  let reach = pool.reach;
  // The plume: one of the cells of a grid four metres across about the
  // camera, that moment's; where in its cell by the sea's steepness,
  // steepest of a few tries.
  let cells = 4.0;
  let cell = vec2i(vec2f(rand(seed, 6u), rand(seed, 7u)) * (2.0 * reach / cells))
    + vec2i(frame.camera.xz / cells - reach / cells);
  let cellSeed = (u32(cell.x) * 0x8da6b343u) ^ (u32(cell.y) * 0xd8163841u)
    ^ (u32(pool.time / 3.0) * 0x5bd1e995u);
  var best = vec2f(0.0);
  var bestSteep = 0.0;
  for (var k = 0u; k < 4u; k++) {
    let at = (vec2f(cell) + vec2f(rand(cellSeed, k * 2u), rand(cellSeed, k * 2u + 1u))) * cells;
    let s = seaAt(at);
    let steep = length(s.yz);
    if (steep > bestSteep) { bestSteep = steep; best = at; }
  }
  let inPlume = rand(seed, 8u) < 0.8;
  let spread = select(reach, 0.6, inPlume);
  let about = select(frame.camera.xz, best, inPlume);
  let r = sqrt(rand(seed, 0u)) * spread;
  let a = rand(seed, 1u) * 6.2832;
  let xz = about + vec2f(cos(a), sin(a)) * r;
  let steep = clamp(bestSteep * 5.0, 0.2, 1.0);
  let depth = select(0.3 * rand(seed, 2u), (0.2 + 1.2 * steep) * rand(seed, 2u), inPlume);
  b.position = vec3f(xz.x, frame.water.x - depth, xz.y);
  let size = rand(seed, 3u);
  b.radius = select(0.0005 + 0.002 * size, 0.001 + 0.006 * size * size, inPlume);
  b.age = 0.0;
  b.life = select(3.0 + 3.0 * rand(seed, 4u), 2.0 + 5.0 * rand(seed, 4u), inPlume);
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
  @location(3) pixels   : f32,  // the bubble's width on the screen
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
  // And softly: the quad three times the bubble, the glow's.
  let least = dist * frame.camera.w * 2.0;
  let drawn = max(size * 3.0, least);
  let coverage = min(1.0, (size * 3.0) * (size * 3.0) / (drawn * drawn));
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
  out.pixels = 2.0 * size / max(dist * frame.camera.w, 1e-6);
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let r = length(in.uv);
  if (r > 1.0) { discard; }
  let dist = length(in.relative);
  let view = in.relative / max(dist, 1e-4);
  // The light about the bubble: the water's at this depth, the sun's
  // above.
  let depthHere = frame.water.x - (in.relative.y + frame.camera.y);
  let sunlight = frame.sunlight.rgb * exp(-frame.extinct.rgb * depthHere / max(frame.sun.y, 0.1));
  let ambient = water(vec3f(0.0, 1.0, 0.0)) * 2.0;
  // The bubble is the inner third of the quad; about it, a soft glow
  // (the water it lights), for when it is a point of light far off; up
  // close the glow goes and the bubble is a sphere of air in water, as
  // the eye has it.
  let core = r * 3.0;
  let near = smoothstep(4.0, 14.0, in.pixels);
  let glow = (1.0 - smoothstep(0.2, 1.0, r)) * 0.35 * (1.0 - near);
  // Far: a bright rim about a glassy middle, and a highlight toward the
  // sun.
  let rimFar = smoothstep(0.55, 0.85, core) * (1.0 - smoothstep(0.85, 1.1, core));
  let middleFar = 1.0 - smoothstep(0.0, 0.6, core);
  let sunward = max(dot(normalize(vec3f(in.uv.x, in.uv.y, 0.4)),
                        normalize(vec3f(dot(frame.sun.xyz, frame.right.xyz),
                                        dot(frame.sun.xyz, frame.up.xyz), 0.6))), 0.0);
  let highlightFar = pow(sunward, 16.0) * 1.5;
  let colourFar = (ambient + sunlight * 0.3) * (rimFar * 0.9 + middleFar * 0.08 + glow)
    + sunlight * highlightFar * rimFar;
  let alphaFar = rimFar * 0.8 + middleFar * 0.12 + highlightFar * rimFar + glow;
  // Near: the sphere's own optics. Its normal where the pixel sees it;
  // the view's angle to it. Light from the water in front of the bubble
  // reflects from its surface by Fresnel's share, wholly past 48.6
  // degrees (air is the rarer medium: total internal reflection), so
  // the outer quarter of the disc is a mirror of the water around,
  // bright; inside, the bubble is a lens, diverging, that shows the
  // water behind it shrunk and inverted, dim. The sun's image reflected
  // on the front, a hard spot, and a second, fainter, reflected within
  // from the back.
  let inside = min(core, 1.0);
  let nz = sqrt(max(1.0 - inside * inside, 0.0));
  let n = vec3f(in.uv.x * 3.0, in.uv.y * 3.0, nz);
  let normal = normalize(frame.right.xyz * n.x + frame.up.xyz * n.y - view * n.z);
  let cosI = max(dot(normal, -view), 0.0);
  let sinT = 1.333 * sqrt(max(1.0 - cosI * cosI, 0.0));
  var reflectance = 1.0;
  if (sinT < 1.0) {
    let cosT = sqrt(1.0 - sinT * sinT);
    let rs = (1.333 * cosI - cosT) / (1.333 * cosI + cosT);
    let rp = (cosT - 1.333 * cosI) / (cosT + 1.333 * cosI);
    reflectance = 0.5 * (rs * rs + rp * rp);
  }
  let mirrored = reflect(view, normal);
  let reflected = water(mirrored) * 1.6 + ambient * 0.2;
  // Through the lens: what is behind, spread wide: the water's colour in
  // the view's direction, and some of the way down.
  let transmitted = water(normalize(view + vec3f(0.0, -0.3, 0.0))) * 0.8;
  let spot = pow(max(dot(mirrored, frame.sun.xyz), 0.0), 600.0) * 6.0;
  let spot2 = pow(max(dot(reflect(view, -normal), frame.sun.xyz), 0.0), 300.0) * 1.2;
  let edge = 1.0 - smoothstep(0.96, 1.0, core);
  let colourNear = (reflected * reflectance + transmitted * (1.0 - reflectance) * 0.4
    + sunlight * (spot + spot2)) * edge;
  let alphaNear = (reflectance + (1.0 - reflectance) * 0.4 + spot * 0.3) * edge
    * select(0.0, 1.0, core <= 1.0);
  let colour = mix(colourFar, colourNear, near);
  let alpha = min(mix(alphaFar, alphaNear, near) * in.fade, 1.0);
  return vec4f(fogged(colour, in.relative) * alpha, alpha);
}
