// The sand: the floor, a quadtree of patches (`Reef/Floor.lean`), each
// the one lattice placed and scaled by its node's record, lifted to the
// floor's height (`height`, in shaders/frame.wgsl) and, near the camera,
// its ripples' (`rippleHeight`); lit by a sun from above with the normal
// found at each pixel, from the floor's slope and the ripples', the
// troughs shaded; fading into the background with distance as the grid
// does.

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

// Where `xz`, in the world, is on the ripples' tile: along the waves, and
// across them, in tiles (`shaders/ripples.wgsl`).
fn rippleUV(xz : vec2f) -> vec2f {
  let dir = frame.ripple.xy;
  return vec2f(dot(xz, dir), dot(xz, vec2f(-dir.y, dir.x))) / frame.tiling.x;
}

// What the ripples add to the floor's height at `xz`, in the world: a
// crest half their height up, a trough half down.
fn rippleHeight(xz : vec2f) -> f32 {
  let h = textureSampleLevel(ripples, rippleSampler, rippleUV(xz), 0.0).r;
  return (h - 0.5) * frame.ripple.w;
}

// How much the ripples lift the mesh `dist` from the eye: wholly near it,
// where the patches are fine enough to carry them; beyond, the normal map
// carries them alone.
fn rippleFade(dist : f32) -> f32 {
  return 1.0 - smoothstep(frame.tiling.y, frame.tiling.z, dist);
}

// The floor's point at `cellXZ`, in leaf cells from the eye's cell,
// relative to the camera, as `height` says, and the ripples near the eye.
fn floorAt(cellXZ : vec2f) -> vec3f {
  let xz = cellXZ * frame.eye.z - frame.eye.xy;
  let world = xz + frame.camera.xz;
  let y = height(world) + rippleHeight(world) * rippleFade(length(xz));
  return vec3f(xz.x, y - frame.camera.y, xz.y);
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
// from the eye. The three levels above are morphed too, as a neighbour
// at those levels would morph the same vertex, so that the two agree
// wherever they meet, whatever the distances (three, for relief many
// times the design's, which carries a node's vertices far).
@vertex fn vs(@location(0) lattice : vec2f,
              @builtin(vertex_index) index : u32,
              @builtin(instance_index) instance : u32) -> Out {
  let node = nodes[instance];
  let cells = frame.floor.x;
  // Leaf cells a lattice step: a power of two, exact.
  let step = node.z / cells;
  var morphed = lattice;
  for (var k = 0u; k < 4u; k++) {
    // The distance from where the vertex is after the levels below: a
    // vertex moved onto another must go on as that one does.
    let dist = length(floorAt(node.xy + morphed * step));
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
  let world = toWorld(in.relative);
  // The floor's slope at this pixel, by differences a pixel's footprint
  // wide, at least a few centimetres: smooth, whatever the tessellation.
  let e = max(length(fwidth(world.xz)), 0.03);
  var slope = floorSlope(world.xz, e);
  // The ripples' slope, from their tile, filtered to the pixel's
  // footprint (so that far off, where they are finer than a pixel, they
  // average away): in heights per wavelength along the waves and across,
  // made metres per metre, and turned to the world's axes.
  let tile = textureSample(ripples, rippleSampler, rippleUV(world.xz));
  let along = (tile.gb * 2.0 - 1.0) * 8.0 * frame.ripple.w / frame.ripple.z;
  let dir = frame.ripple.xy;
  slope += along.x * dir + along.y * vec2f(-dir.y, dir.x);
  let normal = normalize(vec3f(-slope.x, 1.0, -slope.y));
  // The sun low, for now, so that the relief shows.
  let sun = normalize(vec3f(0.8, 0.45, 0.3));
  let sand = vec3f(0.55, 0.47, 0.30);
  let cavity = mix(1.0, tile.a, frame.tiling.w);
  let light = (0.25 + 0.75 * max(dot(normal, sun), 0.0)) * cavity;
  let color = sand * light;
  let fade = visible(length(in.relative));
  return vec4f(mix(background, color, fade), 1.0);
}
