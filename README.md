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
ocean, with light from above, and glowing creatures drifting in it.

[bindings]: https://github.com/lancelet/webgpu-raw-lean

## Building and running

You need Lean through [elan], and a C compiler with the C library's headers
(`cc`, or the one `CC` names; on Windows, MinGW's: `CC=gcc`), `curl` and
`unzip`; on Linux and macOS, `cmake` too, to build SDL3 (on Linux, with the
X11 and Wayland headers, as [CI](.github/workflows/ci.yml) installs them).
Then:

    lake build
    lake exe reef

`reef --frames N` ends after `N` frames; `reef --headless` draws with no
display (macOS only).

[elan]: https://github.com/leanprover/elan

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
- `Reef/Scene.lean`: what is drawn, as the shaders read it.
- `Reef/Render.lean`: the pipelines, and drawing a frame.
- `Reef/Main.lean`: the program.
- `shaders/`: the WGSL. The build writes it into `Reef/Shaders.lean` (not
  committed), so it is embedded in the program, and an edited shader is
  built in.
- `web/index.html`: the page.

## License

Licensed under either of

- the Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE)), or
- the MIT license ([LICENSE-MIT](LICENSE-MIT)),

at your option. Unless you say otherwise, a contribution you submit for
inclusion is licensed as above, with no further terms. [NOTICE](NOTICE)
lists the third-party components the build fetches or links.
