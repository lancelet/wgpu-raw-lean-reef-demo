// The frame's uniforms, as every shader reads them, put before each
// (`Reef/Render.lean`): as `Reef.frameBytes` encodes them, 176 bytes.

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
}

@group(0) @binding(0) var<uniform> frame : Frame;

// The ripples' tile (`shaders/ripples.wgsl`) and the grains'
// (`shaders/grains.wgsl`), with their mip levels, and how they are
// sampled: repeating, filtered by the pixel's footprint.
@group(0) @binding(2) var ripples : texture_2d<f32>;
@group(0) @binding(3) var rippleSampler : sampler;
@group(0) @binding(4) var grains : texture_2d<f32>;

// The background, which what is far fades into: the colour the frame is
// cleared to.
const background = vec3f(0.02, 0.05, 0.09);

// How much of something `dist` from the camera shows, the rest fog.
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
// three octaves of noise, from fifty metres across to five, about a metre
// of relief in all at an amplitude of 1 (`Reef.Floor.relief` bounds it).
// The ripples are on top of this (`shaders/sand.wgsl`).
fn height(xz : vec2f) -> f32 {
  return frame.floor.w * (0.6 * noise(xz / 40.0) + 0.3 * noise(xz / 13.0 + 7.0)
                          + 0.1 * noise(xz / 5.0 + 3.0));
}

// The floor's slope at `xz`, in the world (the height's rise along x and
// along z), from the height a step `e` either side.
fn floorSlope(xz : vec2f, e : f32) -> vec2f {
  let dx = height(xz + vec2f(e, 0.0)) - height(xz - vec2f(e, 0.0));
  let dz = height(xz + vec2f(0.0, e)) - height(xz - vec2f(0.0, e));
  return vec2f(dx, dz) / (2.0 * e);
}
