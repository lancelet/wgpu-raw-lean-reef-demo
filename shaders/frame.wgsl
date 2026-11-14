// The frame's uniforms, as every shader reads them, put before each
// (`Reef/Render.lean`): as `Reef.frameBytes` encodes them, 400 bytes.

// Everything is drawn relative to the camera, which is at the origin of
// `viewProj`; `camera` is where it is in the world, for what is a function
// of the world's coordinates.
struct Frame {
  viewProj : mat4x4f,
  camera   : vec4f,  // where the camera is in the world; the angle a pixel subtends, in radians
  grid     : vec4f,  // spacing, major, extent, fade
  floor    : vec4f,  // a patch's cells a side, the leaves' range, the morph fraction, the height's amplitude
  eye      : vec4f,  // the camera's place in its leaf cell (x, z), the cell's size; w unused
  ripple   : vec4f,  // the waves' direction (x, z), the ripples' wavelength, their height, in metres
  tiling   : vec4f,  // the ripples' tile, in metres; the distance their displacement fades from, and to; the cavity's strength
  grain    : vec4f,  // the grains' tile, in metres; their relief; their speckle; w unused
  sun      : vec4f,  // where the sun's light comes from: unit; w unused
  right    : vec4f,  // the camera's right, and the tangent of half the view's width
  up       : vec4f,  // the camera's up, and the tangent of half the view's height
  forward  : vec4f,  // the camera's forward; w unused
  screen   : vec4f,  // the target's width and height, in pixels; the time, in seconds; w unused
  water    : vec4f,  // the surface's height above the floor's zero, in metres; the caustics' strength; z, w unused
  extinct  : vec4f,  // how fast the water takes each colour, per metre; w unused
  horizon  : vec4f,  // the water's colour seen level, far off
  zenith   : vec4f,  // ... seen up, toward the surface
  deep     : vec4f,  // ... seen down, into the depths
  sunlight : vec4f,  // the sun's light at the floor
  skylight : vec4f,  // the sky's, from all above
  caustic  : vec4f,  // the caustics' loop: its tile, in metres; its length, in seconds; its moments, the layers; w unused
  surface  : vec4f,  // the surface's grid, cells a side, and its reach from the camera, in metres; z, w unused
}

@group(0) @binding(0) var<uniform> frame : Frame;

// The ripples' tile (`shaders/ripples.wgsl`) and the grains'
// (`shaders/grains.wgsl`), with their mip levels, and how they are
// sampled: repeating, filtered by the pixel's footprint.
@group(0) @binding(2) var ripples : texture_2d<f32>;
@group(0) @binding(3) var rippleSampler : sampler;
@group(0) @binding(4) var grains : texture_2d<f32>;
@group(0) @binding(5) var horizons : texture_2d<f32>;
// The caustics, baked as a loop (`Reef/Caustics.lean`): a layer a moment,
// over one tile of the surface, the light over its brightest.
@group(0) @binding(6) var caustics : texture_2d_array<f32>;
const causticBrightest = 8.0;
// The sea's surface at this moment (`shaders/ocean.wgsl`, evolved each
// frame): the height and the slopes at each point of a grid over one
// tile, `seaPoints` a side.
@group(0) @binding(7) var<storage, read> sea : array<vec4f>;
const seaPoints = 256u;

// The sea's surface at `xz`, in the world, between the grid's points:
// its height, and its slope along x and z.
fn seaAt(xz : vec2f) -> vec3f {
  let uv = xz / frame.caustic.x * f32(seaPoints);
  let i = vec2i(floor(uv));
  let f = fract(uv);
  let n = i32(seaPoints);
  let i00 = vec2u(vec2i((i.x % n + n) % n, (i.y % n + n) % n));
  let i11 = (i00 + vec2u(1u)) % seaPoints;
  let f00 = sea[i00.y * seaPoints + i00.x].xyz;
  let f10 = sea[i00.y * seaPoints + i11.x].xyz;
  let f01 = sea[i11.y * seaPoints + i00.x].xyz;
  let f11 = sea[i11.y * seaPoints + i11.x].xyz;
  return mix(mix(f00, f10, f.x), mix(f01, f11, f.x), f.y);
}

// The water, looking along `dir` (unit) into it with nothing in the
// way: the horizon's colour level, brighter up toward the surface,
// darker down.
fn water(dir : vec3f) -> vec3f {
  let up = smoothstep(-0.05, 0.6, dir.y);
  let down = smoothstep(0.05, -0.5, dir.y);
  return mix(mix(frame.horizon.rgb, frame.zenith.rgb, up), frame.deep.rgb, down);
}

// `colour`, seen through the water at `relative` from the camera: what
// the water has not taken of it, and the water's own light scattered in
// along the way, each colour at its own rate.
fn fogged(colour : vec3f, relative : vec3f) -> vec3f {
  let dist = length(relative);
  let through = exp(-frame.extinct.rgb * dist);
  return mix(water(relative / max(dist, 1e-4)), colour, through);
}

// How much of something `dist` from the camera shows, the rest fog: for
// what fades by an alpha (the overlays).
fn visible(dist : f32) -> f32 {
  return exp(-dist / frame.grid.w);
}

// Where `relative`, a point relative to the camera, is in the world.
fn toWorld(relative : vec3f) -> vec3f {
  return relative + frame.camera.xyz;
}

// A gradient at the lattice point `p`, by a hash of its integer
// coordinates (an integer hash, not a sine's, which fails far from the
// origin): a direction, not unit.
fn gradient(p : vec2i) -> vec2f {
  var h = (u32(p.x) * 0x8da6b343u) ^ (u32(p.y) * 0xd8163841u);
  h = h ^ (h >> 15u);
  h = h * 0x2c1b3c6du;
  h = h ^ (h >> 12u);
  let a = f32(h & 0xffffu) / 65535.0;
  let b = f32((h >> 16u) & 0xffffu) / 65535.0;
  return vec2f(a, b) * 2.0 - 1.0;
}

// Gradient noise at `p`: smooth, about -1 to 1, a feature a unit wide.
fn noise(p : vec2f) -> f32 {
  let i = vec2i(floor(p));
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  let a = dot(gradient(i), f);
  let b = dot(gradient(i + vec2i(1, 0)), f - vec2f(1.0, 0.0));
  let c = dot(gradient(i + vec2i(0, 1)), f - vec2f(0.0, 1.0));
  let d = dot(gradient(i + vec2i(1, 1)), f - vec2f(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// The floor's height at `xz`, in the world: the large-scale elevation,
// four octaves of noise, from fifty metres across to two and a half, the
// mounds and hollows of a back-reef's sand, a metre and a half of relief
// in all at an amplitude of 1; and on that the sand waves and hummocks,
// a couple of metres across and under one, some centimetres high, the
// waves drawn out along the ripples' crests (across the waves'
// direction), as sand waves lie (`Reef.Floor.relief` bounds the whole).
// The ripples are on top of this (`shaders/sand.wgsl`).
fn height(xz : vec2f) -> f32 {
  let dir = frame.ripple.xy;
  let along = vec2f(dot(xz, dir), dot(xz, vec2f(-dir.y, dir.x)));
  return frame.floor.w * (0.6 * noise(xz / 40.0) + 0.45 * noise(xz / 13.0 + 7.0)
                          + 0.25 * noise(xz / 5.0 + 3.0)
                          + 0.12 * noise(xz / 2.5 + 11.0))
       + 0.1 * noise(along / vec2f(1.6, 3.2) + 5.0)
       + 0.025 * noise(xz / 0.7 + 9.0);
}

// The floor's slope at `xz`, in the world (the height's rise along x and
// along z), from the height a step `e` either side.
fn floorSlope(xz : vec2f, e : f32) -> vec2f {
  let dx = height(xz + vec2f(e, 0.0)) - height(xz - vec2f(e, 0.0));
  let dz = height(xz + vec2f(0.0, e)) - height(xz - vec2f(0.0, e));
  return vec2f(dx, dz) / (2.0 * e);
}
