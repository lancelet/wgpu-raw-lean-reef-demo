// The wireframe: for every material's shader, which the program puts this
// before, a fragment entry drawing the mesh's edges over its triangles.
// The triangles are drawn again, with no indices, every corner its own
// vertex, so that the vertex shader can give each corner its barycentric
// coordinate (`barycentric`, from the vertex's index, at location 7, which
// every material's vertex output carries): across a triangle they
// interpolate to the distances from its edges, and `fwidth` says how far
// a pixel is, so the edges are lines a pixel and a half wide, anti-aliased,
// whatever the distance, as the grid's are. Being the same triangles, they
// are at the same depth as the material's, and pass a test of less or
// equal. They fade as the triangles shrink on the screen (far off, or
// fine), gone below a few pixels, where they would pile up opaque: the
// derivatives say how many pixels a triangle spans.

// Corner `index % 3`'s barycentric coordinate.
fn barycentric(index : u32) -> vec3f {
  let corner = index % 3u;
  return vec3f(f32(corner == 0u), f32(corner == 1u), f32(corner == 2u));
}

@fragment fn fs_wire(@location(7) bary : vec3f) -> @location(0) vec4f {
  let width = max(fwidth(bary), vec3f(1e-6));
  // The distance to the nearest edge, in pixels: a line a pixel wide.
  let d = bary / width;
  let edge = min(min(d.x, d.y), d.z);
  let line = 1.0 - smoothstep(0.3, 1.0, edge);
  // The triangle's size on the screen, in pixels, about (the mean of its
  // longest and shortest, as a foreshortened one is long one way): the
  // lines go as it falls below three pixels, gone at one.
  let longest = 1.0 / min(min(width.x, width.y), width.z);
  let shortest = 1.0 / max(max(width.x, width.y), width.z);
  let size = sqrt(longest * shortest);
  let alpha = line * smoothstep(1.0, 3.0, size);
  if (alpha < 0.004) {
    discard;
  }
  return vec4f(0.05, 0.1, 0.45, alpha);
}
