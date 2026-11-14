// The bommies, drawn (`Reef/Bommies.lean`): the mesh baked at the start
// (shaders/reefbake.wgsl), its vertices read from a buffer. The material
// is old reef limestone: grey, crusted pink with coralline algae on the
// faces that see the light, furred olive-brown with algal turf, sand
// settled in its low places, darker in its hollows; close up, the coral
// it was, worn and bored and crusted (the detail tile,
// shaders/rockdetail.wgsl, read from three sides). Where it meets the
// sand, sand-blasted pale and bare a hand or two up, the sand banked into
// its pits, and the sand shading its foot. Lit as the sand is: the
// sky, as much as the rock lets in (the baked occlusion), and the sun
// through the caustics, the clouds and the swell, where the rock does not
// shade itself (the baked shadow); fogged by the water.

struct Vertex {
  position : vec3f,
  ao       : f32,
  normal   : vec3f,
  shadow   : f32,
}

@group(1) @binding(0) var<storage, read> vertices : array<Vertex>;
// The rock's detail tile, and its sampler (repeating, filtered).
@group(1) @binding(1) var rockDetail : texture_2d_array<f32>;
@group(1) @binding(2) var rockSampler : sampler;

// The detail tile's width, in metres (`Reef.rockTileWidth`).
const rockTile = 0.25;

struct Out {
  @builtin(position) position : vec4f,
  @location(0) relative : vec3f,
  @location(1) normal   : vec3f,
  @location(2) ao       : f32,
  @location(3) shadow   : f32,
}

@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  let v = vertices[i];
  var out : Out;
  out.relative = v.position - frame.camera.xyz;
  out.position = frame.viewProj * vec4f(out.relative, 1.0);
  out.normal = v.normal;
  out.ao = v.ao;
  out.shadow = v.shadow;
  return out;
}

// Noise over a surface of normal `n` at `p`, by its three planes, each
// weighted by how square it faces them: about -1 to 1. A plane the
// surface hardly faces is not read at all (most faces need one or two).
fn triplanar(p : vec3f, w : vec3f) -> f32 {
  var sum = 0.0;
  if (w.x > 0.02) { sum += noise(p.yz) * w.x; }
  if (w.y > 0.02) { sum += noise(p.xz + 7.3) * w.y; }
  if (w.z > 0.02) { sum += noise(p.xy + 3.1) * w.z; }
  return 2.2 * sum;
}

// The frame's gradient noise (`noise`) at `p`, with its gradient there:
// value, d/dx, d/dy.
fn noiseGrad(p : vec2f) -> vec3f {
  let i = vec2i(floor(p));
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  let du = 6.0 * f * (1.0 - f);
  let ga = gradient(i);
  let gb = gradient(i + vec2i(1, 0));
  let gc = gradient(i + vec2i(0, 1));
  let gd = gradient(i + vec2i(1, 1));
  let va = dot(ga, f);
  let vb = dot(gb, f - vec2f(1.0, 0.0));
  let vc = dot(gc, f - vec2f(0.0, 1.0));
  let vd = dot(gd, f - vec2f(1.0, 1.0));
  let k = va - vb - vc + vd;
  let value = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k;
  let d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
    + du * vec2f(vb - va + u.y * k, vc - va + u.x * k);
  return vec3f(value, d);
}

// `triplanar` with its gradient over the world, at `p` scaled `scale`
// from the world: value, and d/dx, d/dy, d/dz. Exact, so a bump made of it
// needs no differences between pixels (which, through the weights, would
// crease along every triangle's edge).
fn triplanarGrad(p : vec3f, scale : f32, w : vec3f) -> vec4f {
  var sum = vec4f(0.0);
  if (w.x > 0.02) { let g = noiseGrad(p.yz); sum += vec4f(g.x, 0.0, g.y, g.z) * w.x; }
  if (w.y > 0.02) { let g = noiseGrad(p.xz + 7.3); sum += vec4f(g.x, g.y, 0.0, g.z) * w.y; }
  if (w.z > 0.02) { let g = noiseGrad(p.xy + 3.1); sum += vec4f(g.x, g.y, g.z, 0.0) * w.z; }
  return 2.2 * vec4f(sum.x, sum.yzw * scale);
}

// How much of the sky the rock leaves `p` on it, normal `n`: the field
// sampled out along the normal, a hand to a metre (between its points,
// so smooth; too far out to see the rock's small pits, which the detail
// tile darkens itself). Per pixel, near: the vertices' own, baked at the
// rock's every pit and interpolated, would draw the mesh's cells.
fn rockOcclusion(p : vec3f, n : vec3f) -> f32 {
  var occluded = 0.0;
  var total = 0.0;
  for (var k = 1; k <= 4; k++) {
    let d = 0.12 * f32(k * k);
    let weight = 1.0 / f32(k);
    occluded += weight * clamp((d - reefDistance(p + n * d, true)) / d, 0.0, 1.0);
    total += weight;
  }
  return clamp(1.0 - 1.1 * occluded / total, 0.0, 1.0);
}

// The sun's light at `p` on the rock, its normal `n`, marched through the
// reef's field toward the sun (`reefDistance`): for where the shadow
// baked at the vertices changes, which between vertices a hand apart
// would draw its edge as their triangles'.
fn rockShadow(p : vec3f, n : vec3f) -> f32 {
  let sun = frame.sun.xyz;
  // (Started a cell out from the rock, along its normal: the field
  // between its points is not quite the mesh, and nearer it would find
  // the rock's own face and streak it with shadow.)
  var t = 0.06;
  var lit = 1.0;
  for (var s = 0; s < 24; s++) {
    let h = reefDistance(p + n * 0.1 + sun * t, true);
    lit = min(lit, 0.5 + 0.5 * h / (0.05 * t + 0.015));
    t += clamp(h * 0.8, 0.03 + 0.03 * t, 0.5);
    if (lit <= 0.0 || t > 8.0) { break; }
  }
  return smoothstep(0.0, 1.0, clamp(lit, 0.0, 1.0));
}

// The detail tile over the rock, read from its three planes as their
// weights `w` say, `layer` of it, at `scale` tiles a tile's width, with
// the pixel's footprint `fx`, `fy` (in tiles); each plane's own offset,
// so that no two planes' features line up.
struct Planes {
  x : vec4f,
  y : vec4f,
  z : vec4f,
}

fn detailPlanes(p : vec3f, fx : vec3f, fy : vec3f, w : vec3f, layer : i32) -> Planes {
  var r : Planes;
  if (w.x > 0.02) { r.x = textureSampleGrad(rockDetail, rockSampler, p.yz + vec2f(0.31, 0.17), layer, fx.yz, fy.yz); }
  if (w.y > 0.02) { r.y = textureSampleGrad(rockDetail, rockSampler, p.xz + vec2f(0.63, 0.41), layer, fx.xz, fy.xz); }
  if (w.z > 0.02) { r.z = textureSampleGrad(rockDetail, rockSampler, p.xy + vec2f(0.07, 0.83), layer, fx.xy, fy.xy); }
  return r;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let world = toWorld(in.relative);
  let dist = length(in.relative);
  let geometric = normalize(in.normal);
  var n = geometric;
  var w = pow(abs(geometric), vec3f(4.0));
  w = w / (w.x + w.y + w.z);
  // The detail tile's weights sharper: a plane seen slantwise stretches
  // it into streaks, so each is read only where it is nearly square on.
  // (By the smoothed normal: the mesh's own faces, seen from above,
  // are near-rectangles, and weights by them would show each one.)
  var wd = pow(max(abs(geometric) - 0.35, vec3f(0.0)), vec3f(6.0));
  wd = wd / max(wd.x + wd.y + wd.z, 1e-6);
  let near = 1.0 - smoothstep(6.0, 22.0, dist);
  // The sky the rock leaves it: per pixel near, the vertices' far off.
  var ao = in.ao;
  if (dist < 25.0) {
    ao = mix(rockOcclusion(world, geometric), ao, smoothstep(18.0, 25.0, dist));
  }
  // Three scales of noise over the rock, a couple of metres to a few
  // centimetres: where its covers lie, and the knobs of the coral heads.
  let large = triplanar(world * 0.55 + 3.0, w);
  let mid = triplanar(world * 1.7 + 11.0, w);
  let smallG = triplanarGrad(world * 6.0 + 21.0, 6.0, w);
  let small = smallG.x;
  let knobs = 1.0 - abs(small);
  // The detail tile, from its three planes: the surface's slope, cavity
  // and height; its brightness, crust and grit.
  let tp = world / rockTile;
  let fx = dpdx(tp);
  let fy = dpdy(tp);
  let s0 = detailPlanes(tp, fx, fy, wd, 0);
  let s1 = detailPlanes(tp, fx, fy, wd, 1);
  let sx = (s0.x.xy - 0.5) * 4.0;
  let sy = (s0.y.xy - 0.5) * 4.0;
  let sz = (s0.z.xy - 0.5) * 4.0;
  let detailSlope = vec3f(0.0, sx.x, sx.y) * wd.x + vec3f(sy.x, 0.0, sy.y) * wd.y
    + vec3f(sz.x, sz.y, 0.0) * wd.z;
  let cavity = s0.x.z * wd.x + s0.y.z * wd.y + s0.z.z * wd.z;
  let rise = s0.x.w * wd.x + s0.y.w * wd.y + s0.z.w * wd.z;
  let tone = s1.x * wd.x + s1.y * wd.y + s1.z * wd.z;
  // Where it meets the sand: how high above the sand under it (the
  // seabed's, its moat and tails and all).
  let above = world.y - height(world.xz);
  // Sand-blasted: a hand or two up from the sand the surge throws sand at
  // it, and it is worn pale and bare, nothing growing; ragged, higher where
  // the rock juts out.
  let blasted = 1.0 - smoothstep(0.1, 0.45, above + 0.1 * small + 0.08 * mid);
  // The seam's zone: the bottom of the rock, where it turns into the
  // sand. At the contact it is the floor, its sand, its normal, its
  // light; a ragged hand or so up, wholly the rock; between, a smooth
  // blend of the two, so nothing changes at a line.
  let seam = 1.0 - smoothstep(0.0, 0.3, above + 0.06 * small + 0.04 * mid);
  // The bump: the coral heads' knobs (exact, from the noise), and the
  // tile's own slope; held to a sane tilt.
  var slope = 0.07 * knobs * (-sign(small)) * smallG.yzw * near + 0.8 * detailSlope;
  slope = slope * min(1.0, 1.5 / max(length(slope), 1e-6));
  // The material. Under it all, old limestone, pale and a little warm;
  // over it, in patches a hand to a metre across, their edges ragged:
  // coralline algae's crusts, pink to mauve, where the light is good;
  // algal turf, olive and brown, the commonest cover of a reef's rock;
  // bleached patches of dead coral, newly bare;
  // dark sponge and sea squirts in the shade;
  // and none of them where the sand blasts it.
  let up = clamp(geometric.y, -1.0, 1.0);
  // (Roughened by noise a hand across, not by the detail tile, whose
  // millimetres read back at this scale only as its mip levels' means.)
  let ragged = 0.35 * small + 0.25 * triplanar(world * 3.3 + 47.0, w);
  let living = 1.0 - 0.4 * blasted;
  var albedo = vec3f(0.58, 0.55, 0.48);
  let turf = smoothstep(-0.35, 0.35, large + 0.4 * mid + ragged) * living;
  albedo = mix(albedo, mix(vec3f(0.33, 0.33, 0.16), vec3f(0.4, 0.31, 0.2), smoothstep(-0.6, 0.6, mid + ragged)),
               turf * 0.8);
  let coralline = smoothstep(0.0, 0.6, mid - 0.5 * large + ragged) * smoothstep(-0.4, 0.3, up) * living;
  albedo = mix(albedo, mix(vec3f(0.68, 0.43, 0.52), vec3f(0.55, 0.39, 0.56), smoothstep(-0.5, 0.5, small)),
               coralline * 0.75 * mix(0.7, 1.0, tone.y));
  let bare = smoothstep(0.45, 0.85, small + 0.4 * mid + 0.3 * ragged) * (1.0 - coralline);
  albedo = mix(albedo, vec3f(0.76, 0.74, 0.68), bare * 0.6);
  let sponge = smoothstep(0.4, 0.9, -mid - 0.3 * small + 0.2 * ragged)
    * (1.0 - smoothstep(0.55, 0.85, ao)) * living;
  albedo = mix(albedo, vec3f(0.42, 0.18, 0.12), sponge * 0.7);
  // Close up, the coral it was: the tile's brightness and grit, darker in
  // its cavities; far off, their means.
  albedo = albedo * (0.7 + 0.6 * tone.x) * (0.9 + 0.2 * tone.z)
    * clamp(0.45 + 1.1 * cavity, 0.4, 1.1);
  // Sand: settled where the rock is flat enough to hold it, and banked
  // against its foot, filling the low places of its surface first (the
  // tile's height), so that its edge follows the rock's own pits and
  // ridges.
  let settles = max(smoothstep(0.8, 0.95, up) * smoothstep(0.15, 0.3, large + 0.3 * small),
                    (1.0 - smoothstep(0.0, 0.14, above + 0.05 * small)) * smoothstep(-0.3, 0.3, up));
  let level = 0.95 * settles;
  // And the last few centimetres up from the floor all sand, whatever
  // way they face: banked against the rock, the floor's own surface
  // running on up it, so that the two meet sand to sand, not in a line.
  // (Its sand edge a little below the normal's: the sand thins out up
  // the rock, in its low places last, the tile's height.)
  let banked = 1.0 - smoothstep(0.1, 0.28, above + 0.06 * small + 0.04 * mid + 0.1 * (rise - 0.5));
  let sand = max((1.0 - smoothstep(level - 0.06, level + 0.02, rise)) * step(0.01, settles), banked);
  // (Read as the floor reads it, through its grid of triangles, so that
  // the tile's repeating does not show: on the plane the face is most
  // nearly square to.)
  let gx = dpdx(world);
  let gy = dpdy(world);
  // Its colour and its grains' size the floor's at the foot (the
  // seabed's map's moat and tails), so that the two are one sand.
  let floorBed = seabedAt(world.xz);
  let sorting = sandSorting(floorBed);
  if (sand > 0.0) {
    var grain : vec4f;
    if (wd.y >= wd.x && wd.y >= wd.z) {
      grain = grainsAt(world.xz, gx.xz, gy.xz, sorting, 0.0);
    } else if (wd.x >= wd.z) {
      grain = grainsAt(world.zy + 3.7, gx.zy, gy.zy, sorting, 0.0);
    } else {
      grain = grainsAt(world.xy + 5.3, gx.xy, gy.xy, sorting, 0.0);
    }
    albedo = mix(albedo, sandColour(floorBed, grain.a, 0.5), sand);
    slope = mix(slope, vec3f(0.0), sand * 0.8);
  }
  n = normalize(n - (slope - n * dot(n, slope)));
  // The normal across the seam: the floor's at the contact (its lip and
  // all, so the two meet with the same normal, so the same light), the
  // rock's own a hand up, blended smoothly between.
  if (seam > 0.0) {
    let fs = floorSlope(world.xz, 0.04);
    let floorNormal = normalize(vec3f(-fs.x, 1.0, -fs.y));
    let k = seam * seam * (3.0 - 2.0 * seam);
    n = normalize(mix(n, floorNormal, k));
  }
  // In the sky's light, the sand's own shade too: the rock near the floor
  // sees less of the sky, the more so facing down or along it.
  let floorShade = mix(mix(0.35, 0.6, max(up, 0.0)), 1.0, smoothstep(0.0, 0.5, above));
  // The light: the sky's, as much as the rock lets in; the sun's through
  // the caustics where the sun's ray through here meets the surface, the
  // swell's slosh and bending, the clouds and the floating litter, taken
  // by the water on its way down; where the rock does not shade itself.
  let sun = frame.sun.xyz;
  let t = frame.screen.z;
  let toSurface = max(frame.water.x - world.y, 0.0) / max(sun.y, 0.1);
  var onSurface = world.xz + sun.xz * toSurface;
  let bending = swellBending(onSurface, t, toSurface);
  onSurface -= swellDriftAt(onSurface, t) + bending.xy;
  let moments = frame.caustic.z;
  let moment = fract(t / frame.caustic.y) * moments;
  let layer = i32(floor(moment));
  let next = (layer + 1) % i32(moments);
  let uv = onSurface / frame.caustic.x;
  let blur = vec2f(max(toSurface * 0.0093, dist * frame.camera.w) / frame.caustic.x);
  let gathered = mix(textureSampleGrad(caustics, rippleSampler, uv, layer, vec2f(blur.x, 0.0), vec2f(0.0, blur.y)).rgb,
                     textureSampleGrad(caustics, rippleSampler, uv, next, vec2f(blur.x, 0.0), vec2f(0.0, blur.y)).rgb,
                     fract(moment)) * causticBrightest;
  let focus = mix(vec3f(1.0), gathered, frame.water.y) * bending.z;
  // (The sun's light is the floor's: above it, less water has taken it.)
  let down = exp(frame.extinct.rgb * max(world.y, 0.0) / max(sun.y, 0.1));
  let floating = debrisAt(onSurface, swellDriftAt(onSurface, t), t, 0.004 + toSurface * 0.0093).x;
  // (Marched where the vertices' shadow changes, and blended into theirs
  // toward where it does not, so that there is no edge where it starts.)
  var shadow = in.shadow;
  let changing = smoothstep(0.0, 0.08, min(shadow, 1.0 - shadow)) * (1.0 - smoothstep(12.0, 15.0, dist));
  if (changing > 0.0) { shadow = mix(shadow, rockShadow(world, geometric), changing); }
  // (The banked sand lit as the floor it continues is: by the seabed's
  // map, its sky and its sun, so that the two meet without a step.)
  let floorLit = floorBed;
  // (The floor's shadow toward the contact; the rock's own above, which
  // under an overhang the floor's map, a hand out, does not know.)
  shadow = mix(shadow, min(shadow + 0.3, floorLit.y), seam);
  let shade = cloudShade(world, t) * (1.0 - 0.85 * floating) * shadow;
  // (In the seam, the sand's rough diffuse, as the floor is lit.)
  let diffuse = mix(max(dot(n, sun), 0.0), roughDiffuse(n, sun, -normalize(in.relative), 0.5), seam);
  let skySeen = mix(ao * floorShade * (0.55 + 0.45 * up), floorLit.x, seam);
  let sky = frame.skylight.rgb * skySeen;
  let light = sky + frame.sunlight.rgb * diffuse * focus * down * shade;
  return vec4f(fogged(albedo * light, in.relative), 1.0);
}
