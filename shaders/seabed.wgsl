// The seabed's map (`Reef/Render.lean`): what the reef's framework has
// made of the sand about it, over the framework's box, baked once, on
// the first frame (when the frame's uniforms hold the floor and the
// sun): a texel each few centimetres of the floor.
//
//   r: the sky the framework leaves the sand (1 all of it);
//   g: the sun it leaves the sand (1 all of it), its shadow marched
//      through the field, between its points;
//   b: how far it has lowered or raised the sand, in metres;
//   a: how freely the sand moves (1 as on the open floor): its ripples,
//      and what lives in it, follow.
//
// The surge runs to and fro along the waves' direction, the way the
// ripples face. Where it meets the rock it is split, quickened about the
// rock's flanks and its foot, where it scours a moat; behind the rock
// (behind both ways, in turn) it is slack, and drops what it carries in
// a tail of sand, smooth, the ripples dying out in it, and what burrows
// left undisturbed.
//
// The sand reads it (`seabedAt`, shaders/frame.wgsl) instead of marching
// the field every pixel, every frame.

@group(1) @binding(0) var seabedOut : texture_storage_2d<rgba16float, write>;

// How sheltered `p`, on the sand, is from the surge coming along
// `along`: the rock upstream of it, nearer and more, the more.
fn shelterFrom(p : vec3f, along : vec2f) -> f32 {
  var shelter = 0.0;
  for (var k = 1; k <= 16; k++) {
    let x = f32(k) * 0.35;
    let q = p + vec3f(along.x, 0.0, along.y) * x;
    let inRock = smoothstep(0.15, -0.1, reefDistance(q, true));
    shelter = max(shelter, inRock * exp(-x / 2.2));
  }
  return shelter;
}

@compute @workgroup_size(8, 8)
fn bakeSeabed(@builtin(global_invocation_id) id : vec3u) {
  let size = textureDimensions(seabedOut);
  if (any(id.xy >= size)) { return; }
  let extent = (frame.reefDims.xz - 1.0) * frame.reef.w;
  let xz = frame.reef.xz + (vec2f(id.xy) + 0.5) / vec2f(size) * extent;
  let open = baseHeight(xz);
  let dir = frame.ripple.xy;
  // The rock about: how near, at the sand; how sheltered, each way, a
  // hand above it, and on the whole, the surge coming each way in turn.
  let near = max(reefDistance(vec3f(xz.x, open + 0.1, xz.y), true), 0.0);
  let above = vec3f(xz.x, open + 0.3, xz.y);
  let lee = 0.5 * (shelterFrom(above, dir) + shelterFrom(above, -dir));
  // Quickened about the rock, within a metre or so of it, where it is not
  // in the rock's lee.
  let quick = exp(-near / 0.7) * (1.0 - lee);
  // The moat: the scour at the rock's foot, deepest against it, a couple
  // of hand-spans deep, the deeper where the flow is quick; the tails:
  // sand dropped in the lee, off the rock, a hand high.
  let moat = -0.2 * exp(-near / 0.5) * (0.6 + 0.4 * quick);
  let tail = 0.12 * lee * smoothstep(0.4, 1.4, near);
  let bed = moat + tail;
  let moves = clamp((1.0 - 0.85 * lee) * (1.0 + 0.5 * quick), 0.0, 1.5);
  let shade = reefShade(vec3f(xz.x, open + bed, xz.y));
  textureStore(seabedOut, id.xy, vec4f(shade, bed, moves));
}
