// The reef's framework, baked once at the start (`Reef/Bommies.lean`):
// the bommies, mounds of old reef limestone rising out of the sand, as a
// signed distance field over a box of the floor, and a mesh of its
// surface. Four passes:
//
// `field`: the distance at every point of a grid over the box, into a 3D
// texture: the bommies' blobs (ellipsoids, narrower at the base, the
// undercut a bommie has where the sand has scoured it) smoothly joined;
// weathered by layered noise; pocked with holes, the erosion and the
// borings of what lives in the rock.
//
// `vertices`: surface nets: in each cell of the grid that the surface
// crosses, one vertex, at the mean of the crossings on the cell's edges;
// its normal from the field's gradient; its ambient occlusion, how much
// rock is about it along its normal; and its shadow, marched through the
// field toward the sun.
//
// `faces`: for each edge of the grid the surface crosses, a quad of the
// four cells about it.
//
// `count`: the draw's arguments, from the counts.

struct Bake {
  origin    : vec3f,  // the box's corner, in the world
  cell      : f32,    // a cell's width, in metres
  dims      : vec3u,  // the grid's points along x, y, z
  blobCount : u32,
  sun       : vec3f,  // where the sun's light comes from, under the water
  fine      : f32,    // 1 for the fine level near the camera (its finest octaves), 0 the whole reef's
  // The field pass's slab of the grid: its first z, and how many; the
  // most vertices and indices the mesh's buffers hold.
  slab      : vec4u,
}

struct Vertex {
  position : vec3f,
  ao       : f32,
  normal   : vec3f,
  shadow   : f32,
}

@group(0) @binding(0) var<uniform> bake : Bake;
// Two to a blob: centre and radius; height's share of the radius, how much
// narrower at the base, a seed, unused.
@group(0) @binding(1) var<storage, read> blobs : array<vec4f>;
@group(0) @binding(2) var fieldOut : texture_storage_3d<r32float, write>;
@group(0) @binding(3) var fieldIn : texture_3d<f32>;
@group(0) @binding(4) var<storage, read_write> vertices : array<Vertex>;
@group(0) @binding(5) var<storage, read_write> cellIndex : array<u32>;
@group(0) @binding(6) var<storage, read_write> counts : array<atomic<u32>, 2>;
@group(0) @binding(7) var<storage, read_write> indices : array<u32>;
@group(0) @binding(8) var<storage, read_write> args : array<u32, 5>;

const none = 0xffffffffu;

// (The noise and the rock's surface are shaders/rock.wgsl's, which
// `Reef/Bommies.lean` puts before this.)

// A blob: an ellipsoid above its middle; below, a column, narrowing to
// its base and on down into the sand, so that nothing of the rock floats
// (the sand's scour would have undercut it and it would have fallen).
fn blob(p : vec3f, i : u32) -> f32 {
  let a = blobs[2u * i];
  let b = blobs[2u * i + 1u];
  var q = p - a.xyz;
  let half = a.w * b.x;
  let lift = clamp((q.y + half) / (2.0 * half), 0.0, 1.0);
  let widen = mix(1.0 - b.y, 1.0, smoothstep(0.0, 0.6, lift));
  q.y = max(q.y, 0.0);
  let r = vec3f(a.w * widen, half, a.w * widen);
  return (length(q / r) - 1.0) * min(r.x, r.y);
}

// The framework's signed distance at `p`: negative in the rock. The
// bommies' mass, their blobs joined only a little (lumps, not one melted
// shape); and on it the rock's surface (shaders/rock.wgsl), as finely as
// this level's cells can hold.
fn sdf(p : vec3f) -> f32 {
  var mass = 1e5;
  for (var i = 0u; i < bake.blobCount; i++) {
    mass = rockSmoothMin(mass, blob(p, i), 0.35);
  }
  return rockSurface(p, mass, bake.cell);
}

fn fieldAt(i : vec3i) -> f32 {
  return textureLoad(fieldIn, i, 0).r;
}

@compute @workgroup_size(4, 4, 4)
fn field(@builtin(global_invocation_id) gid : vec3u) {
  // (A slab of the grid at a time: the fine level is baked over a few
  // frames, a slab each, so that no frame takes the whole of it.)
  if (gid.z >= bake.slab.y) { return; }
  let id = gid + vec3u(0u, 0u, bake.slab.x);
  if (any(id >= bake.dims)) { return; }
  let p = bake.origin + vec3f(id) * bake.cell;
  textureStore(fieldOut, id, vec4f(sdf(p), 0.0, 0.0, 0.0));
}

fn cellLinear(c : vec3u) -> u32 {
  let cd = bake.dims - 1u;
  return (c.z * cd.y + c.y) * cd.x + c.x;
}

@compute @workgroup_size(4, 4, 4)
fn vertexPass(@builtin(global_invocation_id) id : vec3u) {
  let cd = bake.dims - 1u;
  if (any(id >= cd)) { return; }
  let i = vec3i(id);
  var f : array<f32, 8>;
  var inside = 0u;
  for (var k = 0u; k < 8u; k++) {
    let o = vec3i(i32(k & 1u), i32((k >> 1u) & 1u), i32((k >> 2u) & 1u));
    f[k] = fieldAt(i + o);
    if (f[k] < 0.0) { inside++; }
  }
  let linear = cellLinear(id);
  if (inside == 0u || inside == 8u) { cellIndex[linear] = none; return; }
  // The mean of the crossings on the cell's twelve edges.
  var sum = vec3f(0.0);
  var n = 0.0;
  for (var k = 0u; k < 8u; k++) {
    for (var axis = 0u; axis < 3u; axis++) {
      let bit = 1u << axis;
      if ((k & bit) != 0u) { continue; }
      let other = k | bit;
      if ((f[k] < 0.0) == (f[other] < 0.0)) { continue; }
      let t = f[k] / (f[k] - f[other]);
      let a = vec3f(f32(k & 1u), f32((k >> 1u) & 1u), f32((k >> 2u) & 1u));
      let b = vec3f(f32(other & 1u), f32((other >> 1u) & 1u), f32((other >> 2u) & 1u));
      sum += mix(a, b, t);
      n += 1.0;
    }
  }
  let p = bake.origin + (vec3f(i) + sum / n) * bake.cell;
  // The normal, from the field's gradient.
  let e = bake.cell * 0.5;
  let g = vec3f(sdf(p + vec3f(e, 0.0, 0.0)) - sdf(p - vec3f(e, 0.0, 0.0)),
                sdf(p + vec3f(0.0, e, 0.0)) - sdf(p - vec3f(0.0, e, 0.0)),
                sdf(p + vec3f(0.0, 0.0, e)) - sdf(p - vec3f(0.0, 0.0, e)));
  let normal = normalize(g + vec3f(0.0, 1e-6, 0.0));
  // Ambient occlusion: how much rock is about it, out along its normal.
  var occlusion = 0.0;
  for (var s = 1; s <= 4; s++) {
    let step = 0.12 * f32(s * s);
    occlusion += max(step - sdf(p + normal * step), 0.0) / step;
  }
  let ao = clamp(1.0 - occlusion * 0.35, 0.0, 1.0);
  // The sun's shadow: marched through the field toward it, softly.
  // (As shaders/bommie.wgsl's `rockShadow` marches it, which takes over
  // between the vertices where it changes: the same, so the two meet.)
  var t = 0.06;
  var lit = 1.0;
  for (var s = 0; s < 48; s++) {
    let h = sdf(p + normal * 0.04 + bake.sun * t);
    lit = min(lit, 0.5 + 0.5 * h / (0.05 * t + 0.015));
    t += clamp(h * 0.8, 0.03 + 0.03 * t, 0.5);
    if (lit <= 0.0 || t > 8.0) { break; }
  }
  lit = clamp(lit, 0.0, 1.0);
  let v = atomicAdd(&counts[0], 1u);
  if (v >= bake.slab.z) { cellIndex[linear] = none; return; }
  vertices[v] = Vertex(p, ao, normal, lit * lit * (3.0 - 2.0 * lit));
  cellIndex[linear] = v;
}

@compute @workgroup_size(4, 4, 4)
fn facePass(@builtin(global_invocation_id) id : vec3u) {
  if (any(id >= bake.dims)) { return; }
  let i = vec3i(id);
  let f0 = fieldAt(i);
  for (var axis = 0u; axis < 3u; axis++) {
    var e = vec3i(0);
    var u = vec3i(0);
    var w = vec3i(0);
    if (axis == 0u) { e = vec3i(1, 0, 0); u = vec3i(0, 1, 0); w = vec3i(0, 0, 1); }
    if (axis == 1u) { e = vec3i(0, 1, 0); u = vec3i(0, 0, 1); w = vec3i(1, 0, 0); }
    if (axis == 2u) { e = vec3i(0, 0, 1); u = vec3i(1, 0, 0); w = vec3i(0, 1, 0); }
    let j = i + e;
    if (any(j >= vec3i(bake.dims))) { continue; }
    let f1 = fieldAt(j);
    if ((f0 < 0.0) == (f1 < 0.0)) { continue; }
    // The four cells about the edge.
    let c0 = i - u - w;
    let c1 = i - w;
    let c2 = i;
    let c3 = i - u;
    let cd = vec3i(bake.dims) - 1;
    if (any(c0 < vec3i(0)) || any(c2 >= cd)) { continue; }
    let a = cellIndex[cellLinear(vec3u(c0))];
    let b = cellIndex[cellLinear(vec3u(c1))];
    let c = cellIndex[cellLinear(vec3u(c2))];
    let d = cellIndex[cellLinear(vec3u(c3))];
    if (a == none || b == none || c == none || d == none) { continue; }
    let at = atomicAdd(&counts[1], 6u);
    if (at + 6u > bake.slab.w) { continue; }
    // Wound to face out of the rock, whichever side of the edge it is on.
    var b2 = b;
    var d2 = d;
    if (f0 >= 0.0) { b2 = d; d2 = b; }
    indices[at] = a;
    indices[at + 1u] = b2;
    indices[at + 2u] = c;
    indices[at + 3u] = a;
    indices[at + 4u] = c;
    indices[at + 5u] = d2;
  }
}

@compute @workgroup_size(1)
fn countPass() {
  args[0] = min(atomicLoad(&counts[1]), bake.slab.w);
  args[1] = 1u;
  args[2] = 0u;
  args[3] = 0u;
  args[4] = 0u;
}
