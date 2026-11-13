// The wireframe: a fragment entry for every material's shader, which the
// program puts before the material's own, drawn as lines over its triangles
// with the material's vertex shader, so the lines are where the triangles
// are. The lines are a pixel wide, as WebGPU draws them, and fade with
// distance, faster than the scene does (far off, many lines cross a pixel,
// and would pile up opaque): the distance from the fragment's position
// (its w is the reciprocal of the depth it was projected at).

@fragment fn fs_wire(@builtin(position) position : vec4f) -> @location(0) vec4f {
  let depth = 1.0 / position.w;
  return vec4f(1.0, 0.65, 0.2, visible(4.0 * depth));
}
