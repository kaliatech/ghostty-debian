# ghostty-debian

> ⚠️ **Warning**: I'm still testing this out for my own usage, but so far so good.
> In the long term would like to expand this to Debian stable, testing and experimental - but first time building out this kind of packaging infra, so taking things step by step and dogfooding my own tools in the process.

Builds a release `.deb` package of [Ghostty](https://ghostty.org) for Debian
stable, Debian testing and Ubuntu 24.04, using Docker so you don't need Zig or
Ghostty's build dependencies installed on your own machine. Ghostty isn't
packaged in Debian or Ubuntu, so this compiles it from the official release
source tarball following the
[upstream build instructions](https://ghostty.org/docs/install/build).

## Prerequisites

- Docker with BuildKit (Docker 23+ has this by default).

## Usage

```sh
DOCKER_BUILDKIT=1 docker build --output=build .
```

This produces `build/ghostty_<version>_<arch>.deb`, built against Debian
testing by default. Install it with:

```sh
sudo apt install ./build/ghostty_*.deb
```

To build for a different distro, set `BASE_IMAGE`:

```sh
DOCKER_BUILDKIT=1 docker build --output=build --build-arg BASE_IMAGE=debian:stable .
DOCKER_BUILDKIT=1 docker build --output=build --build-arg BASE_IMAGE=ubuntu:24.04 .
```

Each package only installs on the distro it was built against.

## How it works

The `Dockerfile` is a multi-stage build:

1. **`builder`** (`${BASE_IMAGE}`, `debian:testing` by default) installs
   Ghostty's build dependencies (`libgtk-4-dev`, `libgtk4-layer-shell-dev`
   where the distro has it, `libadwaita-1-dev`, `gettext`, `libxml2-utils`),
   downloads the pinned Zig compiler release, downloads and extracts the
   Ghostty source tarball, applies any patches in `patches/<codename>/`, and
   runs `zig build --prefix /usr -Doptimize=ReleaseFast -Dcpu=baseline`
   with `DESTDIR` set to a staging root, as upstream's `PACKAGING.md`
   describes. `-Dversion-string` is also passed, since without a git
   checkout Ghostty reports itself as a `-dev` build. The libghostty-vt
   library that the build also installs (since 1.4.0) is removed, since the
   `ghostty` binary doesn't link against it. It then
   assembles a Debian control file — with `Depends` computed via
   `dpkg-shlibdeps` against the built binary, so it tracks whatever library
   versions that specific distro actually ships — and packages everything
   with `dpkg-deb`. Building each distro separately (rather than one
   build "for all") matters: each `.deb`'s minimum library versions are only
   correct for the distro it was actually linked against.
2. **`export`** (`scratch`) just holds the resulting `.deb`. Because it's the
   final stage, `docker build --output=build .` copies it straight into
   `./build/` on the host — no `docker run` or volume mount required.

## Ubuntu 24.04

Ghostty 1.4.0 requires GTK 4.18 and libadwaita 1.7. Ubuntu 24.04 ships GTK
4.14 and libadwaita 1.5, so the 24.04 build needs three adjustments.
Upstream doesn't support this configuration. Each patch header has the
details.

**`patches/noble/01-gtk-4.14-build.patch`** lowers Ghostty's minimum
versions to what 24.04 ships. 1.4.0 uses only one function newer than GTK
4.14 (`gtk_css_section_get_bytes`, used to add detail to a CSS error log
message), and the patch removes that call.

**`patches/noble/02-gtk-4.14-css.patch`** rewrites Ghostty's CSS in syntax
GTK 4.14 can parse. Ghostty 1.4.0 uses `color-mix()` and `var(--…)`
custom properties from GTK 4.16 and libadwaita 1.6. Without this patch,
GTK drops those rules and a few elements lose their colors (the
child-exited banner, bell overlay, split divider, drag-to-split drop
zones, and the `window-theme = ghostty` headerbar). The patch uses
libadwaita 1.5's named colors instead:

```css
/* Ghostty 1.4.0 */
background-color: color-mix(in srgb, var(--accent-color), transparent 50%);
/* patched */
background-color: alpha(@accent_color, 0.5);
```

Release tarballs ship `style.css` precompiled into a GResource bundle
(`src/apprt/gtk/ghostty_resources.c`, alongside the compiled blueprints
and icons), and the build uses that bundle in place of the source files.
Rebuilding it from source needs blueprint-compiler 0.20, which 24.04
doesn't have. When a patch touches `src/apprt/gtk/css/`, the Dockerfile
runs `patches/repack-gresource.sh`, which unpacks the shipped bundle,
swaps in the patched `style.css`, and packs it again.

**gtk4-layer-shell** isn't packaged for 24.04. When `pkg-config` can't find
it, the build passes `-fno-sys=gtk4-layer-shell` so Ghostty builds it from
source, ships the resulting library privately in `/usr/lib/ghostty/`, and
sets the binary's RUNPATH to that directory with `-Dpatch-rpath`.

When bumping `GHOSTTY_VERSION`, the patches can fail in three ways:

- `patch` doesn't apply: the patched lines changed upstream. Regenerate the
  patch against the new source.
- The link step fails with `undefined symbol: gtk_…` or `adw_…`: the new
  release calls another function newer than 24.04's libraries. Check
  whether the call can be removed or guarded, and add it to
  `01-gtk-4.14-build.patch`.
- The smoke test fails with "errors parsing Ghostty's CSS": the new release
  added CSS that GTK 4.14 can't parse. The smoke log shows the file and
  line. Rewrite it in `02-gtk-4.14-css.patch`.

## Testing

`test/smoke.sh` runs a headless GUI smoke test of a built package inside a
container of the matching distro. It installs the `.deb`, starts Ghostty
under Xvfb with software OpenGL, drives tabs, splits, the command palette,
the quit dialog and the inspector with `xdotool`, and saves screenshots and
Ghostty's log. It fails if Ghostty exits early, logs GTK/GLib criticals, or
GTK can't parse Ghostty's own CSS.

```sh
docker run --rm -v "$PWD/build:/b:ro" -v "$PWD/test:/t:ro" \
  -v "$PWD/build/smoke:/out" ubuntu:24.04 \
  bash /t/smoke.sh /b/ghostty_1.4.0-1~noble_amd64.deb
```

## Versioning

Package versions look like `1.4.0-1~trixie` / `1.4.0-1~forky` / `1.4.0-1~noble`:

- `1.4.0` is the upstream Ghostty version (`GHOSTTY_VERSION`).
- `1` is the Debian package revision (`PKG_REVISION`) — bump this (and reset
  it to `1` whenever `GHOSTTY_VERSION` changes) to force a new release
  without a new upstream Ghostty version, e.g. after a dependency-only
  rebuild.
- `~trixie`/`~forky`/`~noble` is the actual distro codename the package was
  built against (read from `/etc/os-release` inside the build, not
  hardcoded) — the same tilde-suffix convention used by Debian backports and
  Ubuntu PPAs for suite-specific builds of one upstream version.

## Bumping versions

The Ghostty and Zig versions are build args at the top of the `Dockerfile`:

```dockerfile
ARG GHOSTTY_VERSION=1.4.0
ARG ZIG_VERSION=0.17.0
```

Ghostty pins a specific Zig version per release (see the
[build docs](https://ghostty.org/docs/install/build) for the current
mapping) — when bumping `GHOSTTY_VERSION`, check whether `ZIG_VERSION` needs
to change too, or the build will fail. The Ubuntu 24.04 patch may also need
updating (see [Ubuntu 24.04](#ubuntu-2404)). You can also override any of
the build args at build time without editing the file:

```sh
DOCKER_BUILDKIT=1 docker build --output=build \
  --build-arg GHOSTTY_VERSION=1.4.0 \
  --build-arg ZIG_VERSION=0.17.0 \
  --build-arg BASE_IMAGE=debian:stable \
  --build-arg PKG_REVISION=2 \
  .
```

## GitHub Actions

Two workflows live in `.github/workflows/`:

- **`build-release.yml`** — manually triggered (Actions tab, or
  `gh workflow run build-release.yml -f ghostty_version=1.4.0 -f pkg_revision=1`).
  Builds the `.deb` for Debian stable, Debian testing and Ubuntu 24.04 in
  parallel, runs `test/smoke.sh` against each, then creates (or updates, if
  re-run for the same version/revision) a GitHub Release tagged
  `v<ghostty_version>-<pkg_revision>` with the `.deb` files attached. Smoke
  test screenshots and logs are uploaded as `smoke-*` workflow artifacts.
- **`check-ghostty-version.yml`** — runs weekly (and can be triggered
  manually). Compares the latest `ghostty-org/ghostty` release to the
  version pinned in `Dockerfile` and files a tracking issue if they differ.
  It never bumps versions or builds anything itself — bumping also means
  checking whether `ZIG_VERSION` needs to change, which needs a human to
  check the build docs.
