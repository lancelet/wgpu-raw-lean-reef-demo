// The glowing creatures: each a soft disc of light, drawn as a quad
// (instanced, one per creature, from the storage buffer), bobbing and
// pulsing at its own phase, added to what is behind it.

struct Frame {
  time   : f32,
  aspect : f32,  // width / height
  pad    : vec2f,
}

// As `Reef.Creature` encodes one: 32 bytes.
struct Creature {
  center : vec2f,  // fractions of the width (across) and height (up)
  radius : f32,    // a fraction of the height
  phase  : f32,
  color  : vec4f,
}

@group(0) @binding(0) var<uniform> frame : Frame;
@group(0) @binding(1) var<storage, read> creatures : array<Creature>;

struct Out {
  @builtin(position) position : vec4f,
  @location(0)       offset   : vec2f,  // -1..1 across the quad
  @location(1)       color    : vec4f,
}

@vertex fn vs(@builtin(vertex_index) v : u32,
              @builtin(instance_index) i : u32) -> Out {
  let c = creatures[i];
  let t = frame.time;
  // Two triangles: the quad's corners.
  var corners = array<vec2f, 6>(
    vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(-1.0, 1.0),
    vec2f(-1.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0));
  let corner = corners[v];
  let bob = vec2f(sin(t * 0.23 + c.phase * 1.7) * 0.02,
                  sin(t * 0.61 + c.phase) * 0.03);
  let pulse = 0.65 + 0.35 * sin(t * 1.1 + c.phase * 2.3);
  // In units of the height: across 0..aspect, up 0..1.
  let center = vec2f(c.center.x * frame.aspect, c.center.y);
  let p = center + bob + corner * c.radius * (0.9 + 0.2 * pulse);
  var out : Out;
  // Across, 0..aspect to clip space's -1..1; up, 0..1 likewise.
  out.position = vec4f(p.x / frame.aspect * 2.0 - 1.0, p.y * 2.0 - 1.0,
                       0.0, 1.0);
  out.offset = corner;
  out.color = vec4f(c.color.rgb * pulse, c.color.a);
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let d2 = dot(in.offset, in.offset);
  // A bright core in a soft halo, nothing past the quad's circle.
  let glow = exp(-d2 * 9.0) + 0.35 * exp(-d2 * 2.5);
  let edge = 1.0 - smoothstep(0.8, 1.0, sqrt(d2));
  return vec4f(in.color.rgb * glow * edge * in.color.a, 1.0);
}
