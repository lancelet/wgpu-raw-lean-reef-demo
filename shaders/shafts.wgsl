// The light in the water (`Reef/Render.lean`): the sun's light scattered
// toward the camera by the fine matter the water holds, brighter in the
// columns under the surface's bright filaments, so the caustics show as
// shafts. One triangle over a target half the scene's size, after the
// scene is drawn (added over it, smoothed, by shaders/shaftblend.wgsl),
// each pixel marching its view ray from the camera to what it sees (the
// depth buffer says how far), summing at each step the sun's light there,
// through the caustics' loop where the sun's ray through the step meets
// the surface, taken by the water on its way down and again on its way
// to the camera, scattered forward more than back; added to the pixel.
// The steps begin at an offset that differs pixel to pixel, so that few
// steps leave no bands, only a fine grain the eye does not see.

@group(1) @binding(0) var sceneDepth : texture_depth_2d;

struct Out {
  @builtin(position) position : vec4f,
}

@vertex fn vs(@builtin(vertex_index) i : u32) -> Out {
  let xy = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
  var out : Out;
  out.position = vec4f(xy * 2.0 - 1.0, 0.0, 1.0);
  return out;
}

// A number in [0, 1) for the pixel `p`, differing from its neighbours'
// as evenly as can be (Jimenez's interleaved gradient noise), so that
// the steps' offsets make a fine, even grain and not a blotchy one.
fn dither(p : vec2u) -> f32 {
  let f = vec2f(p);
  return fract(52.9829189 * fract(0.06711056 * f.x + 0.00583715 * f.y));
}

// Henyey and Greenstein's phase: how much light going one way is
// scattered to another at `cosine` between them, `g` the asymmetry,
// forward for g > 0.
fn phase(cosine : f32, g : f32) -> f32 {
  let d = 1.0 + g * g - 2.0 * g * cosine;
  return (1.0 - g * g) / (4.0 * 3.14159265 * d * sqrt(d));
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  // At half size: the scene's pixel is twice this one.
  let pixel = vec2u(in.position.xy);
  let scenePixel = pixel * 2u;
  let ndc = (in.position.xy * 2.0 / frame.screen.xy) * 2.0 - 1.0;
  let dir = normalize(frame.forward.xyz + frame.right.xyz * (ndc.x * frame.right.w)
                      - frame.up.xyz * (ndc.y * frame.up.w));
  // How far the pixel sees: the depth buffer's, made a distance along
  // the ray (the projection's: near * far / (far - z * (far - near)) is
  // the view's depth), or the water's reach where there is nothing.
  let z = textureLoad(sceneDepth, vec2i(scenePixel), 0);
  let near = frame.surface.z;
  let far = frame.surface.w;
  let viewDepth = near * far / (far - z * (far - near));
  let along = max(dot(dir, frame.forward.xyz), 0.05);
  let reach = frame.shaft.z;
  let dist = min(select(viewDepth / along, reach, z >= 1.0), reach);
  let steps = i32(frame.shaft.y);
  let dt = dist / f32(steps);
  let sun = frame.sun.xyz;
  let extinct = frame.extinct.rgb;
  // Forward-scattering, a little back: the sun's light comes down along
  // -sun, the view looks along dir, so the angle between the light and
  // what reaches the camera (going along -dir) has cosine dot(sun, dir).
  let scatter = phase(dot(sun, dir), 0.6) * 0.8 + 0.2 / (4.0 * 3.14159265);
  let moments = frame.caustic.z;
  let moment = fract(frame.screen.z / frame.caustic.y) * moments;
  let layer = i32(floor(moment));
  let next = (layer + 1) % i32(moments);
  let blend = fract(moment);
  let causticTile = frame.caustic.x;
  // The caustics read sharp: the shafts are columns, and a step along
  // the ray crosses them, it does not average them (the dither does
  // that, between pixels); only far off, where a pixel spans cells, the
  // level the pixel's footprint asks.
  let texelsAcross = f32(textureDimensions(caustics).x);
  let pixelAt = frame.camera.w;  // radians a pixel
  var light = vec3f(0.0);
  // The sky's light scattered too, from every direction: brightest just
  // under the surface, where the sky is all above, fading with depth.
  var ambient = vec3f(0.0);
  let clouds = cloudShade(frame.camera.xyz, frame.screen.z);
  let offset = dither(pixel);
  // The swell's drift of the chop, found once, at the march's middle: it
  // varies over tens of metres, and the march is shorter than that.
  let middle = frame.camera.xyz + dir * (dist * 0.5);
  let middleFall = (frame.water.x - middle.y) / max(sun.y, 0.1);
  let middleOnSurface = middle.xz + sun.xz * middleFall;
  let bending = swellBending(middleOnSurface, frame.screen.z, middleFall);
  let drift = swellDriftAt(middleOnSurface, frame.screen.z) + bending.xy;
  for (var i = 0; i < steps; i++) {
    let t = (f32(i) + offset) * dt;
    let p = frame.camera.xyz + dir * t;
    // Under the surface only.
    if (p.y >= frame.water.x) { continue; }
    let toSurface = (frame.water.x - p.y) / max(sun.y, 0.1);
    let onSurface = p.xz + sun.xz * toSurface - drift;
    let uv = onSurface / causticTile;
    // Three levels softer than the pixel asks: the fine matter the light
    // scatters from blurs the columns, the small cells merge, and only
    // the broad bright filaments are left to make rays.
    let lod = 3.5 + log2(max(1.0, t * pixelAt * texelsAcross / causticTile));
    let gathered = mix(textureSampleLevel(caustics, rippleSampler, uv, layer, lod).rgb,
                       textureSampleLevel(caustics, rippleSampler, uv, next, lod).rgb,
                       blend) * causticBrightest;
    // The rays are the light above the mean, a few times over; the mean
    // itself an even glow, dimmer.
    // Rising smoothly from the mean, so a ray's edge is soft.
    let above = max(gathered - vec3f(0.9), vec3f(0.0));
    let rays = above * above * 2.0;
    let focus = mix(vec3f(1.0), vec3f(0.35) + rays, frame.water.y) * bending.z;
    // The sun's light at the step: taken by the water on its way down;
    // and what scatters toward the camera, taken on its way there.
    let down = exp(-extinct * toSurface);
    let toCamera = exp(-extinct * t);
    light += frame.sunlight.rgb * focus * down * toCamera * dt * clouds;
    ambient += frame.skylight.rgb * exp(-extinct * (frame.water.x - p.y) * 2.0) * toCamera * dt;
  }
  return vec4f(light * extinct * scatter * frame.shaft.x + ambient * extinct * 0.35, 1.0);
}
