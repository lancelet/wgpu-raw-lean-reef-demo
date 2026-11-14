// The caustics, drawn each frame (`Reef/Caustics.lean`): the sun's light
// through the surface's waves, as it lands on the floor. A grid over one
// tile of the surface (and a margin, for what lands in the tile from
// beyond it) is drawn as triangles into a texture over the tile, each
// vertex carried down its refracted ray to the floor; each vertex's
// brightness is how much surface lands on how much floor about it (the
// landing's Jacobian, by differences), so that where the surface's
// curvature draws the rays together the light is bright, unboundedly so
// at a fold, and where it spreads them, dim; and where the surface folds
// over itself the triangles pile up and add.
// Three instances, the water's refractive index a little different for
// each, red, green and blue, so the brightest lines fringe with colour,
// as they do.
//
// The surface (`surface`): a score of waves summed, each with a whole
// number of cycles across the tile, so the tile repeats, and each at the
// speed deep water gives its length (its frequency the square root of
// gravity times its wave number), so the surface reshapes as it moves
// rather than sliding. Their lengths spread about the dominant, their
// directions about the waves' (the ripples' own), their phases random;
// the shorter ones the gentler, as the wind leaves them, and as the
// floor needs: a wave focuses the light about as far down as its length
// over its steepness, and the short waves, steep, would focus well
// above the floor and spread again, a mush.

const waveCount = 32u;
const gravity = 9.81;
const tau = 6.283185307;
// The water's refractive index for green, and how far red's and blue's
// lie either side of it: a quarter of the truth, which at the floor's
// depth would fringe every line wider than the line.
const index = 1.333;
const dispersion = 0.001;

struct Out {
  @builtin(position) position : vec4f,
  @location(0) light : f32,
  @location(1) @interpolate(flat) channel : u32,
}

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

// Wave `i`: its wave vector (radians a metre, along its travel), its
// amplitude in metres, and its phase; a whole number of cycles across the
// tile.
fn wave(i : u32) -> vec4f {
  let tile = frame.waves.x;
  let dominant = frame.waves.y;
  let steepness = frame.waves.z;
  let spread = frame.waves.w;
  let dir = frame.ripple.xy;
  // Lengths from half the dominant to four times it, most near it: the
  // long ones the swell, which bends the pattern; the short ones the
  // chop, which makes it. The long ones run nearer the waves' direction
  // than the short, as a sea's do.
  let spreadBy = rand(i, 0u) + rand(i, 1u) - 1.0;
  let wavelen = dominant * exp(spreadBy * 1.0 + 0.35);
  let angle = spread * (rand(i, 2u) + rand(i, 3u) - 1.0) * (1.0 - 0.5 * max(spreadBy, 0.0));
  let heading = vec2f(dir.x * cos(angle) - dir.y * sin(angle),
                      dir.x * sin(angle) + dir.y * cos(angle));
  // Cycles across the tile, whole, in each direction.
  let cycles = round(heading * tile / wavelen);
  let k = cycles * tau / tile;
  let kLength = max(length(k), 1e-3);
  // Steep as said, give or take, the short waves less: by their length
  // over the dominant's, and a half again.
  let amplitude = steepness * (0.6 + 0.8 * rand(i, 4u)) / kLength
    * pow(min(1.0, wavelen / dominant), 1.5);
  return vec4f(k, amplitude, rand(i, 5u) * tau);
}

// The surface at `p` (the world's xz), at time `t`: its height; its
// slope along x and z; and its curvature, the slope's change along x and
// z (the second derivatives, xx, xz, zz), for the slope a little way
// off without summing the waves again.
struct Surface {
  height    : f32,
  slope     : vec2f,
  curvature : vec3f,
}

fn surface(p : vec2f, t : f32) -> Surface {
  var s : Surface;
  s.height = 0.0;
  s.slope = vec2f(0.0);
  s.curvature = vec3f(0.0);
  for (var i = 0u; i < waveCount; i++) {
    let w = wave(i);
    let k = w.xy;
    let omega = sqrt(gravity * length(k));
    let phase = dot(k, p) - omega * t + w.w;
    let sn = w.z * sin(phase);
    s.height += sn;
    s.slope += w.z * k * cos(phase);
    s.curvature -= sn * vec3f(k.x * k.x, k.x * k.y, k.y * k.y);
  }
  return s;
}

// The sun's light as it comes through the air: the water's direction is
// the sun's (`frame.sun`, where the light comes from, under water);
// Snell's law gives the air's, bent further from the vertical.
fn sunInAir() -> vec3f {
  let down = -frame.sun.xyz;
  let horizontal = down.xz;
  let sinWater = length(horizontal);
  let sinAir = min(index * sinWater, 0.9995);
  let cosAir = sqrt(1.0 - sinAir * sinAir);
  let along = horizontal / max(sinWater, 1e-5);
  return vec3f(along.x * sinAir, -cosAir, along.y * sinAir);
}

// Where the sun's ray through the surface at `p`, of height `height`
// and slope `slope`, lands on the floor, less where it would through a
// flat surface (the texture is laid out by the surface, as the sand
// reads it: shaders/sand.wgsl), the water's index `eta` (air's over it).
fn landing(p : vec2f, height : f32, slope : vec2f, eta : f32) -> vec2f {
  let depth = frame.water.x;
  let normal = normalize(vec3f(-slope.x, 1.0, -slope.y));
  var ray = refract(sunInAir(), normal, eta);
  if (length(ray) < 0.5) { ray = -frame.sun.xyz; }
  let flat = -frame.sun.xyz;
  return p + ray.xz * (depth - height) / max(-ray.y, 0.05)
    - flat.xz * depth / max(-flat.y, 0.05);
}

// The light at a fold, which the maths has unbounded.
const brightest = 8.0;

// The grid's vertices, `grid + 1` a side over the tile and its margin,
// indexed as the floor's lattice is (`Reef.latticeIndices`).
@vertex fn vs(@builtin(vertex_index) v : u32,
              @builtin(instance_index) instance : u32) -> Out {
  let tile = frame.waves.x;
  let grid = u32(frame.caustic.y);
  let margin = frame.caustic.z;
  let cx = v % (grid + 1u);
  let cz = v / (grid + 1u);
  let span = tile + 2.0 * margin;
  let step = span / f32(grid);
  let p = vec2f(f32(cx), f32(cz)) * step - margin;
  let eta = 1.0 / (index + dispersion * (f32(instance) - 1.0));
  let s = surface(p, frame.screen.z);
  let here = landing(p, s.height, s.slope, eta);
  // How much floor a patch of surface about `p` lands on: the landing's
  // Jacobian, by differences a little way on, the surface there by its
  // slope and curvature here; the light is the surface's share of it,
  // the inverse.
  let h = step / 3.0;
  let c = s.curvature;
  let onX = landing(p + vec2f(h, 0.0), s.height + s.slope.x * h,
                    s.slope + vec2f(c.x, c.y) * h, eta);
  let onZ = landing(p + vec2f(0.0, h), s.height + s.slope.y * h,
                    s.slope + vec2f(c.y, c.z) * h, eta);
  let ddx = (onX - here) / h;
  let ddz = (onZ - here) / h;
  let spread = abs(ddx.x * ddz.y - ddx.y * ddz.x);
  var out : Out;
  out.position = vec4f(here.x / tile * 2.0 - 1.0, 1.0 - here.y / tile * 2.0, 0.0, 1.0);
  out.light = min(1.0 / max(spread, 1e-4), brightest);
  out.channel = instance;
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  return vec4f(select(0.0, in.light, in.channel == 0u),
               select(0.0, in.light, in.channel == 1u),
               select(0.0, in.light, in.channel == 2u), 0.0);
}
