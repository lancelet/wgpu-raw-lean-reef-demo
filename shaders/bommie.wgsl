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
// weighted by how square it faces them: about -1 to 1.
fn triplanar(p : vec3f, n : vec3f) -> f32 {
  var w = pow(abs(n), vec3f(4.0));
  w = w / (w.x + w.y + w.z);
  return 2.2 * (noise(p.yz) * w.x + noise(p.xz + 7.3) * w.y + noise(p.xy + 3.1) * w.z);
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let world = toWorld(in.relative);
  let dist = length(in.relative);
  var n = normalize(in.normal);
  // The fine roughness: the knobs of old coral heads, pits, the cups of
  // dead polyps; a bump by the surface's own derivatives, fading where it
  // would shimmer.
  let near = 1.0 - smoothstep(5.0, 18.0, dist);
  let knobs = 1.0 - abs(triplanar(world * 4.0, n));
  let polyps = 1.0 - abs(triplanar(world * 19.0 + 5.0, n));
  let grit = triplanar(world * 47.0 + 9.0, n);
  let relief = knobs * knobs * 0.6 + polyps * 0.3 + grit * 0.1;
  let h = (0.03 * knobs * knobs + 0.008 * polyps + 0.002 * grit) * near;
  let dpx = dpdx(world);
  let dpy = dpdy(world);
  let r1 = cross(dpy, n);
  let r2 = cross(n, dpx);
  let det = dot(dpx, r1);
  let grad = sign(det) * (dpdx(h) * r1 + dpdy(h) * r2);
  n = normalize(abs(det) * n - grad);
  // The material. Under it all, old limestone, pale and a little warm;
  // over it, in patches a hand to a metre across:
  // coralline algae's crusts, pink to mauve, where the light is good;
  // algal turf, olive and brown, the commonest cover of a reef's rock;
  // bleached patches of dead coral, newly bare;
  // dark sponge and sea squirts in the shade;
  // sand dusted on what is flat enough to hold it;
  // and the hollows darker.
  let up = clamp(n.y, -1.0, 1.0);
  let large = triplanar(world * 0.55 + 3.0, n);
  let mid = triplanar(world * 1.7 + 11.0, n);
  let small = triplanar(world * 6.0 + 21.0, n);
  var albedo = vec3f(0.58, 0.55, 0.48) * (0.9 + 0.15 * small);
  let turf = smoothstep(-0.25, 0.25, large + 0.4 * mid);
  albedo = mix(albedo, mix(vec3f(0.33, 0.33, 0.16), vec3f(0.4, 0.31, 0.2), smoothstep(-0.5, 0.5, mid)),
               turf * 0.85);
  let coralline = smoothstep(0.1, 0.45, mid - 0.5 * large + 0.3 * small)
    * smoothstep(-0.4, 0.3, up);
  albedo = mix(albedo, mix(vec3f(0.7, 0.42, 0.52), vec3f(0.55, 0.38, 0.58), smoothstep(-0.4, 0.4, small)),
               coralline * 0.85);
  let bare = smoothstep(0.55, 0.75, small + 0.4 * mid) * (1.0 - coralline);
  albedo = mix(albedo, vec3f(0.78, 0.76, 0.7), bare * 0.7);
  let sponge = smoothstep(0.5, 0.8, -mid - 0.3 * small) * (1.0 - smoothstep(0.6, 0.95, in.shadow));
  albedo = mix(albedo, vec3f(0.42, 0.18, 0.12), sponge * 0.8);
  let dust = smoothstep(0.7, 0.9, up) * smoothstep(-0.3, 0.3, triplanar(world * 1.3, n) + 0.2);
  albedo = mix(albedo, vec3f(0.66, 0.5, 0.26) * (0.9 + 0.2 * small), dust * 0.85);
  // Its hollows: the bake's, and the relief's own, close up.
  let crevice = mix(0.5, 1.0, in.ao) * mix(1.0, 0.55 + 0.6 * relief, near * (1.0 - dust));
  albedo = albedo * crevice;
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
  let shade = cloudShade(world, t) * (1.0 - 0.85 * floating) * in.shadow;
  let diffuse = max(dot(n, sun), 0.0);
  let sky = frame.skylight.rgb * in.ao * (0.55 + 0.45 * up);
  let light = sky + frame.sunlight.rgb * diffuse * focus * down * shade;
  return vec4f(fogged(albedo * light, in.relative), 1.0);
}
