// The bommies, drawn (`Reef/Bommies.lean`): the mesh baked at the start
// (shaders/reefbake.wgsl), its vertices read from a buffer. The material
// is old reef limestone: grey, crusted pink with coralline algae on the
// faces that see the light, furred olive-brown with algal turf, dusted
// with sand where it is flat enough to hold it, darker in its hollows; a
// fine roughness of pits and nodules over it all. Lit as the sand is: the
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

// The sun's light at `p` on the rock, its normal `n`, marched through the
// reef's field toward the sun (`reefDistance`): for where the shadow
// baked at the vertices changes, which between vertices a hand apart
// would draw its edge as their triangles'.
fn rockShadow(p : vec3f, n : vec3f) -> f32 {
  let sun = frame.sun.xyz;
  var t = 0.06;
  var lit = 1.0;
  for (var s = 0; s < 24; s++) {
    let h = reefDistance(p + n * 0.04 + sun * t, true);
    lit = min(lit, 0.5 + 0.5 * h / (0.05 * t + 0.015));
    t += clamp(h * 0.8, 0.03 + 0.03 * t, 0.5);
    if (lit <= 0.0 || t > 8.0) { break; }
  }
  return smoothstep(0.0, 1.0, clamp(lit, 0.0, 1.0));
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let world = toWorld(in.relative);
  let dist = length(in.relative);
  let geometric = normalize(in.normal);
  var n = geometric;
  var w = pow(abs(geometric), vec3f(4.0));
  w = w / (w.x + w.y + w.z);
  // Five scales of noise over the rock, from a couple of metres to a
  // couple of centimetres; the finest only near, where it shows.
  let near = 1.0 - smoothstep(6.0, 22.0, dist);
  let large = triplanar(world * 0.55 + 3.0, w);
  let mid = triplanar(world * 1.7 + 11.0, w);
  let smallG = triplanarGrad(world * 6.0 + 21.0, 6.0, w);
  var detailG = vec4f(0.0);
  var gritG = vec4f(0.0);
  var microG = vec4f(0.0);
  if (dist < 22.0) { detailG = triplanarGrad(world * 19.0 + 5.0, 19.0, w); }
  if (dist < 8.0) { gritG = triplanarGrad(world * 47.0 + 9.0, 47.0, w); }
  if (dist < 2.0) { microG = triplanarGrad(world * 140.0 + 2.0, 140.0, w); }
  // (Each octave faded out before the distance it stops being read at,
  // its gradient with it, so that no edge shows where it stops.)
  gritG = gritG * (1.0 - smoothstep(5.0, 8.0, dist));
  microG = microG * (1.0 - smoothstep(1.0, 2.0, dist));
  detailG = detailG * (1.0 - smoothstep(16.0, 22.0, dist));
  let small = smallG.x;
  let detail = detailG.x;
  let grit = gritG.x;
  let micro = microG.x;
  // The fine roughness: the knobs of old coral heads, the cups of dead
  // polyps, grit, and, a hand away, the rock's own grain; a bump of their
  // exact gradients, fading where it would shimmer.
  let knobs = 1.0 - abs(small);
  let cupT = clamp((detail - 0.3) / 0.4, 0.0, 1.0);
  let cups = cupT * cupT * (3.0 - 2.0 * cupT);
  let relief = knobs * knobs * 0.5 + (1.0 - abs(detail)) * 0.25 + grit * 0.1 - cups * 0.3;
  let slope = (0.07 * knobs * (-sign(small)) * smallG.yzw
             - 0.008 * sign(detail) * detailG.yzw
             - 0.004 * 6.0 * cupT * (1.0 - cupT) / 0.4 * detailG.yzw
             + 0.002 * gritG.yzw + 0.0006 * microG.yzw) * near;
  n = normalize(n - (slope - n * dot(n, slope)));
  // The material. Under it all, old limestone, pale and a little warm;
  // over it, in patches a hand to a metre across, their edges ragged:
  // coralline algae's crusts, pink to mauve, where the light is good;
  // algal turf, olive and brown, the commonest cover of a reef's rock;
  // bleached patches of dead coral, newly bare;
  // dark sponge and sea squirts in the shade;
  // sand on what is flat enough to hold it;
  // and the hollows darker.
  let up = clamp(geometric.y, -1.0, 1.0);
  let ragged = 0.35 * small + 0.25 * detail;
  var albedo = vec3f(0.58, 0.55, 0.48) * (0.88 + 0.12 * small + 0.08 * detail);
  let turf = smoothstep(-0.35, 0.35, large + 0.4 * mid + ragged);
  albedo = mix(albedo, mix(vec3f(0.33, 0.33, 0.16), vec3f(0.4, 0.31, 0.2), smoothstep(-0.6, 0.6, mid + detail * 0.3)),
               turf * 0.8);
  let coralline = smoothstep(0.0, 0.6, mid - 0.5 * large + ragged) * smoothstep(-0.4, 0.3, up);
  albedo = mix(albedo, mix(vec3f(0.68, 0.43, 0.52), vec3f(0.55, 0.39, 0.56), smoothstep(-0.5, 0.5, small)),
               coralline * 0.75);
  let bare = smoothstep(0.45, 0.85, small + 0.4 * mid + 0.3 * detail) * (1.0 - coralline);
  albedo = mix(albedo, vec3f(0.76, 0.74, 0.68), bare * 0.6);
  let sponge = smoothstep(0.4, 0.9, -mid - 0.3 * small + 0.2 * detail) * (1.0 - smoothstep(0.6, 0.95, in.shadow));
  albedo = mix(albedo, vec3f(0.42, 0.18, 0.12), sponge * 0.7);
  // Sand, where it is flat enough to lie: the floor's own grains, read
  // from above as the floor's are (only on what faces up), speckled.
  let dust = smoothstep(0.75, 0.92, up) * smoothstep(-0.4, 0.2, large + 0.3 * small + 0.2);
  if (dust > 0.0) {
    let grain = textureSampleLevel(grains, rippleSampler, world.xz / frame.grain.x, 0,
                                   log2(max(1.0, dist * frame.camera.w * 512.0 / frame.grain.x)));
    albedo = mix(albedo, vec3f(0.66, 0.5, 0.26) * mix(1.0, 2.0 * grain.a, frame.grain.z), dust * 0.9);
  }
  // Mottled at a hand's scale and finer: the crusts and films of what
  // grows on the rock, never one even colour; darker in its hollows, the
  // bake's, and the relief's own, close up.
  // Close up, crunchy: grit, pale and dark, a couple of centimetres, and
  // the polyps' cups dark.
  let crunch = (0.78 + 0.32 * detail) * (0.8 + 0.4 * smoothstep(-0.5, 0.5, grit))
    * (1.0 - 0.35 * cups) * (0.85 + 0.3 * smoothstep(-0.4, 0.4, micro));
  albedo = albedo * mix(1.0, crunch, (1.0 - dust) * near);
  albedo = albedo * mix(0.45, 1.0, in.ao) * mix(1.0, 0.55 + 0.6 * relief, near * (1.0 - dust));
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
  let shade = cloudShade(world, t) * (1.0 - 0.85 * floating) * shadow;
  let diffuse = max(dot(n, sun), 0.0);
  let sky = frame.skylight.rgb * in.ao * (0.55 + 0.45 * up);
  let light = sky + frame.sunlight.rgb * diffuse * focus * down * shade;
  return vec4f(fogged(albedo * light, in.relative), 1.0);
}
