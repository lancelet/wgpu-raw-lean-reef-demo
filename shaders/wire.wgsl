// The wireframe: a fragment entry for every material's shader, which the
// program puts before the material's own, drawn as lines over its triangles
// with the material's vertex shader, so the lines are where the triangles
// are. The lines are a pixel wide, as WebGPU draws them, and fade with
// distance, faster than the scene does (far off, many lines cross a pixel,
// and would pile up opaque): the distance from the fragment's position
// (its w is the reciprocal of the depth it was projected at).
//
// WebGPU allows lines no depth bias, so a material's vertex shader places
// the wireframe's vertices itself, through `place`: a little nearer the
// camera along the line of sight, which leaves them where they are on the
// screen and in front of the triangles in depth. `wireframe` is set true
// on the wireframe's pipeline alone, as a constant.

override wireframe : bool = false;

// `world`, where the vertex goes: nearer the camera by a fraction of its
// distance, for the wireframe.
fn place(world : vec3f) -> vec3f {
  if (wireframe) {
    return frame.camera.xyz + (world - frame.camera.xyz) * 0.998;
  }
  return world;
}

@fragment fn fs_wire(@builtin(position) position : vec4f) -> @location(0) vec4f {
  let depth = 1.0 / position.w;
  return vec4f(0.05, 0.1, 0.45, visible(4.0 * depth));
}
