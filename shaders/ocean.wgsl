// The sea's surface, one tile of it, for a moment (`Reef/Caustics.lean`):
// Tessendorf's, a spectrum of waves summed by a fast Fourier transform.
// The spectrum (Phillips's) says how high each wave is for its length
// and its direction against the wind's, with a random phase and
// amplitude of its own; each wave moves at the speed deep water gives
// its length, its frequency rounded to a multiple of the loop's, so the
// surface repeats in time as it does in space. The transform sums them
// into the height at each point of a grid over the tile, and likewise
// the slope along x and along z (each wave's slope its height times its
// wave number): three fields, three transforms, into `field`.
//
// Three kernels: `spectrum` fills `spec` with one field's waves at the
// moment; `rows` transforms each row of it into `tmp`; `columns` each
// column of that into the field's component of `field`. A transform is
// one workgroup to a row, each thread one element, the row in workgroup
// memory, the butterflies in place a stage at a time.

const N = 256u;
const tau = 6.283185307;
const gravity = 9.81;

struct Sea {
  // The tile's width, in metres; the moment, in seconds; the loop's
  // length, in seconds; which field: 0 the height, 1 the slope along x,
  // 2 along z.
  tile      : f32,
  time      : f32,
  period    : f32,
  component : u32,
  // The wind's speed, in metres a second, and direction; how high the
  // waves are, a factor; the shortest wave kept, in metres.
  wind      : f32,
  windX     : f32,
  windZ     : f32,
  amplitude : f32,
  shortest  : f32,
  pad0      : f32,
  pad1      : f32,
  pad2      : f32,
}

@group(0) @binding(0) var<uniform> sea : Sea;
@group(0) @binding(1) var<storage, read_write> spec : array<vec2f>;
@group(0) @binding(2) var<storage, read_write> tmp : array<vec2f>;
@group(0) @binding(3) var<storage, read_write> field : array<vec4f>;

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

// Two numbers from a Gaussian, mean 0, spread 1, for the cell `c`.
fn gaussian(c : vec2u) -> vec2f {
  let seed = (c.x * 0x8da6b343u) ^ (c.y * 0xd8163841u);
  let u1 = max(rand(seed, 0u), 1e-6);
  let u2 = rand(seed, 1u);
  let r = sqrt(-2.0 * log(u1));
  return r * vec2f(cos(tau * u2), sin(tau * u2));
}

// The wave vector of cell `c`: the grid's cells run from -N/2 to N/2 - 1
// in each direction, in cycles across the tile.
fn waveVector(c : vec2u) -> vec2f {
  return (vec2f(c) - f32(N) / 2.0) * tau / sea.tile;
}

// How high the waves of wave vector `k` are, squared, by Phillips's
// spectrum: most in the wind's direction, at lengths about the wind
// makes, none the shortest.
fn phillips(k : vec2f) -> f32 {
  let kLen = length(k);
  if (kLen < 1e-4) { return 0.0; }
  let L = sea.wind * sea.wind / gravity;
  let wind = normalize(vec2f(sea.windX, sea.windZ));
  let along = dot(k / kLen, wind);
  let kL = kLen * L;
  let shortest = sea.shortest;
  return sea.amplitude * exp(-1.0 / (kL * kL)) / (kLen * kLen * kLen * kLen)
    * along * along * exp(-kLen * kLen * shortest * shortest);
}

// The wave of cell `c` at time 0: its amplitude and phase, complex.
fn wave0(c : vec2u) -> vec2f {
  return gaussian(c) * sqrt(phillips(waveVector(c)) * 0.5);
}

// Complex multiplication.
fn cmul(a : vec2f, b : vec2f) -> vec2f {
  return vec2f(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

@compute @workgroup_size(16, 16)
fn spectrum(@builtin(global_invocation_id) id : vec3u) {
  let c = id.xy;
  let k = waveVector(c);
  // The wave at time t: its own turning one way, and its mirror's
  // conjugate the other, so that the sum is real.
  let mirror = vec2u((N - c.x) % N, (N - c.y) % N);
  let omega0 = tau / sea.period;
  let omega = max(1.0, round(sqrt(gravity * length(k)) / omega0)) * omega0;
  let phase = omega * sea.time;
  let turn = vec2f(cos(phase), sin(phase));
  let back = vec2f(turn.x, -turn.y);
  let m = wave0(mirror);
  var h = cmul(wave0(c), turn) + cmul(vec2f(m.x, -m.y), back);
  // The slopes: the height times i k.
  if (sea.component == 1u) { h = vec2f(-h.y, h.x) * k.x; }
  if (sea.component == 2u) { h = vec2f(-h.y, h.x) * k.y; }
  spec[c.y * N + c.x] = h;
}

var<workgroup> a : array<vec2f, N>;
var<workgroup> b : array<vec2f, N>;

// `n`'s bits reversed, the low `bits` of them.
fn reversed(n : u32, bits : u32) -> u32 {
  var r = 0u;
  var v = n;
  for (var i = 0u; i < bits; i++) {
    r = (r << 1u) | (v & 1u);
    v = v >> 1u;
  }
  return r;
}

// The inverse transform of the row in `a` (loaded in bit-reversed
// order), in place through `b`, by thread `i` of its workgroup: the
// result is in `a` if the stages are even, else `b`.
fn transform(i : u32) -> vec2f {
  var fromA = true;
  for (var s = 1u; s < N; s = s << 1u) {
    let j = i & (s - 1u);
    let angle = tau * f32(j) / f32(2u * s);
    let w = vec2f(cos(angle), sin(angle));
    let upper = (i & s) == 0u;
    var result : vec2f;
    if (fromA) {
      if (upper) { result = a[i] + cmul(w, a[i + s]); }
      else { result = a[i - s] - cmul(w, a[i]); }
    } else {
      if (upper) { result = b[i] + cmul(w, b[i + s]); }
      else { result = b[i - s] - cmul(w, b[i]); }
    }
    workgroupBarrier();
    if (fromA) { b[i] = result; } else { a[i] = result; }
    workgroupBarrier();
    fromA = !fromA;
  }
  if (fromA) { return a[i]; }
  return b[i];
}

@compute @workgroup_size(N)
fn rows(@builtin(workgroup_id) group : vec3u,
        @builtin(local_invocation_id) local : vec3u) {
  let row = group.x;
  let i = local.x;
  a[reversed(i, 8u)] = spec[row * N + i];
  workgroupBarrier();
  tmp[row * N + i] = transform(i);
}

@compute @workgroup_size(N)
fn columns(@builtin(workgroup_id) group : vec3u,
           @builtin(local_invocation_id) local : vec3u) {
  let column = group.x;
  let i = local.x;
  a[reversed(i, 8u)] = tmp[i * N + column];
  workgroupBarrier();
  let value = transform(i).x;
  // The grid's cells were centred: the sum is of the cell's position
  // shifted by half the grid, a sign a cell.
  let sign = select(1.0, -1.0, ((column + i) & 1u) == 1u);
  let index = i * N + column;
  var f = field[index];
  if (sea.component == 0u) { f.x = value * sign; }
  if (sea.component == 1u) { f.y = value * sign; }
  if (sea.component == 2u) { f.z = value * sign; }
  field[index] = f;
}
