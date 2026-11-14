// The caustics for one moment of the sea's surface (`Reef/Caustics.lean`):
// the sun's light through the surface's waves, as it lands on the floor.
// A grid over one tile of the surface (and a margin, for what lands in
// the tile from beyond it) is drawn as triangles into a texture over the
// tile, each vertex carried straight down its refracted ray to the
// floor; each vertex's brightness is how much surface lands on how much
// floor about it (the landing's Jacobian, by differences), so that where
// the surface's curvature draws the rays together the light is bright,
// unboundedly so at a fold, and where it spreads them, dim; and where
// the surface folds over itself the triangles pile up and add. Three
// instances, the water's refractive index a little different for each,
// red, green and blue, so the brightest lines fringe with colour, as
// they do. The sun straight down: the sand projects the pattern along
// the sun it has.
//
// The surface is `field` (shaders/ocean.wgsl): the height and the slopes
// at each point of a grid over the tile, read between the points.

const N = 256u;
// The water's refractive index for green; how far red's and blue's lie
// either side of it is the bake's `dispersion`.
const index = 1.333;
// The light at a fold, which the maths has unbounded; the texture holds
// the light over this, 0 to 1.
const brightest = 8.0;

struct Bake {
  // The tile's width, in metres; the surface's height above the floor;
  // the grid drawn, quads a side; its margin beyond the tile, in metres;
  // how far the water's index for red and for blue lie either side of
  // green's (0.004 in truth, which at the floor's depth would fringe
  // every line wider than the line).
  tile       : f32,
  depth      : f32,
  grid       : u32,
  margin     : f32,
  dispersion : f32,
  pad0       : f32,
  pad1       : f32,
  pad2       : f32,
}

@group(0) @binding(0) var<uniform> bake : Bake;
@group(0) @binding(1) var<storage, read> field : array<vec4f>;

struct Out {
  @builtin(position) position : vec4f,
  @location(0) light : f32,
  @location(1) @interpolate(flat) channel : u32,
}

// The surface at `p` (the world's xz), between the grid's points: the
// height, and the slope along x and z.
fn surface(p : vec2f) -> vec3f {
  let uv = p / bake.tile * f32(N);
  let i = vec2i(floor(uv));
  let f = fract(uv);
  let n = i32(N);
  let i00 = vec2u(vec2i((i.x % n + n) % n, (i.y % n + n) % n));
  let i11 = (i00 + vec2u(1u)) % N;
  let f00 = field[i00.y * N + i00.x].xyz;
  let f10 = field[i00.y * N + i11.x].xyz;
  let f01 = field[i11.y * N + i00.x].xyz;
  let f11 = field[i11.y * N + i11.x].xyz;
  return mix(mix(f00, f10, f.x), mix(f01, f11, f.x), f.y);
}

// Where the sun's ray, straight down, through the surface at `p` lands
// on the floor, the water's index `eta` (air's over it).
fn landing(p : vec2f, eta : f32) -> vec2f {
  let s = surface(p);
  let normal = normalize(vec3f(-s.y, 1.0, -s.z));
  var ray = refract(vec3f(0.0, -1.0, 0.0), normal, eta);
  if (length(ray) < 0.5) { ray = vec3f(0.0, -1.0, 0.0); }
  return p + ray.xz * (bake.depth - s.x) / max(-ray.y, 0.05);
}

// The grid's vertices, `grid + 1` a side over the tile and its margin,
// indexed as the floor's lattice is (`Reef.latticeIndices`).
@vertex fn vs(@builtin(vertex_index) v : u32,
              @builtin(instance_index) instance : u32) -> Out {
  let grid = bake.grid;
  let cx = v % (grid + 1u);
  let cz = v / (grid + 1u);
  let span = bake.tile + 2.0 * bake.margin;
  let step = span / f32(grid);
  let p = vec2f(f32(cx), f32(cz)) * step - bake.margin;
  let eta = 1.0 / (index + bake.dispersion * (f32(instance) - 1.0));
  let here = landing(p, eta);
  // How much floor a patch of surface about `p` lands on: the landing's
  // Jacobian, by differences a third of a step on; the light is the
  // surface's share of it, the inverse.
  let h = step / 3.0;
  let ddx = (landing(p + vec2f(h, 0.0), eta) - here) / h;
  let ddz = (landing(p + vec2f(0.0, h), eta) - here) / h;
  let spread = abs(ddx.x * ddz.y - ddx.y * ddz.x);
  var out : Out;
  out.position = vec4f(here.x / bake.tile * 2.0 - 1.0, 1.0 - here.y / bake.tile * 2.0,
                       0.0, 1.0);
  out.light = min(1.0 / max(spread, 1e-4), brightest) / brightest;
  out.channel = instance;
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  return vec4f(select(0.0, in.light, in.channel == 0u),
               select(0.0, in.light, in.channel == 1u),
               select(0.0, in.light, in.channel == 2u), 0.0);
}
