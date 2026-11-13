// The sand: the floor, a quadtree of patches (`Reef/Floor.lean`), each
// the one lattice placed and scaled by its node's record, lifted to the
// floor's height (`height`, in shaders/frame.wgsl), lit by a sun from
// above with the normal found at each pixel, fading into the background
// with distance as the grid does.

// The nodes drawn this frame: each its corner nearest the origin (x, z)
// and its size, in whole leaf cells, the corner's from the cell the eye
// is in; and its level, 0 the leaves. Whole numbers, so that a vertex two
// nodes share comes out the same in both, to the last bit.
@group(0) @binding(1) var<storage, read> nodes : array<vec4f>;

struct Out {
  @builtin(position) position : vec4f,
  @location(0)       relative : vec3f,  // to the camera
  @location(7)       bary     : vec3f,  // the wireframe's (shaders/wire.wgsl)
}

// The floor's point at `cellXZ`, in leaf cells from the eye's cell,
// relative to the camera, as `height` says.
fn floorAt(cellXZ : vec2f) -> vec3f {
  let xz = cellXZ * frame.eye.z - frame.eye.xy;
  let world = xz + frame.camera.xz;
  return vec3f(xz.x, height(world) - frame.camera.y, xz.y);
}

// How far a vertex `dist` from the eye is morphed at level `level`: 0
// before the level's range's `morph` fraction, 1 a little short of the
// range (so that a vertex at it is wholly morphed whatever the floats say).
fn morph(dist : f32, level : f32) -> f32 {
  let range = frame.floor.y * exp2(level);
  let start = range * frame.floor.z;
  let end = range - (range - start) * 0.05;
  return clamp((dist - start) / (end - start), 0.0, 1.0);
}

// A lattice vertex of the node `instance` (its record relative to the
// camera): placed in the node, and, near the node's range, morphed onto
// its parent's lattice (every other vertex moved onto the one before it),
// so that the node meets a neighbour at the level above with no crack,
// and leaves for the level above with no pop. The morph begins at the
// range's `morph` fraction of the way out, by the vertex's own distance
// from the eye. The two levels above are morphed too, as a neighbour at
// those levels would morph the same vertex, so that the two agree
// wherever they meet, whatever the distances.
@vertex fn vs(@location(0) lattice : vec2f,
              @builtin(vertex_index) index : u32,
              @builtin(instance_index) instance : u32) -> Out {
  let node = nodes[instance];
  let cells = frame.floor.x;
  // Leaf cells a lattice step: a power of two, exact.
  let step = node.z / cells;
  let dist = length(floorAt(node.xy + lattice * step));
  var morphed = lattice;
  for (var k = 0u; k < 3u; k++) {
    let s = exp2(f32(k + 1u));
    morphed = morphed - fract(morphed / s) * s * morph(dist, node.w + f32(k));
  }
  var out : Out;
  out.relative = floorAt(node.xy + morphed * step);
  out.position = frame.viewProj * vec4f(out.relative, 1.0);
  out.bary = barycentric(index);
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  // The normal at this pixel, by differences a pixel's footprint wide,
  // at least a few centimetres: smooth, whatever the tessellation.
  let world = toWorld(in.relative);
  let e = max(length(fwidth(world.xz)), 0.03);
  let normal = floorNormal(world.xz, e);
  // The sun low, for now, so that the relief shows.
  let sun = normalize(vec3f(0.8, 0.45, 0.3));
  let sand = vec3f(0.55, 0.47, 0.30);
  let light = 0.25 + 0.75 * max(dot(normal, sun), 0.0);
  let color = sand * light;
  let fade = visible(length(in.relative));
  return vec4f(mix(background, color, fade), 1.0);
}
