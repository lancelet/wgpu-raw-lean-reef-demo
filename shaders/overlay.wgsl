// The overlay: text, as pixels in a texture (white, its alpha the text's),
// drawn a pixel to a pixel at a place in the target, on a translucent panel
// a little larger, blended over what is there.

// As `Reef.placementBytes` encodes it: 32 bytes, all in pixels, from the
// target's top left.
struct Placement {
  extent  : vec2f,  // the target's size
  origin  : vec2f,  // the text's top left
  size    : vec2f,  // the text's size
  padding : f32,    // the panel's, around the text
  pad     : f32,
}

@group(0) @binding(0) var<uniform> placement : Placement;
@group(0) @binding(1) var text : texture_2d<f32>;

@vertex fn vs(@builtin(vertex_index) v : u32) -> @builtin(position) vec4f {
  // Two triangles: the panel's corners, 0..1 across and down.
  var corners = array<vec2f, 6>(
    vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(0.0, 1.0),
    vec2f(0.0, 1.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0));
  let pad = vec2f(placement.padding);
  let p = placement.origin - pad + corners[v] * (placement.size + 2.0 * pad);
  // Pixels, down from the top, to clip space, up from the bottom.
  let clip = p / placement.extent * 2.0 - 1.0;
  return vec4f(clip.x, -clip.y, 0.0, 1.0);
}

@fragment fn fs(@builtin(position) position : vec4f) -> @location(0) vec4f {
  // The pixel's place in the text: its centre is at + 0.5.
  let p = floor(position.xy - placement.origin);
  var coverage = 0.0;
  if (all(p >= vec2f(0.0)) && all(p < placement.size)) {
    coverage = textureLoad(text, vec2i(p), 0).a;
  }
  let panel = vec4f(0.01, 0.04, 0.07, 0.55);
  let ink = vec4f(0.7, 0.95, 1.0, 1.0);
  return mix(panel, ink, coverage);
}
