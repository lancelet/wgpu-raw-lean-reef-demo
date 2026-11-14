// The grains' tile, baked once at the start (`Reef/Grains.lean`): the
// sand's grains, a few centimetres of them, as a texture that repeats.
// Each texel: the normal of the grains' surface, as (normal / 2 + 0.5),
// and its brightness, 0.5 the sand's own colour, darker in the gaps
// between grains, which see less light, and on dark grains, brighter on
// shell. `shaders/sand.wgsl` reads them.
//
// The grains are spheres, a couple to each cell of a grid a grain and a
// half wide, placed at random in it, of sizes spread three to one about
// the grain's, most in the middle (a reef's sand is poorly sorted, being
// broken shell and coral): the surface is the highest of them at each
// point, a packed bed. Among them, coarse grains, a few times the size,
// here and there; and fragments (shell and the like): flatter domes,
// bigger still, one to some of the cells of a coarser grid, lying on the
// bed. The bed itself rises and falls a little over a few
// millimetres, the sand's own unevenness between the grains and the
// ripples, which shows as roughness from a metre or two off, where the
// grains themselves have averaged away; and is a little darker in its
// hollows. The grids and the noise are whole numbers of cells across
// the tile, so the tile repeats.

struct Bake {
  // The tile's texels a side; a grain's diameter, and a fragment's, in
  // texels; how many of the fragments' cells hold one, 0 to 1.
  grain : vec4f,
}

@group(0) @binding(0) var<uniform> bake : Bake;

const tau = 6.283185307;

struct Out {
  @builtin(position) position : vec4f,
}

// One triangle over the whole target; the fragment's position says where.
@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  let xy = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
  var out : Out;
  out.position = vec4f(xy * 2.0 - 1.0, 0.0, 1.0);
  return out;
}

// A number in [0, 1) from `seed`, the `n`th of its sequence.
fn rand(seed : u32, n : u32) -> f32 {
  var h = seed + n * 0x9e3779b9u;
  h = h ^ (h >> 16u);
  h = h * 0x7feb352du;
  h = h ^ (h >> 15u);
  h = h * 0x846ca68bu;
  h = h ^ (h >> 16u);
  return f32(h & 0xffffffu) / 16777216.0;
}

// The seed of the cell `cell` of a grid `n` wide over the tile, the grid
// repeating with it, salted by `salt`.
fn cellSeed(cell : vec2i, n : i32, salt : u32) -> u32 {
  let wrapped = ((cell % n) + n) % n;
  return (u32(wrapped.x) * 0x8da6b343u) ^ (u32(wrapped.y) * 0xd8163841u) ^ salt;
}

// A gradient at the lattice point `p` of a lattice `period` wide, which
// repeats: a direction, not unit.
fn gradient(p : vec2i, period : i32) -> vec2f {
  var h = cellSeed(p, period, 0x7u);
  h = h ^ (h >> 15u);
  h = h * 0x2c1b3c6du;
  h = h ^ (h >> 12u);
  let a = f32(h & 0xffffu) / 65535.0;
  let b = f32((h >> 16u) & 0xffffu) / 65535.0;
  return vec2f(a, b) * 2.0 - 1.0;
}

// Gradient noise at `p`, repeating every `period`: smooth, about -1 to 1,
// a feature a unit wide.
fn noise(p : vec2f, period : i32) -> f32 {
  let i = vec2i(floor(p));
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  let a = dot(gradient(i, period), f);
  let b = dot(gradient(i + vec2i(1, 0), period), f - vec2f(1.0, 0.0));
  let c = dot(gradient(i + vec2i(0, 1), period), f - vec2f(0.0, 1.0));
  let d = dot(gradient(i + vec2i(1, 1), period), f - vec2f(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.4;
}

// The bed's unevenness at `p`, in texels: two octaves of noise, eight
// and four features across the tile, about -1 to 1.
fn unevenness(p : vec2f) -> f32 {
  let uv = p / bake.grain.x;
  return 0.6 * noise(uv * 8.0 + 3.0, 8) + 0.4 * noise(uv * 4.0 + 11.0, 4);
}

// A grain's brightness, from its seed: most a little darker or lighter
// than the sand, a few dark (basalt, say), a few bright (shell); a
// fragment's more often one or the other.
fn brightnessOf(seed : u32, fragment : bool) -> f32 {
  let kind = rand(seed, 3u);
  let dark = select(0.06, 0.3, fragment);
  let bright = select(0.1, 0.6, fragment);
  if (kind < dark) { return 0.15 + 0.15 * rand(seed, 4u); }
  if (kind < bright) { return 0.8 + 0.2 * rand(seed, 4u); }
  return 0.4 + 0.3 * rand(seed, 4u);
}

// The surface of a bed of domes at `p`, in texels: the domes `perCell`
// to each cell of a grid of cells `cell` texels wide, `n` across the
// tile, each placed at random in its cell, of radius `radius` of the
// cell at the middle of a spread of sizes `spread` to 1 from smallest to
// largest (most in the middle, a few at the ends: the sand's sorting,
// poor for a reef's broken shell and coral), `squash` as high as it is
// wide (1 a sphere), drawn out along a direction of its own by up to
// `stretch` (0 round), each there with chance `chance`; seeds salted by
// `salt`. The height, in texels, of the highest dome at `p` (0 off them
// all), and its brightness (the gaps' if none).
fn bedAt(p : vec2f, cell : f32, n : i32, perCell : u32, radius : f32,
         spread : f32, squash : f32, stretch : f32, chance : f32,
         salt : u32) -> vec2f {
  let base = vec2i(floor(p / cell));
  var best = vec2f(0.0, 0.2);
  for (var j = -1; j <= 1; j++) {
    for (var i = -1; i <= 1; i++) {
      let c = base + vec2i(i, j);
      for (var k = 0u; k < perCell; k++) {
        let seed = cellSeed(c, n, salt + k * 0x9e3779b9u);
        if (rand(seed, 5u) >= chance) { continue; }
        let centre = (vec2f(c) + vec2f(rand(seed, 0u), rand(seed, 1u))) * cell;
        // Two draws summed: a peak in the middle, in the log of the size.
        let r = cell * radius * pow(spread, 0.5 * (rand(seed, 2u) + rand(seed, 8u) - 1.0));
        // Narrowed across its own direction: an ellipse, of the radius
        // along it.
        let angle = tau * rand(seed, 6u);
        let along = vec2f(cos(angle), sin(angle));
        let narrow = 1.0 / (1.0 - stretch * rand(seed, 7u));
        let d = p - centre;
        let e = vec2f(dot(d, along), dot(d, vec2f(-along.y, along.x)) * narrow);
        let under = r * r - dot(e, e);
        if (under > 0.0) {
          let h = squash * sqrt(under);
          if (h > best.x) { best = vec2f(h, brightnessOf(seed, salt == 0x2u)); }
        }
      }
    }
  }
  return best;
}

// The grains' surface at `p`, in texels: the bed of grains, and the
// fragments lying on it, in height (texels) and brightness; the bed on
// its unevenness, a grain's diameter of it, darker in the hollows.
fn surfaceAt(p : vec2f) -> vec2f {
  let texels = bake.grain.x;
  // The grains' cells a grain and a half wide, two grains to each, so
  // that their spacing is no lattice; the coarse grains' cells three
  // wide, one to some; the fragments' a fragment wide, one to a few.
  let grainCells = i32(round(texels / (bake.grain.y * 1.5)));
  let grainCell = texels / f32(grainCells);
  let coarseCells = i32(round(texels / (bake.grain.y * 3.0)));
  let coarseCell = texels / f32(coarseCells);
  let fragmentCells = i32(round(texels / bake.grain.z));
  let fragmentCell = texels / f32(fragmentCells);
  let fine = bedAt(p, grainCell, grainCells, 2u, 0.4, 3.0, 1.0, 0.2, 1.0, 0x1u);
  let coarse = bedAt(p, coarseCell, coarseCells, 1u, 0.4, 2.0, 0.9, 0.3, 0.3, 0x3u);
  let grains = select(fine, coarse, coarse.x > fine.x);
  var fragments = bedAt(p, fragmentCell, fragmentCells, 1u, 0.4, 2.0, 0.3, 0.5,
                        bake.grain.w, 0x2u);
  // A fragment lies on the bed, a grain's height up.
  if (fragments.x > 0.0) { fragments.x += bake.grain.y * 0.5; }
  let uneven = unevenness(p);
  let surface = select(grains, fragments, fragments.x > grains.x);
  return vec2f(surface.x + uneven * bake.grain.y,
               surface.y * (1.0 + 0.2 * uneven));
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let p = in.position.xy;
  let here = surfaceAt(p);
  let sx = (surfaceAt(p + vec2f(1.0, 0.0)).x - surfaceAt(p - vec2f(1.0, 0.0)).x) / 2.0;
  let sy = (surfaceAt(p + vec2f(0.0, 1.0)).x - surfaceAt(p - vec2f(0.0, 1.0)).x) / 2.0;
  let normal = normalize(vec3f(-sx, 1.0, -sy));
  return vec4f(normal * 0.5 + 0.5, here.y);
}
