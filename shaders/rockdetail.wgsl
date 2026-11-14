// The rock's detail tile, baked once at the start (`Reef/Bommies.lean`):
// a quarter metre of old reef rock's surface, as a texture that repeats,
// for `shaders/bommie.wgsl` to read over the rock from three sides. What
// a few metres of noise cannot give it close up: the coral it was, and
// what has worn and bored and grown on it since.
//
// The surface, as a height: crowded corallites, the cups the polyps
// stood in, a few millimetres across, walls between them, worn down in
// places and sharp in others; nodules of encrusting growth, a couple of
// centimetres, over them; the borers' holes, a centimetre, here and
// there; grit, a millimetre; and a slow rise and fall. All of them whole
// numbers of features across the tile, so that it repeats.
//
// Two layers. The first: the surface's slope along the tile's two axes
// (metres a metre, as 0.5 + slope / 4), how far below its surroundings
// it lies (the cavity, 0.5 level, less deeper, which the mip levels
// average to the rock's own darkening in its pits from afar), and its
// height (0 to 1 over the relief). The second: its brightness (0.5 the
// rock's own colour), the crust's cover (0 to 1), and grit's speckle
// (0.5 none); w unused.

struct Bake {
  // The tile's texels a side; its width, in metres; which layer; unused.
  tile : vec4f,
}

@group(0) @binding(0) var<uniform> bake : Bake;

struct Out {
  @builtin(position) position : vec4f,
}

@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  let xy = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
  var out : Out;
  out.position = vec4f(xy * 2.0 - 1.0, 0.0, 1.0);
  return out;
}

fn rand(seed : u32, n : u32) -> f32 {
  var h = seed + n * 0x9e3779b9u;
  h = h ^ (h >> 16u);
  h = h * 0x7feb352du;
  h = h ^ (h >> 15u);
  h = h * 0x846ca68bu;
  h = h ^ (h >> 16u);
  return f32(h & 0xffffffu) / 16777216.0;
}

fn cellSeed(cell : vec2i, n : i32, salt : u32) -> u32 {
  let wrapped = ((cell % n) + n) % n;
  return (u32(wrapped.x) * 0x8da6b343u) ^ (u32(wrapped.y) * 0xd8163841u) ^ salt;
}

// Value noise at `uv` (0 to 1 over the tile), `n` features across,
// repeating: smooth, -1 to 1.
fn wavy(uv : vec2f, n : i32, salt : u32) -> f32 {
  let p = uv * f32(n);
  let i = vec2i(floor(p));
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  let a = rand(cellSeed(i, n, salt), 0u);
  let b = rand(cellSeed(i + vec2i(1, 0), n, salt), 0u);
  let c = rand(cellSeed(i + vec2i(0, 1), n, salt), 0u);
  let d = rand(cellSeed(i + vec2i(1, 1), n, salt), 0u);
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 2.0 - 1.0;
}

// Cells at `uv`, `n` across the tile, one point in each, repeating: the
// distance to the nearest point and the next nearest (in cells), and the
// nearest's seed.
fn cells(uv : vec2f, n : i32, salt : u32) -> vec3f {
  let p = uv * f32(n);
  let base = vec2i(floor(p));
  var f1 = 9.0;
  var f2 = 9.0;
  var id = 0.0;
  for (var j = -1; j <= 1; j++) {
    for (var i = -1; i <= 1; i++) {
      let c = base + vec2i(i, j);
      let seed = cellSeed(c, n, salt);
      let at = vec2f(c) + vec2f(0.15 + 0.7 * rand(seed, 1u), 0.15 + 0.7 * rand(seed, 2u));
      let d = length(p - at);
      if (d < f1) { f2 = f1; f1 = d; id = rand(seed, 3u); }
      else if (d < f2) { f2 = d; }
    }
  }
  return vec3f(f1, f2, id);
}

// The surface's height at `uv`, in millimetres, and its brightness and
// crust there.
struct Surface {
  height : f32,
  bright : f32,
  crust  : f32,
  grit   : f32,
}

fn surfaceAt(uv : vec2f) -> Surface {
  var s : Surface;
  // The slow rise and fall, and how worn the corallites are: sharp in
  // some places, worn nearly flat in others.
  let swell = 0.6 * wavy(uv, 3, 11u) + 0.4 * wavy(uv, 7, 12u);
  // Worn: mostly, the corallites eroded to a rough suggestion; sharp only
  // in patches.
  // (Evenly: as worn here as there, give or take, so that the detail is
  // as dense everywhere.)
  let worn = 0.45 + 0.15 * wavy(uv, 5, 13u) + 0.1 * wavy(uv, 17, 14u);
  // The corallites: cups 4 to 7 mm across (two colonies' sizes, in their
  // own patches); the wall between neighbours where the two nearest
  // points are equally near.
  let colony = smoothstep(-0.2, 0.2, wavy(uv, 4, 15u));
  let ca = cells(uv, 40, 21u);
  let cb = cells(uv, 64, 22u);
  let c = mix(ca, cb, colony);
  let wall = c.y - c.x;
  let cup = -1.4 * (1.0 - smoothstep(0.05, 0.45, wall)) * mix(1.0, 0.25, worn)
    * (0.7 + 0.3 * c.z);
  let cupFloor = 1.0 - smoothstep(0.0, 0.5, c.x);
  // The septa: the cups' radial ribs, a fine ridging in each.
  let ribs = 0.25 * sin(atan2(uv.y * 48.0 - floor(uv.y * 48.0) - 0.5,
                              uv.x * 48.0 - floor(uv.x * 48.0) - 0.5) * 12.0)
    * cupFloor * (1.0 - worn);
  // Nodules: domes of encrusting growth, 1.5 to 3 cm, over a part.
  let nod = cells(uv, 12, 31u);
  let crust = smoothstep(-0.1, 0.35, wavy(uv, 4, 32u) + 0.3 * wavy(uv, 9, 33u));
  let dome = (1.0 - smoothstep(0.0, 0.85, nod.x)) * crust;
  // The borers' holes: from a few millimetres to a centimetre and a half,
  // in some of the cells of two coarser grids, each its own size, a
  // little drawn out and ragged.
  let wobble = 0.05 * wavy(uv, 90, 42u);
  let boreA = cells(uv, 11, 41u);
  let boreB = cells(uv, 27, 43u);
  let rA = 0.12 + 0.2 * fract(boreA.z * 7.31);
  let rB = 0.1 + 0.18 * fract(boreB.z * 5.17);
  let boring = max(select(0.0, 1.0 - smoothstep(rA - 0.04, rA + 0.02, boreA.x + wobble), boreA.z < 0.18),
                   select(0.0, 1.0 - smoothstep(rB - 0.04, rB + 0.02, boreB.x + wobble), boreB.z < 0.22));
  // Grit: a millimetre.
  let g = cells(uv, 260, 51u);
  let grain = 1.0 - smoothstep(0.0, 0.55, g.x);
  // The crust is no smoother than the rock: its own pores and warts, a
  // couple of millimetres, over its domes; the corallites showing
  // through it, faintly.
  let pores = cells(uv, 110, 61u);
  let wart = (1.0 - smoothstep(0.0, 0.6, pores.x)) - 0.5 * (1.0 - smoothstep(0.0, 0.2, pores.x));
  s.height = 1.2 * swell + (cup + ribs) * mix(1.0, 0.35, crust) + 2.2 * dome
    + 0.7 * wart * crust - 4.0 * boring + 0.35 * grain;
  s.crust = crust;
  s.grit = g.z;
  // Brighter on what stands up and is worn, darker down the holes and in
  // the cups; the crust its own shade, mottled.
  s.bright = 0.5 + 0.08 * swell + 0.1 * worn * (1.0 - crust) - 0.25 * boring
    + 0.06 * (nod.z - 0.5) * crust + 0.05 * (g.z - 0.5);
  return s;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let texels = bake.tile.x;
  let uv = in.position.xy / texels;
  let here = surfaceAt(uv);
  if (bake.tile.z > 0.5) {
    return vec4f(clamp(here.bright, 0.0, 1.0), here.crust, 0.5 + 0.5 * (here.grit - 0.5), 1.0);
  }
  // The slope, by differences a texel either side, in millimetres a
  // millimetre; and the cavity: the height against the mean of a ring
  // a couple of millimetres about.
  let e = 1.0 / texels;
  let mmPerTexel = bake.tile.y * 1000.0 / texels;
  let dx = (surfaceAt(uv + vec2f(e, 0.0)).height - surfaceAt(uv - vec2f(e, 0.0)).height)
    / (2.0 * mmPerTexel);
  let dy = (surfaceAt(uv + vec2f(0.0, e)).height - surfaceAt(uv - vec2f(0.0, e)).height)
    / (2.0 * mmPerTexel);
  var ring = 0.0;
  for (var k = 0; k < 8; k++) {
    let a = f32(k) * 0.785398;
    ring += surfaceAt(uv + vec2f(cos(a), sin(a)) * 8.0 * e).height;
  }
  let cavity = clamp(0.5 + 0.12 * (here.height - ring / 8.0), 0.0, 1.0);
  return vec4f(clamp(0.5 + vec2f(dx, dy) * 0.25, vec2f(0.0), vec2f(1.0)), cavity,
               clamp((here.height + 6.0) / 10.0, 0.0, 1.0));
}
