// The ripples' tile, baked once at the start (`Reef/Ripples.lean`): the
// sand's wave ripples, in their own frame (the waves run along x, so the
// crests run along y), as a texture that repeats. Each texel: the height,
// 0 the lowest to 1 the highest; the slopes along x and y, in heights per
// wavelength, as (slope / 8 + 0.5); and the cavity, how much of the sky a
// point in a trough sees, 1 all of it. `shaders/sand.wgsl` reads them.
//
// The ripples are phasor noise (Tricard et al., "Procedural Phasor
// Noise", 2019): a sum of kernels, bumps, each carrying a plane wave,
// whose phase, where they interfere, is a field that oscillates at about
// the ripples' frequency everywhere. Each kernel's wave is the ripples'
// direction and frequency as a smooth field has them at the kernel: so
// neighbours agree, the crests bend as the field does, and where it
// bends enough that a crest must end or fork, one does, as ripples'
// crests do. A profile of the phase is the height: a long gentle rise to
// a sharp crest, a short steep fall down its lee, a round trough. On
// that, small ripples, the same field at a few times the frequency, and
// scour pits, hollows scattered sparsely and sunk where the troughs are.
// The field is periodic over the tile, and each wave has a whole number
// of cycles across it, so the tile repeats.
//
// Two passes: `fs_height` writes the height alone (a kernel sum a texel);
// `fs_finish` reads it back for the slopes and the cavity, which need the
// height at many points each.

struct Bake {
  // Ripples across the tile; how far the ripples' direction strays from
  // the waves', in radians; how far out of step the kernels are, 0 none
  // to 1 wholly; the crests' sharpness, a power.
  shape : vec4f,
  // The ripples' steepness, trough to crest over the wavelength, for the
  // cavity; the tile's texels a side; how much of the wavelength the
  // gentle rise takes, 0.5 symmetric; the small ripples' height, as a
  // fraction of the ripples'.
  size  : vec4f,
  // The pits: how many a wavelength's square (0 to 1); their depth, as a
  // fraction of the ripples' height; z, w unused.
  pits  : vec4f,
}

@group(0) @binding(0) var<uniform> bake : Bake;
@group(0) @binding(1) var heights : texture_2d<f32>;

const tau = 6.283185307;
const kernelsPerCell = 4u;
// The direction's and the frequency's fields: this many features across
// the tile.
const bends = 4.0;
// The small ripples: this many to one of the ripples.
const fineRipples = 4.0;
// A pit's half-width across the trough and along it, in wavelengths:
// under 1, so that the cells around a point hold every pit reaching it.
const pitAcross = 0.35;
const pitAlong = 0.7;
// The small ripples come in patches: this many across the tile.
const patches = 8.0;

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
  var h = cellSeed(p, period, 0u);
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

// The ripples' wave at `p`, in tile units, for ripples `scale` times as
// fine as the ripples: their direction, which strays from the waves' by
// up to the spread (the small ripples straying further, on their own
// account), and their frequency, which strays by a tenth, each as a
// smooth field over the tile; in cycles across the tile, whole, so that
// the tile repeats.
fn waveAt(p : vec2f, scale : f32) -> vec2f {
  var angle = bake.shape.y * noise(p * bends, i32(bends));
  if (scale > 1.0) {
    angle += 0.35 * noise(p * bends * 2.0 + 5.0, i32(bends * 2.0));
  }
  let frequency = bake.shape.x * (1.0 + 0.1 * noise(p * bends + 17.0, i32(bends)));
  return round(scale * frequency * vec2f(cos(angle), sin(angle)));
}

// The kernels' sum at `p`, in tile units (0 to 1 across the tile, and
// on, the tile repeating), and their weights' sum, for ripples `scale`
// times as fine as the ripples (1 the ripples themselves): the phase is
// the sum's argument; its length against the weights' says how far the
// kernels agree there. The kernels sit in cells two wavelengths wide, a
// few to a cell, each a bump a cell wide, those of the cells around `p`
// summed; a cell's kernels are those of its cell in the tile, so that
// the tile repeats.
fn phasor(p : vec2f, scale : f32) -> vec3f {
  let disorder = bake.shape.z;
  let cells = bake.shape.x * scale / 2.0;
  let n = i32(cells);
  let base = vec2i(floor(p * cells));
  var sum = vec2f(0.0);
  var weights = 0.0;
  for (var j = -1; j <= 1; j++) {
    for (var i = -1; i <= 1; i++) {
      let cell = base + vec2i(i, j);
      for (var k = 0u; k < kernelsPerCell; k++) {
        let seed = cellSeed(cell, n, k * 0xcb1ab31fu + u32(scale) * 0x3d4d51cbu);
        let centre = (vec2f(cell) + vec2f(rand(seed, 0u), rand(seed, 1u))) / cells;
        let wave = waveAt(centre, scale);
        // A bump a cell wide, and nothing beyond: the cells around are
        // all that is summed, and a kernel reaching past them would be
        // cut off at their edge, a line through the tile.
        let d = (p - centre) * cells;
        let r2 = dot(d, d);
        let weight = select(0.0, (1.0 - r2) * (1.0 - r2), r2 < 1.0);
        // The wave's phase from the tile's origin, not the kernel's: so
        // kernels of one wave agree, and only those of different waves,
        // or put out of step, interfere.
        let phi = tau * (dot(wave, p) + disorder * rand(seed, 2u));
        sum += weight * vec2f(cos(phi), sin(phi));
        weights += weight;
      }
    }
  }
  return vec3f(sum, weights);
}

// How far the crests are rounded: a little, so that the normal has no
// one-texel cusp to show as a line along every crest.
const rounding = 0.03;

// The height for a phase, were the ripples symmetric: 1 at a crest
// (phase 0), 0 in a trough; the crests sharp (though rounded a little)
// and the troughs round, more so the lower the power.
fn symmetric(phi : f32) -> f32 {
  let p = bake.shape.w;
  let lo = pow(rounding, p);
  let hi = pow(1.0 + rounding, p);
  return 1.0 - (pow((1.0 - cos(phi)) * 0.5 + rounding, p) - lo) / (hi - lo);
}

// The height for a phase: the symmetric profile's, with the cycle
// warped so that the fall from the crest down its lee (the phase runs
// along the waves) takes the short part of the wavelength and the rise
// up the next the long part. The trough, where the symmetric profile is
// flat, stays smooth across the warp's kink; the crest is a kink anyway.
fn profile(phi : f32) -> f32 {
  let rise = bake.size.z;
  let fall = 1.0 - rise;
  let t = fract(phi / tau);
  let warped = select(0.5 + 0.5 * (t - fall) / rise, 0.5 * t / fall, t < fall);
  return symmetric(tau * warped);
}

// The ripples' height from the kernels' sum `s`: the profile of the
// phase, tapering to the mean where the kernels disagree (the sum short
// against the weights), as a crest tapers out where it ends or forks;
// the phase alone would jump there, a cliff.
fn rippleOf(s : vec3f) -> f32 {
  let agreement = length(s.xy) / s.z;
  let taper = smoothstep(0.05, 0.25, agreement);
  return mix(0.5, profile(atan2(s.y, s.x)), taper);
}

// How much of a pit `p` is in, 0 none to 1 the bottom of one: pits are
// scattered one to some of the wavelength's squares, each a bowl longer
// along the troughs than across them.
fn pitsAt(p : vec2f) -> f32 {
  let n = i32(bake.shape.x);
  let base = vec2i(floor(p * f32(n)));
  var pit = 0.0;
  for (var j = -1; j <= 1; j++) {
    for (var i = -1; i <= 1; i++) {
      let cell = base + vec2i(i, j);
      let seed = cellSeed(cell, n, 0x5bd1e995u);
      if (rand(seed, 0u) < bake.pits.x) {
        let centre = (vec2f(cell) + vec2f(rand(seed, 1u), rand(seed, 2u))) / f32(n);
        let d = (p - centre) * f32(n) / vec2f(pitAcross, pitAlong);
        let q = dot(d, d);
        pit += select(0.0, (1.0 - q) * (1.0 - q), q < 1.0);
      }
    }
  }
  return min(pit, 1.0);
}

// The height at `p`: the ripples', the small ripples' on them, in
// patches, and the pits sunk into them where they are low (a pit on a
// crest is no pit), the three summed and scaled back to 0 to 1
// (`Reef.Ripples.height` is the sum's scale).
fn heightOf(p : vec2f) -> f32 {
  let fine = bake.size.w;
  let depth = bake.pits.y;
  let ripples = rippleOf(phasor(p, 1.0));
  let patchy = smoothstep(-0.2, 0.5, noise(p * patches + 31.0, i32(patches)));
  let small = mix(0.5, rippleOf(phasor(p, fineRipples)), patchy);
  let pit = pitsAt(p) * (1.0 - ripples);
  return (ripples + fine * small + depth * (1.0 - pit)) / (1.0 + fine + depth);
}

@fragment fn fs_height(in : Out) -> @location(0) vec4f {
  let uv = in.position.xy / bake.size.y;
  return vec4f(heightOf(uv), 0.0, 0.0, 1.0);
}

// The height baked at texel `t`, the tile repeating.
fn heightAt(t : vec2i) -> f32 {
  let n = i32(bake.size.y);
  return textureLoad(heights, ((t % n) + n) % n, 0).r;
}

@fragment fn fs_finish(in : Out) -> @location(0) vec4f {
  let t = vec2i(in.position.xy);
  let h = heightAt(t);
  // A texel, in wavelengths.
  let texel = bake.shape.x / bake.size.y;
  let sx = (heightAt(t + vec2i(1, 0)) - heightAt(t - vec2i(1, 0))) / (2.0 * texel);
  let sy = (heightAt(t + vec2i(0, 1)) - heightAt(t - vec2i(0, 1))) / (2.0 * texel);
  // The cavity: the horizon either way along x (across the crests), as
  // the highest rise over run out to a wavelength, at the height's
  // steepness (the ripples' and what is on them); what is left of the
  // sky between the two.
  let steepness = bake.size.x * (1.0 + bake.size.w + bake.pits.y);
  let steps = 16;
  let stride = max(1, i32(1.0 / texel) / steps);
  var tanP = 0.0;
  var tanM = 0.0;
  for (var i = 1; i <= steps; i++) {
    let run = f32(i * stride) * texel;
    tanP = max(tanP, (heightAt(t + vec2i(i * stride, 0)) - h) * steepness / run);
    tanM = max(tanM, (heightAt(t - vec2i(i * stride, 0)) - h) * steepness / run);
  }
  let cavity = 1.0 - 0.5 * (tanP / sqrt(1.0 + tanP * tanP)
                            + tanM / sqrt(1.0 + tanM * tanM));
  return vec4f(h, sx / 8.0 + 0.5, sy / 8.0 + 0.5, cavity);
}
