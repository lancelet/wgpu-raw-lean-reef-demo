// The seabed's map (`Reef/Render.lean`): what the sand is told about the
// reef's framework over the framework's box, baked once, on the first
// frame (when the frame's uniforms hold the floor and the sun): a texel
// each few centimetres of the floor, at the floor's height there.
//
//   r: the sky the framework leaves the sand (1 all of it);
//   g: the sun it leaves the sand (1 all of it), its shadow marched
//      through the field, between its points;
//   b, a: not yet used (the seabed's fields will go here).
//
// The sand reads it (`seabedAt`, shaders/frame.wgsl) instead of marching
// the field every pixel, every frame.

@group(1) @binding(0) var seabedOut : texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8)
fn bakeSeabed(@builtin(global_invocation_id) id : vec3u) {
  let size = textureDimensions(seabedOut);
  if (any(id.xy >= size)) { return; }
  let extent = (frame.reefDims.xz - 1.0) * frame.reef.w;
  let xz = frame.reef.xz + (vec2f(id.xy) + 0.5) / vec2f(size) * extent;
  let p = vec3f(xz.x, height(xz), xz.y);
  let shade = reefShade(p);
  textureStore(seabedOut, id.xy, vec4f(shade, 0.0, 0.0));
}
