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
// The surge's flow about the framework, for the ripples: what its
// potential and stream function gain, and its potential's gradient.
@group(1) @binding(1) var flowOut : texture_storage_2d<rgba16float, write>;
// The bommies as the surge sees them, circles on the floor: centre x, z,
// radius, unused (`Reef.bommieCircles`).
@group(1) @binding(2) var<storage, read> circles : array<vec4f>;

// What the bommies add to the surge's complex potential at `xz`, the
// open floor's being the position itself along the surge and across it:
// each a doublet, the flow about a cylinder (w = z + a^2 / z), so that
// the potential's lines, along which ripples lie, wrap round the rock,
// and the streamlines with them. Inside a circle, where its doublet
// would blow up, held at its rim's (the rock hides it). Each fades out
// some radii away, so that the box's edge sees none.
fn doublets(xz : vec2f) -> vec2f {
  let dir = frame.ripple.xy;
  let perp = vec2f(-dir.y, dir.x);
  var gain = vec2f(0.0);
  for (var i = 0u; i < arrayLength(&circles); i++) {
    let c = circles[i];
    let rel = xz - c.xy;
    let z = vec2f(dot(rel, dir), dot(rel, perp));
    let a2 = c.z * c.z;
    let r2 = max(dot(z, z), a2);
    let fade = 1.0 - smoothstep(3.0 * c.z, 6.0 * c.z, sqrt(r2));
    // a^2 / z = a^2 conj(z) / |z|^2.
    gain += vec2f(z.x, -z.y) * (a2 / r2) * fade;
  }
  return gain;
}

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
  // The rock about: how near, at the sand; how sheltered, a hand above
  // it, from the surge coming either way (the more sheltered way: the
  // sand there is left alone half of every wave, and the ripples cannot
  // keep up their shape on the other half).
  let near = max(reefDistance(vec3f(xz.x, open + 0.1, xz.y), true), 0.0);
  let above = vec3f(xz.x, open + 0.3, xz.y);
  let lee = max(shelterFrom(above, dir), shelterFrom(above, -dir));
  // Quickened about the rock, within a metre or so of it, where it is not
  // in the rock's lee.
  let quick = exp(-near / 0.7) * (1.0 - lee);
  // The moat: the scour at the rock's foot, deepest against it, a couple
  // of hand-spans deep, the deeper where the flow is quick; the tails:
  // sand dropped in the lee, off the rock, a hand high.
  let moat = -0.32 * exp(-near / 0.75) * (0.6 + 0.4 * quick);
  let tail = 0.16 * lee * smoothstep(0.5, 1.6, near);
  // The lip: right against the rock the sand rises a little into it,
  // a fillet a few centimetres high and a hand wide, the sand banked
  // where the rock meets it, so that the floor turns up into the rock
  // rather than running into it.
  let lip = 0.06 * exp(-near / 0.08);
  let bed = moat + tail + lip;
  let moves = clamp((1.0 - smoothstep(0.1, 0.7, lee)) * (1.0 + 0.5 * quick), 0.0, 1.5);
  var shade = reefShade(vec3f(xz.x, open + bed, xz.y));
  // And right against the rock, in the last hand-span, the sand sees
  // little of the sky: the contact's own shade, which the broad occlusion
  // is too soft to give.
  let touching = max(reefDistance(vec3f(xz.x, open + bed + 0.05, xz.y), true), 0.0);
  shade.x *= mix(0.4, 1.0, smoothstep(0.0, 0.18, touching));
  textureStore(seabedOut, id.xy, vec4f(shade, bed, moves));
  // The flow, for the ripples: its potential's gradient by differences
  // (the stream function's is the same turned a right angle, the map
  // being conformal), in the world's axes.
  let e = 0.01;
  let gx = (doublets(xz + vec2f(e, 0.0)).x - doublets(xz - vec2f(e, 0.0)).x) / (2.0 * e);
  let gz = (doublets(xz + vec2f(0.0, e)).x - doublets(xz - vec2f(0.0, e)).x) / (2.0 * e);
  textureStore(flowOut, id.xy, vec4f(doublets(xz), gx, gz));
}
