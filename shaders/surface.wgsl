// The sea's surface, seen from below (`Reef/Render.lean`): a grid of the
// plane at the water's height, centred on the camera, its cells small
// near and growing with distance, each vertex lifted by the sea's
// height at that moment (`seaAt`, in shaders/frame.wgsl: the same
// surface the caustics were baked from). From below the surface is a
// window straight up, through which the sky shows refracted, bright,
// with the sun in it; beyond the window's edge, about 49 degrees from
// the vertical, the surface reflects the water below it wholly, a
// mirror of the deep (Fresnel's equations between: some of each). Then
// the water between the camera and the surface fogs it as everything.

// The scene below as the surface mirrors it (`Reef/Render.lean`): the
// sand drawn from the camera's mirror image above the surface, at half
// size, into a texture laid out as the screen; transparent where there
// is no sand.
@group(1) @binding(0) var reflection : texture_2d<f32>;
@group(1) @binding(1) var reflectionSampler : sampler;

// How much wider the reflection's view is than the screen's
// (`Reef.mirrorOverscan`, which must agree).
const mirrorOverscan = 1.3;

struct Out {
  @builtin(position) position : vec4f,
  @location(0) relative : vec3f,  // to the camera
  @location(1) normal   : vec3f,
}

const waterIndex = 1.333;

// Where a grid coordinate `c`, -1 to 1, falls: geometrically, the cells
// growing with distance by the same fraction each, from `nearest` at
// the centre out to `radius`.
const nearest = 0.04;
fn spaced(c : f32, radius : f32) -> f32 {
  let k = log(radius / nearest);
  return sign(c) * nearest * (exp(k * abs(c)) - 1.0);
}

// The grid's vertices, `grid + 1` a side, indexed as the floor's lattice
// is (`Reef.latticeIndices`): over the square `radius` either side of the
// camera, concentrated at the centre.
@vertex fn vs(@builtin(vertex_index) v : u32) -> Out {
  let grid = u32(frame.surface.x);
  let radius = frame.surface.y;
  let cx = f32(v % (grid + 1u)) / f32(grid) * 2.0 - 1.0;
  let cz = f32(v / (grid + 1u)) / f32(grid) * 2.0 - 1.0;
  let offset = vec2f(spaced(cx, radius), spaced(cz, radius));
  // Snapped to the grid's finest cell, so that the mesh does not swim
  // as the camera moves.
  let cell = nearest * log(radius / nearest) * 2.0 / f32(grid);
  let snapped = floor(frame.camera.xz / cell) * cell;
  let world = snapped + offset;
  let swell = swellAt(world, frame.screen.z);
  let sea = chopAt(world) + vec3f(swell.height, swell.slope);
  // The swell carries the surface's points sideways in their orbits
  // (Gerstner): the vertex goes where the water at `world` has gone.
  let carried = world + swell.offset;
  var out : Out;
  out.relative = vec3f(carried.x - frame.camera.x, frame.water.x + sea.x - frame.camera.y,
                       carried.y - frame.camera.z);
  out.position = frame.viewProj * vec4f(out.relative, 1.0);
  out.normal = normalize(vec3f(-sea.y, 1.0, -sea.z));
  return out;
}

// The sky, looking up along `dir` (unit) from just above the surface: a
// gradient, pale at the horizon, blue up; and the sun, a disc and its
// glow, where the sun is in the air.
// The sky, and the sun in it: its disc, bright as the sun; the flash
// about it, which the surface's facets, each tilted its own way, throw
// to the eye from a spread of directions, the glitter; and a soft halo.
fn sky(dir : vec3f) -> vec3f {
  let up = clamp(dir.y, 0.0, 1.0);
  var base = mix(vec3f(0.85, 0.92, 1.0), vec3f(0.25, 0.45, 0.9), pow(up, 0.6));
  // The clouds: white where the sun is behind the eye, grey beneath,
  // bright at their edges toward the sun.
  if (dir.y > 0.02) {
    let layer = frame.camera.xz + dir.xz / dir.y * cloudHeight;
    let cloud = cloudsAt(layer, frame.screen.z);
    let lit = 0.75 + 0.35 * max(dot(dir, sunInSky()), 0.0);
    base = mix(base, vec3f(0.95, 0.96, 0.98) * lit, cloud * smoothstep(0.02, 0.15, dir.y));
  }
  let sunAir = sunInAir();
  let toSun = max(dot(dir, -sunAir), 0.0);
  let disc = pow(toSun, 4000.0) * 400.0;
  let flash = pow(toSun, 900.0) * 6.0;
  let halo = pow(toSun, 12.0) * 0.5;
  return base + vec3f(1.0, 0.96, 0.88) * (disc + flash + halo);
}

// The capillary ripples at `xz`, at `t`: the centimetre waves the wind
// raises on the water, too fine for the sea's grid, that turn the sun's
// image into a field of flashes; as a tilt of the surface, two octaves
// of noise drifting with the wind, fading out with distance, where a
// pixel spans many and they would only shimmer. In patches: the wind
// gusts, raising cat's-paws here and leaving slicks there, glassy, a
// few metres across and changing over seconds, so the sun is a hard
// disc through a slick and a sparkle field through a cat's-paw; the
// wind's strength sets how much of the surface is ruffled at all.
fn capillaries(xz : vec2f, t : f32, dist : f32) -> vec2f {
  let dir = frame.ripple.xy;
  let gusts = noise((xz - dir * t * 0.8) / 3.0 + vec2f(0.0, t * 0.05));
  let wind = frame.caustic.w;
  let ruffled = smoothstep(0.35 - 0.1 * wind, 0.0 - 0.1 * wind, -gusts);
  let drift = dir * t * 0.3;
  let p1 = (xz - drift) / 0.05;
  let p2 = (xz - drift * 1.6) / 0.018 + 13.0;
  let e = 0.35;
  let a = vec2f(noise(p1 + vec2f(e, 0.0)) - noise(p1 - vec2f(e, 0.0)),
                noise(p1 + vec2f(0.0, e)) - noise(p1 - vec2f(0.0, e))) / (2.0 * e);
  let b = vec2f(noise(p2 + vec2f(e, 0.0)) - noise(p2 - vec2f(e, 0.0)),
                noise(p2 + vec2f(0.0, e)) - noise(p2 - vec2f(0.0, e))) / (2.0 * e);
  let fade = 1.0 - smoothstep(8.0, 40.0, dist);
  return (a * 0.04 + b * 0.03) * fade * ruffled;
}

// The sun's light as it comes through the air: the water's direction is
// the sun's (`frame.sun`, where the light comes from, under water);
// Snell's law gives the air's, bent further from the vertical.
fn sunInAir() -> vec3f {
  let down = -frame.sun.xyz;
  let horizontal = down.xz;
  let sinWater = length(horizontal);
  let sinAir = min(waterIndex * sinWater, 0.9995);
  let cosAir = sqrt(1.0 - sinAir * sinAir);
  let along = horizontal / max(sinWater, 1e-5);
  return vec3f(along.x * sinAir, -cosAir, along.y * sinAir);
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let dist = length(in.relative);
  let toSurface = in.relative / max(dist, 1e-4);
  // The normal at the pixel, from the sea itself, which the grid is too
  // coarse for far out; the vertices' where the sea is finer than the
  // pixel.
  let world = in.relative.xz + frame.camera.xz;
  let swell = swellAt(world, frame.screen.z);
  let sea = chopAt(world) + vec3f(swell.height, swell.slope);
  // The capillaries only where they show (they fade out by forty metres).
  var ripple = vec2f(0.0);
  if (dist < 40.0) { ripple = capillaries(world, frame.screen.z, dist); }
  let fine = normalize(vec3f(-sea.y - ripple.x, 1.0, -sea.z - ripple.y));
  let coarse = normalize(in.normal);
  let n = normalize(mix(fine, coarse, smoothstep(40.0, 120.0, dist)));
  let cosI = max(dot(n, toSurface), 0.0);
  let sinT = waterIndex * sqrt(max(1.0 - cosI * cosI, 0.0));
  var reflectance = 1.0;
  var through = vec3f(0.0);
  if (sinT < 1.0) {
    let cosT = sqrt(1.0 - sinT * sinT);
    // Fresnel, unpolarised, from water into air.
    let rs = (waterIndex * cosI - cosT) / (waterIndex * cosI + cosT);
    let rp = (cosT - waterIndex * cosI) / (cosT + waterIndex * cosI);
    reflectance = 0.5 * (rs * rs + rp * rp);
    let inAir = refract(toSurface, -n, waterIndex);
    through = sky(inAir) * (1.0 - reflectance);
  }
  // Reflected: the floor, as it is lit, seen through the water the
  // mirrored ray crosses to reach it, where the ray goes down; the
  // water's own colour where it does not. Over bright sand in shallow
  // water the ceiling is a bright mirror near the window, and the
  // water's blue far off, where the ray grazes.
  let mirrored = reflect(toSurface, n);
  // The sand, as the surface mirrors it: the reflection's texture at
  // this pixel, moved by the surface's tilt, as a wavy mirror moves its
  // image.
  let screenUV = in.position.xy / frame.screen.xy;
  // The reflection is drawn over a wider view than the screen's (by
  // `mirrorOverscan`), so the screen is its middle and the wobble always
  // has picture to pull from. The wobble by the waves' smooth slope only
  // (the capillaries would tear it), and less the nearer the surface: a
  // near patch of a wavy mirror shows a small piece of the floor.
  let calm = normalize(vec3f(-sea.y, 1.0, -sea.z));
  let nearness = smoothstep(1.0, 12.0, dist);
  let wobble = vec2f(dot(calm, frame.right.xyz), -dot(calm, frame.up.xyz))
    * 0.05 * nearness;
  let at = clamp(0.5 + (screenUV - 0.5) / mirrorOverscan + wobble,
                 vec2f(0.001), vec2f(0.999));
  // Drawn small, an eighth of the screen, and read softly: five taps, a
  // texel and a half apart, which a wavy mirror would blur anyway.
  let texel = 1.5 / vec2f(textureDimensions(reflection));
  var mirror = textureSampleLevel(reflection, reflectionSampler, at, 0.0) * 0.4;
  mirror += textureSampleLevel(reflection, reflectionSampler,
                               clamp(at + vec2f(texel.x, 0.0), vec2f(0.001), vec2f(0.999)), 0.0) * 0.15;
  mirror += textureSampleLevel(reflection, reflectionSampler,
                               clamp(at - vec2f(texel.x, 0.0), vec2f(0.001), vec2f(0.999)), 0.0) * 0.15;
  mirror += textureSampleLevel(reflection, reflectionSampler,
                               clamp(at + vec2f(0.0, texel.y), vec2f(0.001), vec2f(0.999)), 0.0) * 0.15;
  mirror += textureSampleLevel(reflection, reflectionSampler,
                               clamp(at - vec2f(0.0, texel.y), vec2f(0.001), vec2f(0.999)), 0.0) * 0.15;
  mirror = vec4f(mirror.rgb * 0.9, mirror.a);
  // The sand's light has come down through the water, and goes up
  // through it again to the surface: the water's colour twice over, and
  // the sun's warmth mostly gone from it.
  let sandLit = vec3f(0.66, 0.5, 0.26) * 0.6
    * (frame.skylight.rgb + frame.sunlight.rgb * max(frame.sun.y, 0.0) * 0.5);
  let floorBelow = frame.water.x;  // the surface's height over the floor's zero
  let toFloor = select(1e9, floorBelow / max(-mirrored.y, 1e-4), mirrored.y < -1e-4);
  // Mostly the water's own colour, a little of the floor: at a few metres
  // over sand the underside is a dark blue mirror with the floor faint
  // in it, brighter the steeper the ray goes down.
  let floorSeen = select(vec3f(0.0), fogged(sandLit, mirrored * toFloor * 2.5), toFloor < 1e8);
  let below = mix(water(mirrored) * 1.5 + floorSeen * 0.3 * max(-mirrored.y, 0.0),
                  mirror.rgb, mirror.a);
  var colour = through + below * reflectance;
  // What floats here: a dark shape against the window, the light coming
  // through it a little, green or amber; against the mirror, darker.
  let footprint = max(length(fwidth(world)), 0.002);
  var floating = vec2f(0.0);
  if (dist < 40.0) {
    floating = debrisAt(world, swell.offset, frame.screen.z, footprint);
  }
  if (floating.x > 0.0) {
    var tint = vec3f(0.22, 0.28, 0.08);
    if (floating.y > 0.5) { tint = vec3f(0.14, 0.24, 0.06); }
    if (floating.y > 1.5) { tint = vec3f(0.32, 0.2, 0.05); }
    if (floating.y > 2.5) { tint = vec3f(0.2, 0.18, 0.14); }
    let backlit = dot(through, vec3f(0.3, 0.5, 0.2));
    let thing = tint * (0.15 + 0.5 * backlit) + below * 0.05;
    colour = mix(colour, thing, floating.x);
  }
  return vec4f(fogged(colour, in.relative), 1.0);
}
