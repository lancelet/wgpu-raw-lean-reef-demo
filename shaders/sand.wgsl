// The sand: the floor, a quadtree of patches (`Reef/Floor.lean`), each
// the one lattice placed and scaled by its node's record, lifted to the
// floor's height (`height`, in shaders/frame.wgsl) and, near the camera,
// its ripples' (`rippleHeight`); lit by a sun from above with the normal
// found at each pixel, from the floor's slope, the ripples' and the
// grains', the troughs shaded, the colour speckled by the grains, the
// sun's light focused by the surface's waves into caustics; seen through
// the water, which takes its colours with distance and scatters in its
// own.

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
// widths off; so it is read through a grid of triangles, each corner of
// which reads the tile from a place of its own, and the three readings
// blended by how near the corners are (Heitz and Neyret, "High-
// Performance By-Example Noise using a Histogram-Preserving Blending
// Operator", 2018): no two triangles show the same part of the tile,
// and no seam between them. The triangles are smaller than the tile, so
// that it never repeats even within one (a grid of a few tiles across
// let it, and the repeat showed at a metre). A blend of three is flatter
// than any one, so what varies is scaled back up by the weights' length:
// the tilt, which varies about zero, and the brightness, which varies
// about a half.
const grainTriangles = 0.4;  // tile widths across one

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
// triangles, for a pixel whose footprint is `along` and `across`, the
// grains `coarser` times their size (the sand sorted: coarser in the
// ripples' troughs, finer on their crests): the normal, not unit
// (shorter where the filtering has averaged it), and the brightness. The
// tilt and the brightness are scaled back up to the tile's contrast; the
// normal's height is the plain blend, as its length is what is wanted
// of it.
fn grainsAt(xz : vec2f, along : vec2f, across : vec2f, coarser : f32,
            still : f32) -> vec4f {
  let uv = xz / frame.grain.x;
  let corners = triangleAt(uv);
  var sum = vec4f(0.0);
  var weights = 0.0;
  for (var i = 0; i < 3; i++) {
    let corner = corners[i];
    // Scaled about the corner, not the world's origin: the scale varies
    // over the ripples, and about the origin that would smear the tile.
    let cornerUV = mat2x2f(1.0, 0.0, 0.5, 0.8660254) * corner.xy * grainTriangles;
    let local = (uv - cornerUV) / coarser + cornerUV;
    // The layer with the traces where the sand is still, the one without
    // where it moves: both, blended, where it is between.
    let at = local + cornerOffset(corner.xy);
    let dx = along / (frame.grain.x * coarser);
    let dy = across / (frame.grain.x * coarser);
    let read = mix(textureSampleGrad(grains, rippleSampler, at, 1, dx, dy),
                   textureSampleGrad(grains, rippleSampler, at, 0, dx, dy), still);
    sum += corner.z * (read - 0.5);
    weights += corner.z * corner.z;
  }
  let scaled = sum / sqrt(weights);
  return vec4f(scaled.x * 2.0, sum.y * 2.0, scaled.z * 2.0, scaled.w + 0.5);
}

// Oren and Nayar's diffuse lighting of a rough surface, `sigma2` the
// square of its roughness (the spread of its facets, in radians), with
// normal `n`, lit from `l`, seen from `v`: like Lambert's, but a rough
// surface shows the same from every angle when lit from behind the
// viewer, and darkens toward the light, as sand does.
fn roughDiffuse(n : vec3f, l : vec3f, v : vec3f, sigma2 : f32) -> f32 {
  let nl = max(dot(n, l), 0.0);
  let nv = max(dot(n, v), 0.0);
  let a = 1.0 - 0.5 * sigma2 / (sigma2 + 0.33);
  let b = 0.45 * sigma2 / (sigma2 + 0.09);
  let s = dot(l, v) - nl * nv;
  let t = select(1.0, max(nl, nv), s > 0.0);
  return nl * (a + b * s / max(t, 1e-4));
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
  // The sand sorted by the ripples: the water carries the fine grains up
  // the crests and leaves the coarse in the troughs, which are a little
  // darker for it.
  let sorted = mix(1.35, 0.8, tile.r);
  // What lives in the sand digs where the sand is still: in the ripples'
  // troughs, not on their crests, which the water sweeps; and in
  // colonies, patches a few ripples across with bare sand between (a
  // field of noise over the world, half a metre a feature).
  let colonies = smoothstep(0.05, 0.4, noise(world.xz / 0.5 + 77.0));
  let still = (1.0 - smoothstep(0.2, 0.55, tile.r)) * colonies;
  let grain = grainsAt(world.xz, footAlong, footAcross, sorted, still);
  let tilt = grain.xyz;
  slope += frame.grain.y * vec2f(-tilt.x, -tilt.z) / max(tilt.y, 0.2);
  let normal = normalize(vec3f(-slope.x, 1.0, -slope.y));
  // The sand's roughness: its own, grain on grain, and what the
  // filtering has averaged out of the grains' normal, which is shorter
  // by that much (Toksvig).
  let shortened = max(length(tilt), 0.2);
  let sigma2 = 0.36 + (1.0 - shortened) / shortened;
  let sun = frame.sun.xyz;
  // Whether the sun is up over the ripples here: the horizon toward it,
  // from the four the tile holds, against its elevation; softly, as the
  // horizons, filtered, are a mean over what is under the pixel.
  let sunAcross = vec2f(dot(sun.xz, dir), dot(sun.xz, vec2f(-dir.y, dir.x)));
  let toward = max(vec4f(sunAcross.x, -sunAcross.x, sunAcross.y, -sunAcross.y),
                   vec4f(0.0));
  let rims = textureSampleGrad(horizons, rippleSampler, rippleUV(world.xz),
                               rippleUV(footAlong), rippleUV(footAcross));
  let horizon = dot(toward, rims) / max(dot(toward, vec4f(1.0)), 1e-4) * 1.5707963;
  let lit = smoothstep(horizon - 0.15, horizon + 0.15, asin(clamp(sun.y, -1.0, 1.0)));
  // The sand's colour, speckled by the grains: each its own brightness,
  // the gaps between them dark; far off, their mean.
  let sand = vec3f(0.66, 0.5, 0.26) * mix(1.0, 2.0 * grain.a, frame.grain.z)
    * mix(0.88, 1.0, tile.r);
  // Lit by the sky as much as it can see, and by the sun where it is up,
  // through the caustics (found where the sun's ray through this point
  // meets the surface, so that they drift down the sun's slant).
  let cavity = mix(1.0, tile.a, frame.tiling.w);
  let toSurface = (frame.water.x - world.y) / max(sun.y, 0.1);
  let onSurface = world.xz + sun.xz * toSurface;
  // The caustics' loop at this moment: the layer, and the next, blended;
  // blurred at least by the sun's own width, half a degree of sky, over
  // the water the light has come down through.
  let causticTile = frame.caustic.x;
  let moments = frame.caustic.z;
  let moment = fract(frame.screen.z / frame.caustic.y) * moments;
  let layer = i32(floor(moment));
  let next = (layer + 1) % i32(moments);
  let sunBlur = toSurface * 0.0093;
  let blurAlong = footAlong * max(1.0, sunBlur / max(length(footAlong), 1e-5));
  let blurAcross = footAcross * max(1.0, sunBlur / max(length(footAcross), 1e-5));
  let uv = onSurface / causticTile;
  let dx = blurAlong / causticTile;
  let dy = blurAcross / causticTile;
  let gathered = mix(textureSampleGrad(caustics, rippleSampler, uv, layer, dx, dy).rgb,
                     textureSampleGrad(caustics, rippleSampler, uv, next, dx, dy).rgb,
                     fract(moment)) * causticBrightest;
  let focus = mix(vec3f(1.0), gathered, frame.water.y);
  let light = frame.skylight.rgb * cavity
    + frame.sunlight.rgb * roughDiffuse(normal, sun, -view, sigma2) * lit * focus;
  let color = sand * light;
  return vec4f(fogged(color, in.relative), 1.0);
}
