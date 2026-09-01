# Changelog

All notable changes to Alien::Xmake will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- We install the latest tagged release of xmake rather than hardcoding a version.

### Added

- Alien::Xrepo::Base
- A "QUICK START EXAMPLES" section in the Alien::Xrepo docs with copy-paste examples
  for FFI::Platypus, Affix, and Affix::Wrap, getting build flags, discovering packages,
  cross-compiling, and dropping into a package environment
- Full coverage of xrepo actions in Alien::Xrepo
  - `fetch` returns parsed package info (or raw `--cflags`/`--ldflags`) without reinstalling
  - `info` supports `--depgraph` and `--format=json`
  - `scan` lists installed packages (optional lua-pattern filter)
  - `download` fetches package source archives
  - `import_pkg` / `export` handle offline package distribution
  - `list_repo` lists configured remote repositories
  - `env` sets up a package environment and runs a program (or `--show` it)
  - `search` supports `--addon`
  - `uninstall` supports `--all` and `--force`
  - `_build_args` now understands jobs, force/shallow/build, VS/NDK/SDK/MingW
    toolchain switches, and `--toolchain_host`
- Full coverage of xmake actions and plugins in Alien::Xmake
  - New constructor option `verbose` to echo commands as they run
  - Actions: `build`, `clean`, `create`, `configure`, `global`, `install`, `uninstall`,
    `package`, `pack`, `require`, `run`, `test`, `update`, `service`, `addon`
  - Plugins: `check`, `doxygen`, `format`, `lua`, `macro`, `project`, `repo`, `show`, `watch`
  - Generic escape hatch `task( $name, %options )` for tasks without a dedicated method
  - `show` strips ANSI codes, splits listings, and decodes `--format=json` into a data structure
  - The xmake `f`-style config switches are mapped to options like `plat`, `arch`, `mode`,
    `kind`, `vs`, `ndk`, `mingw`, `sdk`, `toolchain`, ... (plus a `set` hash for any `--key=value`)
  - `global` gets only the config keys xmake actually accepts there (`vs`, `ndk`, `qt`, ...)
  - Version-build accessor renamed `build()` to `buildid()` so `build` is the build action;
    the xmake `config` action is exposed as `configure()` to keep `config( $key )` as the
    install-time data accessor
- `install`, `fetch`, `scan`, `info`, `uninstall`, `download`, `import_pkg`, `export`, `env`, and
  `clean` accept `installdir`/`cachedir` options to force a project-local package store (via
  `XMAKE_PKG_INSTALLDIR` / `XMAKE_PKG_CACHEDIR`) for reproducible, isolated builds
- Document third-party package manager support (`vcpkg::`, `conan::`, `brew::`, `pacman::`, `dub::`, ...) in the
  Alien::Xrepo docs and add `eg/xrepo_features.pl`, a feature tour covering every method including
  dependency graphs (`info( ..., depgraph => 1, format => 'dot' )` for Graphviz)
- `PackageInfo` gains an `installdir` accessor (from fetch `artifacts.installdir`, else derived from the first
  libfile/include dir) and `bin_dir` falls back to `<installdir>/bin`, so tool packages (ninja, python, ...) can be
  installed and run as binaries
- `Alien::Xrepo->new( root => $dir )` becomes the default `installdir` for every store-touching method, so one
  install call can run against a project-local store; used by `Alien::Xrepo::Base` and the dist builder
- `PackageInfo` gains a `kind` accessor (`library` vs `binary`), surfaced by `print`/`dump`/`_data_printer`
- `Alien::Xrepo::Base::bin_dir()` returns an empty list (not `[undef]`) before install, keeping callers that
  interpolate `@bin_dir` from warnings
- New docs examples: an Inline::C walkthrough linking both `libpng` and `zlib` into one XS function, and installing &
  running the `ninja` binary (direct exe or shunt onto `PATH`); `eg/xrepo_inline_c.pl` (requires `Inline::C`) and
  `eg/xrepo_binary.pl` mirror them
- Alien::Xrepo POD describes binary/tool installs in NAME/SYNOPSIS/DESCRIPTION, not just FFI libraries

## [0.08] - 2026-01-11

### Changed

- Don't bother with making sure we can install a lib on CPAN smokers. I can't diagnose a system I have no access to.

## [0.07] - 2026-01-09

### Changed

- Switch xmake to plain text mode on CPAN smokers

## [0.06] - 2026-01-07

### Added

- Support system installs on Windows
- Expose xrepo
- Demos in `eg/`
  - `eg/xmake_demo.pl` creates and builds a simple shared library in C
  - `eg/xrepo_demo.pl` queries for zlib's info, installs it locally, and spews the flags required to build against it

### Changed

- Bump to Xmake 3.0.6

## [0.05] - 2024-03-18

### Fixed

- Resort to git when we fail to download snapshot with HTTP::Tiny (kinda pointless but the code was already there)

## [0.04] - 2024-03-17

### Changed

- Install v2.8.8 on platforms that build from source
- Pull tarball instead of git clone on platforms that build from source

## [0.03] - 2024-03-17

### Changed

- Install v2.8.8 on Windows

## [0.02] - 2024-03-17

### Changed

- Minor documentation changes
- Move to Test2::V0

## [0.01] - 2023-10-02

### Changed

- It exists.

[Unreleased]: https://github.com/sanko/Alien-Xmake/compare/0.08...HEAD
[0.08]: https://github.com/sanko/Alien-Xmake/compare/0.07...0.08
[0.07]: https://github.com/sanko/Alien-Xmake/compare/0.06...0.07
[0.06]: https://github.com/sanko/Alien-Xmake/compare/0.05...0.06
[0.05]: https://github.com/sanko/Alien-Xmake/compare/0.04...0.05
[0.04]: https://github.com/sanko/Alien-Xmake/compare/0.03...0.04
[0.03]: https://github.com/sanko/Alien-Xmake/compare/0.02...0.03
[0.02]: https://github.com/sanko/Alien-Xmake/compare/0.01...0.02
[0.01]: https://github.com/sanko/Alien-Xmake/releases/tag/0.01
