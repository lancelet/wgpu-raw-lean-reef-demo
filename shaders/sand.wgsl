// The sand: the floor, a quadtree of patches (`Reef/Floor.lean`), each
// the one lattice placed and scaled by its node's record, lifted to the
// floor's height (`height`, in shaders/frame.wgsl) and, near the camera,
// its ripples' (`rippleHeight`); lit by a sun from above with the normal
// found at each pixel, from the floor's slope, the ripples' and the
// grains', the troughs shaded, the colour speckled by the grains; fading
// into the background with distance as the grid does.

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

// What the ripples add to the floor's height at `xz`, in the world, for
// a vertex `dist` from the eye: a crest half their height up, a trough
// half down, from the tile's mip level smoothed over twice the mesh's
// cell at that distance (the leaves' within their range, doubling with
// it), so that the vertices carry what they can and not a sample each
// of what they cannot, which would be ragged; what is finer than the
// mesh the normal map keeps.
fn rippleHeight(xz : vec2f, dist : f32) -> f32 {
  let texel = frame.tiling.x / f32(textureDimensions(ripples, 0).x);
  let cell = frame.eye.z * max(1.0, 2.0 * dist / frame.floor.y);
  let lod = log2(max(1.0, 2.0 * cell / texel));
  let h = textureSampleLevel(ripples, rippleSampler, rippleUV(xz), lod).r;
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
  let dist = length(xz);
  let y = height(world) + rippleHeight(world, dist) * rippleFade(dist);
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

// The grains' tile is small, and would show its repeating a few tile
// widths off; so it is read through a grid of triangles a few tiles
// across, each corner of which reads the tile from a place of its own,
// and the three readings blended by how near the corners are (Heitz and
// Neyret, "High-Performance By-Example Noise using a Histogram-
// Preserving Blending Operator", 2018): no two triangles show the same
// part of the tile, and no seam between them. A blend of three is
// flatter than any one, so what varies is scaled back up by the
// weights' length: the tilt, which varies about zero, and the
// brightness, which varies about a half.
const grainTriangles = 3.0;  // tile widths across one

// Where `uv`, in tile widths, falls in the grid of triangles: the
// three corners, and how near each (the barycentric weights).
fn triangleAt(uv : vec2f) -> mat3x3f {
  let skewed = mat2x2f(1.0, 0.0, -0.57735027, 1.15470054) * (uv / grainTriangles);
  let base = floor(skewed);
  let f = fract(skewed);
  if (f.x + f.y < 1.0) {
    return mat3x3f(vec3f(base, 1.0 - f.x - f.y),
                   vec3f(base + vec2f(1.0, 0.0), f.x),
                   vec3f(base + vec2f(0.0, 1.0), f.y));
  }
  return mat3x3f(vec3f(base + vec2f(1.0, 1.0), f.x + f.y - 1.0),
                 vec3f(base + vec2f(1.0, 0.0), 1.0 - f.y),
                 vec3f(base + vec2f(0.0, 1.0), 1.0 - f.x));
}

// The place a corner `corner` of the grid reads the tile from: an
// offset of its own, in tile widths.
fn cornerOffset(corner : vec2f) -> vec2f {
  let c = vec2i(corner);
  var h = (u32(c.x) * 0x8da6b343u) ^ (u32(c.y) * 0xd8163841u) ^ 0x3u;
  h = h ^ (h >> 15u);
  h = h * 0x2c1b3c6du;
  h = h ^ (h >> 12u);
  return vec2f(f32(h & 0xffffu), f32((h >> 16u) & 0xffffu)) / 65535.0;
}

// The grains' tile at `xz`, in the world, read through the grid of
// triangles, for a pixel whose footprint is `along` and `across`: the
// normal (as the tile holds it) and the brightness.
fn grainsAt(xz : vec2f, along : vec2f, across : vec2f) -> vec4f {
  let uv = xz / frame.grain.x;
  let corners = triangleAt(uv);
  var sum = vec4f(0.0);
  var weights = 0.0;
  for (var i = 0; i < 3; i++) {
    let corner = corners[i];
    let read = textureSampleGrad(grains, rippleSampler, uv + cornerOffset(corner.xy),
                                 along / frame.grain.x, across / frame.grain.x);
    sum += corner.z * (read - 0.5);
    weights += corner.z * corner.z;
  }
  return sum / sqrt(weights) + 0.5;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let world = toWorld(in.relative);
  let dist = length(in.relative);
  let view = in.relative / dist;
  // The pixel's footprint on the floor: its width square on, and, along
  // the view, longer as the view slants. Found from the pixel's angle and
  // the floor's slope, not the screen's differences, which at a crest's
  // silhouette span the gap to the ripple behind, and would fetch the
  // tile's mean there: a flat normal, a bright line along every crest.
  let foot = dist * frame.camera.w;
  // The floor's slope at this pixel, by differences a footprint wide, at
  // least a few centimetres: smooth, whatever the tessellation.
  var slope = floorSlope(world.xz, max(foot, 0.03));
  let floorNormal = normalize(vec3f(-slope.x, 1.0, -slope.y));
  let slant = max(abs(dot(floorNormal, view)), 0.02);
  let ahead = select(vec2f(1.0, 0.0), normalize(view.xz), length(view.xz) > 1e-4);
  let footAlong = ahead * (foot / slant);
  let footAcross = vec2f(-ahead.y, ahead.x) * foot;
  // The ripples' slope, from their tile, filtered to that footprint (so
  // that far off, where they are finer than a pixel, they average away):
  // in heights per wavelength along the waves and across, made metres
  // per metre, and turned to the world's axes.
  let tile = textureSampleGrad(ripples, rippleSampler, rippleUV(world.xz),
                               rippleUV(footAlong), rippleUV(footAcross));
  let along = (tile.gb * 2.0 - 1.0) * 8.0 * frame.ripple.w / frame.ripple.z;
  let dir = frame.ripple.xy;
  slope += along.x * dir + along.y * vec2f(-dir.y, dir.x);
  // The grains' tilt, from their tile over the world's axes, filtered
  // likewise: where they are finer than the pixel, the normal averages
  // to flat, and shorter (the roughness they leave, Toksvig's measure,
  // for the lighting to come), so the tilt fades out of its own accord.
  let grain = grainsAt(world.xz, footAlong, footAcross);
  let tilt = grain.rgb * 2.0 - 1.0;
  slope += frame.grain.y * vec2f(-tilt.x, -tilt.z) / max(tilt.y, 0.2);
  let normal = normalize(vec3f(-slope.x, 1.0, -slope.y));
  // The sun low, for now, so that the relief shows.
  let sun = normalize(vec3f(0.8, 0.45, 0.3));
  // The sand's colour, speckled by the grains: each its own brightness,
  // the gaps between them dark; far off, their mean.
  let sand = vec3f(0.55, 0.47, 0.30) * mix(1.0, 2.0 * grain.a, frame.grain.z);
  let cavity = mix(1.0, tile.a, frame.tiling.w);
  let light = (0.25 + 0.75 * max(dot(normal, sun), 0.0)) * cavity;
  let color = sand * light;
  let fade = visible(length(in.relative));
  return vec4f(mix(background, color, fade), 1.0);
}
