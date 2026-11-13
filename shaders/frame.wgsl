// The frame's uniforms, as every shader reads them, put before each
// (`Reef/Render.lean`): as `Reef.frameBytes` encodes them, 112 bytes.

struct Frame {
  viewProj : mat4x4f,
  camera   : vec4f,  // where the camera is; w unused
  grid     : vec4f,  // spacing, major, extent, fade
  floor    : vec4f,  // a patch's cells a side, the leaves' range, the morph fraction, unused
}

@group(0) @binding(0) var<uniform> frame : Frame;

// The background, which what is far fades into: the colour the frame is
// cleared to.
const background = vec3f(0.02, 0.05, 0.09);

// How much of something `dist` from the camera shows, the rest fog.
fn visible(dist : f32) -> f32 {
  return exp(-dist / frame.grid.w);
}
