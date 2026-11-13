// The sand: the floor, a quadtree of patches (`Reef/Floor.lean`), each
// the one lattice placed and scaled by its node's record, flat for now
// (`height` is 0), lit by a sun from above, fading into the background
// with distance as the grid does.

// The nodes drawn this frame: each its corner nearest the origin (x, z),
// its size, and its level, 0 the leaves.
@group(0) @binding(1) var<storage, read> nodes : array<vec4f>;

struct Out {
  @builtin(position) position : vec4f,
  @location(0)       relative : vec3f,  // to the camera
  @location(7)       bary     : vec3f,  // the wireframe's (shaders/wire.wgsl)
}

// The floor's height at `xz`, in the world: flat, for now.
fn height(xz : vec2f) -> f32 {
  return 0.0;
}

// The floor's point at `xz`, relative to the camera, as `height` says.
fn floorAt(xz : vec2f) -> vec3f {
  let world = xz + frame.camera.xz;
  return vec3f(xz.x, height(world) - frame.camera.y, xz.y);
}

// A lattice vertex of the node `instance` (its record relative to the
// camera): placed in the node, and, near the node's range, morphed onto
// its parent's lattice (every other vertex moved onto the one before it),
// so that the node meets a neighbour at the level above with no crack,
// and leaves for the level above with no pop. The morph begins at the
// range's `morph` fraction of the way out, by the vertex's own distance
// from the eye.
@vertex fn vs(@location(0) lattice : vec2f,
              @builtin(vertex_index) index : u32,
              @builtin(instance_index) instance : u32) -> Out {
  let node = nodes[instance];
  let cells = frame.floor.x;
  let range = frame.floor.y * exp2(node.w);
  let start = range * frame.floor.z;
  let dist = length(floorAt(node.xy + lattice / cells * node.z));
  let t = clamp((dist - start) / (range - start), 0.0, 1.0);
  let morphed = lattice - fract(lattice * 0.5) * 2.0 * t;
  var out : Out;
  out.relative = floorAt(node.xy + morphed / cells * node.z);
  out.position = frame.viewProj * vec4f(out.relative, 1.0);
  out.bary = barycentric(index);
  return out;
}

@fragment fn fs(in : Out) -> @location(0) vec4f {
  let normal = vec3f(0.0, 1.0, 0.0);
  let sun = normalize(vec3f(0.3, 1.0, 0.2));
  let sand = vec3f(0.55, 0.47, 0.30);
  let light = 0.25 + 0.75 * max(dot(normal, sun), 0.0);
  let color = sand * light;
  let fade = visible(length(in.relative));
  return vec4f(mix(background, color, fade), 1.0);
}
