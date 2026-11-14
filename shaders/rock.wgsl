// The reef rock's shape (`Reef/Bommies.lean`), shared by its bake
// (shaders/reefbake.wgsl) and its draw (shaders/bommie.wgsl), in two
// parts:
//
// The mass (`rockMass`): the bommies' blobs, warped, lumped and creased,
// nothing in it narrower than half a metre,
// so that a grid of ten centimetres holds it whole, and nothing comes
// loose of it. Baked once into the reef's field, and meshed.
//
// The detail (`rockDisplacement`): crags, the domes of coral heads, the
// borers' pits, and finer erosion down to a millimetre, as a displacement
// of the mass's surface, out and in, by bands of a baked noise. A
// displacement of bounded slope cannot pinch off an island. Drawn per
// pixel: the mass's mesh, inflated to hold all of it, is rasterised, and
// each pixel marches in from it to the rock (shaders/bommie.wgsl), with
// every band at least a couple of pixels long, each fading in as it grows
// past that. There are no levels: nothing switches, at any distance.

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

// The bands' noise: value noise with its gradient, repeating every
// `bandPeriod` of its features, baked into a 3D texture (`bakeBandNoise`,
// shaders/reefbake.wgsl) with `bandTexels` texels to a feature, which
// the bake and the draw both read (`bandNoise`, each with its own
// binding): one filtered read a band, not eight hashes.
const bandPeriod = 32;
const bandTexels = 4;

fn rockHashWrapped(p : vec3i) -> f32 {
  return rockHash(((p % bandPeriod) + bandPeriod) % bandPeriod);
}

// The bands' noise at `p`, as baked: value, gradient.
fn bandNoiseExact(p : vec3f) -> vec4f {
  let i = vec3i(floor(p));
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  let du = 6.0 * f * (1.0 - f);
  let a = rockHashWrapped(i);
  let b = rockHashWrapped(i + vec3i(1, 0, 0));
  let c = rockHashWrapped(i + vec3i(0, 1, 0));
  let d = rockHashWrapped(i + vec3i(1, 1, 0));
  let e = rockHashWrapped(i + vec3i(0, 0, 1));
  let g = rockHashWrapped(i + vec3i(1, 0, 1));
  let h = rockHashWrapped(i + vec3i(0, 1, 1));
  let k = rockHashWrapped(i + vec3i(1, 1, 1));
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

// The bommies' mass at `p`, given the distance to their blobs, joined.
fn rockMass(p : vec3f, blobs : f32) -> f32 {
  if (blobs > 1.2) { return blobs; }
  var d = blobs;
  let q = p + 0.3 * vec3f(rockFbm(p * 0.55), rockFbm(p * 0.55 + 5.1), rockFbm(p * 0.55 + 9.7));
  // Lumps and hollows of a metre; creases, folded.
  d += 0.2 * rockFbm(q * 0.8);
  d += 0.12 * abs(rockNoise(q * 1.3 + 4.0)) - 0.05;
  d = max(d, blobs - 0.12);
  // (No holes cut through it: the detail's pits, bounded in depth, are
  // its hollows; a void cut through a thin part of the mass leaves it
  // see-through, or a piece of it loose.)
  return d;
}

// The detail's bands: the noise's frequency (features a metre), its
// amplitude (metres, out of the rock), and its kind: 0 noise, 1 crags
// (ridged), 2 domes (rounded bumps), 3 pits (rounded hollows). Coarsest
// first.
const detailBandCount = 12;

fn detailBand(i : i32) -> vec4f {
  if (i == 0) { return vec4f(2.2, 0.07, 1.0, 0.0); }
  if (i == 1) { return vec4f(1.6, 0.06, 2.0, 0.0); }
  if (i == 2) { return vec4f(3.3, 0.04, 3.0, 0.0); }
  if (i == 3) { return vec4f(4.6, 0.03, 1.0, 0.0); }
  if (i == 4) { return vec4f(9.2, 0.014, 1.0, 0.0); }
  if (i == 5) { return vec4f(7.0, 0.012, 3.0, 0.0); }
  if (i == 6) { return vec4f(18.0, 0.006, 0.0, 0.0); }
  if (i == 7) { return vec4f(37.0, 0.003, 0.0, 0.0); }
  if (i == 8) { return vec4f(75.0, 0.0015, 0.0, 0.0); }
  if (i == 9) { return vec4f(150.0, 0.0008, 0.0, 0.0); }
  if (i == 10) { return vec4f(300.0, 0.0004, 0.0, 0.0); }
  return vec4f(600.0, 0.0002, 0.0, 0.0);
}

// The first three bands, the coarsest (crags, domes and pits of half a
// metre or so), the reef's field holds, baked with the mass: a grid of
// ten centimetres holds them well. The rest are the march's. The most
// those lift the rock out of the field's surface, and sink it in, in
// metres: the mesh is inflated by the first and a little
// (`Reef.reefIso`), and a pixel's march goes in no further than both.
const bakedBands = 3;
const detailOut = 0.06;
const detailIn = 0.02;
// The most the bands after the first `bakedBands + 3` lift or sink the
// rock: the march's first phase, with only the three before them, stops
// this far short.
const fineReach = 0.013;

// The detail at `p`, its height out of the rock and its gradient, with
// each band weighted by how much longer it is than `footprint` metres
// (from `lo` footprints, none, to `hi`, all of it); and, apart, the fine
// bands' height alone, for darkening their hollows.
struct Detail {
  height : vec4f,
  fine   : f32,
}

fn rockDisplacement(p : vec3f, footprint : f32, lo : f32, hi : f32, first : i32, last : i32) -> Detail {
  var r : Detail;
  for (var i = first; i < last; i++) {
    let band = detailBand(i);
    let lambda = 1.0 / band.x;
    // (For the geometry, `lo` > 1, a band also only where it is tall
    // enough to move the rock by half a footprint: below that it is the
    // normal's alone. Nanite's measure: the error, in pixels.)
    var w = smoothstep(lo * footprint, hi * footprint, lambda);
    if (lo > 1.5) { w *= smoothstep(0.25 * footprint, 0.5 * footprint, band.y); }
    if (w <= 0.0) { break; }
    let n = bandNoise(p * band.x + vec3f(7.0, 13.0, 3.0) * f32(i + 1));
    let g = n.yzw * band.x;
    var h = vec4f(n.x, g);
    if (band.z == 1.0) {
      let k = 1.0 - abs(n.x);
      h = vec4f(k * k, -2.0 * k * sign(n.x) * g);
    } else if (band.z == 2.0) {
      let t = clamp(n.x * 1.25, 0.0, 1.0);
      h = vec4f(t * t * (3.0 - 2.0 * t), select(vec3f(0.0), 6.0 * t * (1.0 - t) * 1.25 * g, n.x > 0.0 && n.x < 0.8));
    } else if (band.z == 3.0) {
      let t = clamp((n.x - 0.35) * 2.5, 0.0, 1.0);
      h = -vec4f(t * t * (3.0 - 2.0 * t), select(vec3f(0.0), 6.0 * t * (1.0 - t) * 2.5 * g, n.x > 0.35 && n.x < 0.75));
    }
    r.height += w * band.y * h;
    if (i >= 6) { r.fine += w * band.y * h.x; }
  }
  return r;
}
