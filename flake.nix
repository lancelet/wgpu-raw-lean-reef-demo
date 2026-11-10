{
  # Development tools only, as the bindings' flake is: nothing in the build
  # depends on Nix. The Lean toolchain is the one `lean-toolchain` names,
  # which elan installs whether or not elan comes from Nix.
  #
  # The shell's `cc` is what compiles the bindings' C and builds SDL3. On
  # macOS it is clang, which SDL3 needs (its Objective-C); a `cc` that is
  # GCC, as a Nix profile may put first on PATH, cannot build it. On Linux
  # it is gcc, and the shell adds the window systems' libraries SDL3 builds
  # against and loads when it runs, and Vulkan's loader for wgpu-native.
  #
  # On NixOS, elan patches each toolchain it installs to call this shell's
  # bash and cc by store path. Keep the shell GC-rooted (nix-direnv does
  # this), and after `nix flake update` reinstall toolchains with
  # `elan toolchain uninstall <ver>`, or they break once old paths are
  # collected.
  description = "wgpu-raw-lean-reef-demo development shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          # What SDL3 builds against on Linux, and loads by name when it runs;
          # and Vulkan's loader, which wgpu-native loads the same way.
          linuxLibraries = with pkgs; [
            xorg.libX11
            xorg.libXext
            xorg.libXrandr
            xorg.libXcursor
            xorg.libXfixes
            xorg.libXi
            xorg.libXScrnSaver
            xorg.libXtst
            libxkbcommon
            wayland
            libglvnd
            libdrm
            mesa
            vulkan-loader
          ];
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.elan # installs the Lean toolchain named in lean-toolchain
              pkgs.curl # the bindings' vendor/*/fetch.sh
              pkgs.unzip # the bindings' vendor/wgpu-native/fetch.sh
              pkgs.cmake # builds SDL3
              # the web build (the bindings' web/build.sh); CI uses the
              # Emscripten SDK at the version the bindings name, which this
              # should match
              pkgs.emscripten
              pkgs.gnumake
              pkgs.nodejs
              pkgs.git
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux ([ pkgs.pkg-config ] ++ linuxLibraries);

            # So that SDL3 and wgpu-native find those libraries when the
            # program runs (they load them by name, not by store path).
            LD_LIBRARY_PATH = pkgs.lib.optionalString pkgs.stdenv.isLinux (
              pkgs.lib.makeLibraryPath linuxLibraries
            );
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
