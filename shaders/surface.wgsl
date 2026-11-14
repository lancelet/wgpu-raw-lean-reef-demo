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
  let sea = seaAt(world);
  // The swell carries the surface's points sideways in their orbits
  // (Gerstner): the vertex goes where the water at `world` has gone.
  let carried = world + swellAt(world, frame.screen.z).offset;
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
  let base = mix(vec3f(0.85, 0.92, 1.0), vec3f(0.25, 0.45, 0.9), pow(up, 0.6));
  let sunAir = sunInAir();
  let toSun = max(dot(dir, -sunAir), 0.0);
  let disc = pow(toSun, 4000.0) * 400.0;
  let flash = pow(toSun, 250.0) * 12.0;
  let halo = pow(toSun, 12.0) * 0.6;
  return base + vec3f(1.0, 0.96, 0.88) * (disc + flash + halo);
}

// The capillary ripples at `xz`, at `t`: the centimetre waves the wind
// raises on the water, too fine for the sea's grid, that turn the sun's
// image into a field of flashes; as a tilt of the surface, two octaves
// of noise drifting with the wind, fading out with distance, where a
// pixel spans many and they would only shimmer.
fn capillaries(xz : vec2f, t : f32, dist : f32) -> vec2f {
  let dir = frame.ripple.xy;
  let drift = dir * t * 0.3;
  let p1 = (xz - drift) / 0.05;
  let p2 = (xz - drift * 1.6) / 0.018 + 13.0;
  let e = 0.35;
  let a = vec2f(noise(p1 + vec2f(e, 0.0)) - noise(p1 - vec2f(e, 0.0)),
                noise(p1 + vec2f(0.0, e)) - noise(p1 - vec2f(0.0, e))) / (2.0 * e);
  let b = vec2f(noise(p2 + vec2f(e, 0.0)) - noise(p2 - vec2f(e, 0.0)),
                noise(p2 + vec2f(0.0, e)) - noise(p2 - vec2f(0.0, e))) / (2.0 * e);
  let fade = 1.0 - smoothstep(8.0, 40.0, dist);
  return (a * 0.045 + b * 0.025) * fade;
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
  let sea = seaAt(world);
  let ripple = capillaries(world, frame.screen.z, dist);
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
  let below = water(mirrored) * 1.5 + floorSeen * 0.3 * max(-mirrored.y, 0.0);
  let colour = through + below * reflectance;
  return vec4f(fogged(colour, in.relative), 1.0);
}
