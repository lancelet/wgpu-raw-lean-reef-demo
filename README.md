# wgpu-raw-lean-reef-demo

[![CI][ci-badge]][ci]

[ci]: https://github.com/lancelet/wgpu-raw-lean-reef-demo/actions/workflows/ci.yml
[ci-badge]: https://github.com/lancelet/wgpu-raw-lean-reef-demo/actions/workflows/ci.yml/badge.svg?branch=main

A bioluminescent reef, drawn with WebGPU from [Lean], natively (Linux, macOS,
Windows) and in a browser: [see it in yours][pages] (it needs WebGPU).

[Lean]: https://lean-lang.org
[pages]: https://lancelet.github.io/wgpu-raw-lean-reef-demo/

It is also an example of a package that uses the raw WebGPU bindings,
[webgpu-raw-lean][bindings], and builds both ways. So far it draws the
floor the reef will stand on, flat sand as a quadtree of patches chosen by
their distance from the eye, with a grid and a wireframe to see it by, and
a camera to look at it with.

[bindings]: https://github.com/lancelet/webgpu-raw-lean

## Building and running

You need Lean through [elan], and a C compiler with the C library's headers
(`cc`, or the one `CC` names; on Windows, MinGW's: `CC=gcc`), `curl` and
`unzip`; on Linux and macOS, `cmake` too, to build SDL3 (on Linux, with the
X11 and Wayland headers, as [CI](.github/workflows/ci.yml) installs them;
on macOS, with clang, for SDL3's Objective-C: if your `cc` is GCC, set
`CC=clang`). With [Nix], `nix develop` is a shell with all of that, for
Linux and macOS, and the web build's tools too. Then:

    lake build
    lake exe reef

It fills the screen; F leaves it, or fills it again, and Escape ends it.
`reef --windowed` draws in a window instead; `reef --frames N` ends after
`N` frames; `reef --headless` draws with no display (macOS only);
`reef --screenshot FILE` draws one frame into that file, a PPM image, and
ends (with `--headless`, with no display at all); `reef --camera
X,Y,Z,YAW,PITCH` starts the camera there (metres, and degrees), as a
screenshot from a chosen view needs; `--wireframe on|off` and `--grid
on|off` say whether those show at the start; `--relief FACTOR` and
`--ripples FACTOR` scale the floor's elevation and its ripples' height,
1 as designed, 0 none; `--waves DEGREES` turns the waves the ripples lie
across; `--tile FILE` writes the ripples' tile as baked, a PPM image of
its height and slopes (and its cavity, to a `-cavity` file beside it),
for looking at the bake. How fast it draws, and where the camera is, are
in the bottom right.

The camera is driven as a modelling program's viewport, with no modes: two
fingers on a trackpad (or the wheel) orbit the point it looks at; with
Shift, pan; with Ctrl (or a pinch, in a browser), dolly in and out; with
Alt, turn in place. The main mouse button, dragged, does the same four.
W, A, S, D (or the arrows) move the camera, Q and E down and up, and Shift
hurries. Home puts the camera back where it started. 1 shows the
wireframe, or hides it, and 2 the grid; `[` and `]` halve and double the
detail, how finely every mesh is made, for the hardware at hand.

[elan]: https://github.com/leanprover/elan
[Nix]: https://nixos.org

For the web, you need the [Emscripten SDK][emsdk] at the version the
bindings name (`.lake/packages/WebGPURaw/web/emscripten-version`), with
`cmake` and `make`. Then:

    .lake/packages/WebGPURaw/web/build.sh \
      --app Reef --page web/index.html --out .lake/web/site
    node .lake/packages/WebGPURaw/web/serve.mjs .lake/web/site

and open http://localhost:8000/. The first web build takes a few minutes:
it builds Lean's runtime for WebAssembly, which Lean does not support (the
bindings' [web/README.md][web-readme] says more).

[emsdk]: https://emscripten.org/docs/getting_started/downloads.html
[web-readme]: https://github.com/lancelet/webgpu-raw-lean/blob/main/web/README.md

## Depending on the bindings

This is all a package needs to use them. In `lakefile.lean`:

```lean
require WebGPURaw from git
  "https://github.com/lancelet/webgpu-raw-lean" @ "main"
```

with the bindings' Lean version in `lean-toolchain`. Then:

- **Natively**, `lake build` builds everything: it fetches wgpu-native, and
  SDL3 for the window library, and copies their shared libraries beside the
  program, which finds them there. Nothing else is needed to run it.
- **On the web**, the bindings' `web/build.sh`, run from the package's root,
  builds the modules under one root (here `Reef`: `Reef.lean` and
  `Reef/**.lean`, one of which has `main`) with the bindings, into the page's
  directory.

A program for both runs each step in the callback of the one before, and its
frames from `WebGPU.Window.run`, as a browser requires (see `Reef/Gpu.lean`
and `Reef/Main.lean`, and the bindings' web/README.md).

## Layout

- `Reef/Platform.lean`: the options, and the window.
- `Reef/Gpu.lean`: requesting a device; buffers and shader modules.
- `Reef/Math.lean`: vectors, and the camera's matrices.
- `Reef/Camera.lean`: the camera, orbited, moved and turned.
- `Reef/App.lean`: the state, and the pure functions that change it, on an
  event and once a frame. What they cannot do themselves they ask the
  program for.
- `Reef/Floor.lean`: the floor's mesh, a quadtree of one patch, its nodes
  chosen each frame by their distance from the eye, morphing between
  levels.
- `Reef/Ripples.lean`: the sand's ripples, one tile of them baked at the
  start from phasor noise, with its mip levels.
- `Reef/Render.lean`: the pipelines, and drawing a frame; the wireframe,
  which any mesh gets.
- `Reef/Overlay.lean`: text over the frame, drawn as pixels.
- `Reef/Stats.lean`: how fast it draws, for the overlay.
- `Reef/Main.lean`: the program: the shell around the state.
- `shaders/`: the WGSL. The build writes it into `Reef/Shaders.lean`, so
  it is embedded in the program, and an edited shader is built in. That file
  is committed too, as `lake build Reef` (which the web build runs) looks
  for it before writing it; CI checks it is current.
- `fonts/`: the overlay's font, JetBrains Mono (under the SIL Open Font
  License, `fonts/OFL.txt`), which the build writes into `Reef/Fonts.lean`,
  in base64, committed likewise.
- `web/index.html`: the page.

## License

Licensed under either of

- the Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE)), or
- the MIT license ([LICENSE-MIT](LICENSE-MIT)),

at your option. Unless you say otherwise, a contribution you submit for
inclusion is licensed as above, with no further terms. [NOTICE](NOTICE)
lists the third-party components the build fetches or links.
