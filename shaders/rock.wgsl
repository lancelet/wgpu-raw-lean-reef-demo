// The reef rock's shape (`Reef/Bommies.lean`), shared by its bake
// (shaders/reefbake.wgsl), which meshes it, and its draw
// (shaders/bommie.wgsl), which shades what the mesh cannot carry.
//
// The rock is a sum of bands, each of a known wavelength, from the
// bommies' mass, metres across, down to grit of a millimetre and a half.
// A level of the mesh, its cells `cell` wide, holds the bands at least
// four cells long, the band at its limit fading out from four cells to
// two, and none shorter (`meshHolds`). The shading carries every band the
// mesh leaves out, by the same functions and the complementary weights,
// as a bending of the normal and a darkening of the hollows; until a
// band is shorter than a pixel, where it fades too (into the roughness it
// is). So whatever the level, the rock at a pixel has every band, split
// differently between mesh and shading: a level giving way to another
// shifts bands from one to the other, and changes nothing to be seen.
// (Nanite's rule, that a coarser level is the finer simplified within an
// error, and is switched to only where the error is too small to see,
// here by the band.)

fn rockHash(p : vec3i) -> f32 {
  var h = (u32(p.x) * 0x8da6b343u) ^ (u32(p.y) * 0xd8163841u) ^ (u32(p.z) * 0xcb1ab31fu);
  h = h ^ (h >> 15u);
  h = h * 0x2c1b3c6du;
  h = h ^ (h >> 12u);
  h = h * 0x297a2d39u;
  h = h ^ (h >> 15u);
  return f32(h & 0xffffffu) / 16777216.0;
}

// Value noise in three dimensions, smooth, -1 to 1, a feature a unit
// wide; with its gradient (value, d/dx, d/dy, d/dz).
fn rockNoiseGrad(p : vec3f) -> vec4f {
  let i = vec3i(floor(p));
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  let du = 6.0 * f * (1.0 - f);
  let a = rockHash(i);
  let b = rockHash(i + vec3i(1, 0, 0));
  let c = rockHash(i + vec3i(0, 1, 0));
  let d = rockHash(i + vec3i(1, 1, 0));
  let e = rockHash(i + vec3i(0, 0, 1));
  let g = rockHash(i + vec3i(1, 0, 1));
  let h = rockHash(i + vec3i(0, 1, 1));
  let k = rockHash(i + vec3i(1, 1, 1));
  let k1 = b - a;
  let k2 = c - a;
  let k3 = e - a;
  let k4 = a - b - c + d;
  let k5 = a - c - e + h;
  let k6 = a - b - e + g;
  let k7 = -a + b + c - d + e - g - h + k;
  let value = a + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z
    + k6 * u.z * u.x + k7 * u.x * u.y * u.z;
  let grad = du * vec3f(k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
                        k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
                        k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y);
  return vec4f(value * 2.0 - 1.0, grad * 2.0);
}

fn rockNoise(p : vec3f) -> f32 {
  return rockNoiseGrad(p).x;
}

fn rockFbm(p : vec3f) -> f32 {
  return 0.55 * rockNoise(p) + 0.3 * rockNoise(p * 2.03 + 11.0) + 0.15 * rockNoise(p * 4.1 + 23.0);
}

// Ridged noise: 1 on the ridges, falling sharply either side.
fn rockRidged(p : vec3f) -> f32 {
  let r = 1.0 - abs(rockNoise(p));
  return r * r;
}

// The distance to the nearest of a scatter of points, one to each unit
// cell: small near the points, which become holes.
fn rockWorley(p : vec3f) -> f32 {
  let base = vec3i(floor(p));
  var best = 9.0;
  for (var z = -1; z <= 1; z++) {
    for (var y = -1; y <= 1; y++) {
      for (var x = -1; x <= 1; x++) {
        let c = base + vec3i(x, y, z);
        let at = vec3f(c) + vec3f(rockHash(c), rockHash(c + vec3i(17, 0, 0)), rockHash(c + vec3i(0, 31, 0)));
        best = min(best, length(p - at));
      }
    }
  }
  return best;
}

fn rockSmoothMin(a : f32, b : f32, k : f32) -> f32 {
  let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}

// How much of a band of wavelength `lambda` a mesh of cells `cell` holds.
fn meshHolds(lambda : f32, cell : f32) -> f32 {
  return smoothstep(2.0 * cell, 4.0 * cell, lambda);
}

// The fine bands: eight octaves, from a fifth of a metre to a millimetre
// and a half, each half the last; crags (ridged) in the coarser three,
// knobs and grit below. Each a height out of the rock, metres.
const rockBandCount = 8;

fn bandFrequency(i : i32) -> f32 {
  return 4.6 * exp2(f32(i));
}

// Band `i` at `p`: its height, and its gradient.
fn rockBand(p : vec3f, i : i32) -> vec4f {
  let f = bandFrequency(i);
  let amplitude = 0.032 * pow(0.55, f32(i));
  let n = rockNoiseGrad(p * f + vec3f(7.0, 13.0, 3.0) * f32(i + 1));
  if (i < 3) {
    let r = 1.0 - abs(n.x);
    let dr = -sign(n.x) * n.yzw * f;
    return amplitude * vec4f(r * r - 0.4, 2.0 * r * dr);
  }
  return amplitude * vec4f(n.x, n.yzw * f);
}

// The bands a mesh of cells `cell` holds, at `p`: their height.
fn rockBandsForMesh(p : vec3f, cell : f32) -> f32 {
  var h = 0.0;
  for (var i = 0; i < rockBandCount; i++) {
    let w = meshHolds(1.0 / bandFrequency(i), cell);
    if (w <= 0.0) { break; }
    h += w * rockBand(p, i).x;
  }
  return h;
}

// The bands the mesh of cells `cell` does not hold, at `p`, for a pixel
// `pixel` metres across there: their height and gradient, each fading out
// as it shrinks below the pixel.
fn rockBandsForShading(p : vec3f, cell : f32, pixel : f32) -> vec4f {
  var h = vec4f(0.0);
  for (var i = 0; i < rockBandCount; i++) {
    let lambda = 1.0 / bandFrequency(i);
    let seen = smoothstep(1.5 * pixel, 4.0 * pixel, lambda);
    if (seen <= 0.0) { break; }
    let w = (1.0 - meshHolds(lambda, cell)) * seen;
    if (w > 0.0) { h += w * rockBand(p, i); }
  }
  return h;
}

// The rock's signed distance at `p`, negative in it, for a mesh of cells
// `cell`, given the distance to its mass (the bommies' blobs, joined).
// Old reef rock is coral heads, plates and rubble cemented together and
// eaten away, so it is built so:
//   its place warped, so nothing is round;
//   eroded: lumps, sharp creases (the folded noise's valleys), crags;
//   the domes of coral heads, crowded over it, bulging from it;
//   holes: the erosion's, and the borers';
//   and the fine bands, as the mesh can hold them.
// Every feature narrower than the mesh can hold is faded out of it
// (`meshHolds`), so the coarser level is the finer smoothed.
fn rockSurface(p : vec3f, mass : f32, cell : f32) -> f32 {
  if (mass > 1.2) { return mass; }
  var d = mass;
  let q = p + 0.3 * vec3f(rockFbm(p * 0.55), rockFbm(p * 0.55 + 5.1), rockFbm(p * 0.55 + 9.7));
  // (Their slopes kept, together, under the surface's own: a
  // displacement that changes faster than the surface it moves pinches
  // off islands, which float.)
  d += 0.2 * rockFbm(q * 0.8);
  d += 0.12 * abs(rockNoise(q * 1.3 + 4.0)) - 0.05;
  d -= meshHolds(0.45, cell) * (0.08 * rockRidged(q * 2.2 + 13.0) - 0.03);
  // (And nothing stands more than a little proud of the mass.)
  d = max(d, mass - 0.12);
  // The domes: half-sunk heads, a fifth to two fifths of a metre, bulging
  // no further from the rock than most of their radius.
  let domes = meshHolds(0.3, cell);
  if (d < 0.5 && domes > 0.0) {
    let g = q / 0.65;
    let base = vec3i(floor(g));
    var withDomes = d;
    for (var z = 0; z <= 1; z++) {
      for (var y = 0; y <= 1; y++) {
        for (var x = 0; x <= 1; x++) {
          let c = base + vec3i(x, y, z);
          let at = (vec3f(c) + vec3f(rockHash(c), rockHash(c + vec3i(5, 0, 0)), rockHash(c + vec3i(0, 7, 0)))) * 0.65;
          let r = 0.1 + 0.12 * rockHash(c + vec3i(0, 0, 11));
          if (rockHash(c + vec3i(3, 3, 3)) < 0.55) {
            withDomes = rockSmoothMin(withDomes, max(length(q - at) - r, d - 0.6 * r), 0.05);
          }
        }
      }
    }
    d = mix(d, withDomes, domes);
  }
  // Holes: the erosion's, a quarter metre, and the borers', a few
  // centimetres, crowded in places.
  d = max(d, -(rockWorley(p * 1.1 + 3.0) - 0.26) / 1.1);
  let borers = meshHolds(0.25, cell);
  if (borers > 0.0) {
    let bored = smoothstep(-0.1, 0.4, rockNoise(p * 0.9 + 51.0));
    let w2 = rockWorley(p * 3.2 + 8.0);
    d = mix(d, max(d, -(w2 - 0.22 * bored) / 3.2), borers);
  }
  // The fine bands the mesh holds.
  if (d < 0.2) { d -= rockBandsForMesh(p, cell); }
  return d;
}
