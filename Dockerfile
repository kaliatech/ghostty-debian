# syntax=docker/dockerfile:1

# Copyright 2026 Mark Mandel
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Builds a release .deb package of Ghostty (https://ghostty.org) for Debian
# stable, Debian testing or Ubuntu 24.04. Follows the official build
# instructions at https://ghostty.org/docs/install/build
#
# Usage:
#   DOCKER_BUILDKIT=1 docker build --output=build .
#   sudo apt install ./build/ghostty_*.deb
#
# Build against a different distro, and/or bump the package revision for a
# rebuild-only release:
#   DOCKER_BUILDKIT=1 docker build --output=build \
#     --build-arg BASE_IMAGE=ubuntu:24.04 \
#     --build-arg PKG_REVISION=2 \
#     .

ARG GHOSTTY_VERSION=1.4.0
# Must match the Zig version required by GHOSTTY_VERSION, per
# https://ghostty.org/docs/install/build (or minimum_zig_version in the
# release's build.zig.zon; major.minor must match exactly).
ARG ZIG_VERSION=0.17.0
ARG MAINTAINER="Josh Sanderson <josh@jgstechnical.com>"
# Distro image to build against: debian:stable, debian:testing or
# ubuntu:24.04. The package only runs on the distro it was built on.
ARG BASE_IMAGE=debian:testing
# Debian package revision. Bump this (and reset it to 1 whenever
# GHOSTTY_VERSION changes) to force a new release without a new upstream
# Ghostty version, e.g. after a dependency-only rebuild.
ARG PKG_REVISION=1

FROM ${BASE_IMAGE} AS builder
ARG GHOSTTY_VERSION
ARG ZIG_VERSION
ARG MAINTAINER
ARG PKG_REVISION

# gtk4-layer-shell isn't packaged on Ubuntu 24.04. When it's missing,
# Ghostty builds it from source instead (see the zig build step).
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    ca-certificates \
    xz-utils \
    pkg-config \
    libgtk-4-dev \
    libadwaita-1-dev \
    libglib2.0-bin \
    gettext \
    libxml2-utils \
    dpkg-dev \
    patchelf \
    && if apt-cache show libgtk4-layer-shell-dev >/dev/null 2>&1; then \
         apt-get install -y --no-install-recommends libgtk4-layer-shell-dev; \
       fi \
    && rm -rf /var/lib/apt/lists/*

# Install the exact Zig version Ghostty requires (static binary release).
RUN ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in \
         amd64) ZIG_ARCH=x86_64 ;; \
         arm64) ZIG_ARCH=aarch64 ;; \
         *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/zig.tar.xz \
         "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

# Fetch the release source tarball (git clones are discouraged upstream).
RUN mkdir -p /src \
    && curl -fsSL -o /tmp/ghostty.tar.gz \
         "https://release.files.ghostty.org/${GHOSTTY_VERSION}/ghostty-${GHOSTTY_VERSION}.tar.gz" \
    && tar -xzf /tmp/ghostty.tar.gz -C /src \
    && rm /tmp/ghostty.tar.gz

WORKDIR /src/ghostty-${GHOSTTY_VERSION}

# Apply distro-specific patches from patches/<codename>/, if any. See
# patches/noble/ for why Ubuntu 24.04 needs them. The tarball ships the
# stylesheet precompiled into a GResource bundle, so a patch to it also
# needs the bundle repacked (see patches/repack-gresource.sh).
COPY patches/ /patches/
RUN set -eu; \
    CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"; \
    REPACK=0; \
    for p in /patches/"${CODENAME}"/*.patch; do \
      [ -e "$p" ] || continue; \
      echo "applying $p"; \
      patch -p1 --forward < "$p"; \
      if grep -q '^+++ b/src/apprt/gtk/css/' "$p"; then REPACK=1; fi; \
    done; \
    if [ "$REPACK" = 1 ]; then sh /patches/repack-gresource.sh; fi

# Build and install into a staging root, following upstream's PACKAGING.md:
# --prefix /usr plus DESTDIR so no staging paths leak into installed files,
# and -Dcpu=baseline so the binary runs on CPUs older than the build host's.
# -Dversion-string is needed because without a git checkout the build
# otherwise reports itself as "<version>-dev+0000000" on the tip channel.
#
# Without a system gtk4-layer-shell, -fno-sys builds it from source as a
# shared library. It gets moved to /usr/lib/ghostty below, and
# -Dpatch-rpath points the binary there (it would otherwise keep a relative
# .zig-cache/... RUNPATH from the build tree).
RUN set -eu; \
    LAYER_SHELL_FLAGS=""; \
    if ! pkg-config --exists gtk4-layer-shell-0; then \
      LAYER_SHELL_FLAGS="-fno-sys=gtk4-layer-shell -Dpatch-rpath=/usr/lib/ghostty"; \
    fi; \
    echo "gtk4-layer-shell flags: ${LAYER_SHELL_FLAGS:-<system package>}"; \
    DESTDIR="/pkg/ghostty-${GHOSTTY_VERSION}" zig build \
      --prefix /usr \
      -Doptimize=ReleaseFast \
      -Dcpu=baseline \
      -Dversion-string="${GHOSTTY_VERSION}" \
      ${LAYER_SHELL_FLAGS}

# Since 1.4.0 the build also installs libghostty-vt (headers, shared and
# static libs, pkg-config files). The ghostty binary doesn't link against
# it, so leave it out of this package, along with any other headers (a
# from-source gtk4-layer-shell installs its own). The from-source
# gtk4-layer-shell library is kept, but as a private library rather than in
# the public /usr/lib.
RUN set -eu; \
    cd "/pkg/ghostty-${GHOSTTY_VERSION}/usr"; \
    rm -f lib/libghostty-vt.* share/pkgconfig/libghostty-vt*.pc; \
    rm -rf include; \
    if [ -e lib/libgtk4-layer-shell.so ]; then \
      mkdir -p lib/ghostty; \
      mv lib/libgtk4-layer-shell.so lib/ghostty/; \
    fi; \
    rmdir --ignore-fail-on-non-empty lib share/pkgconfig

# Assemble the .deb control metadata and build the package.
RUN set -eu; \
    PKGROOT="/pkg/ghostty-${GHOSTTY_VERSION}"; \
    ARCH="$(dpkg --print-architecture)"; \
    DISTRO="$(. /etc/os-release && echo "${NAME}")"; \
    CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"; \
    PKG_VERSION="${GHOSTTY_VERSION}-${PKG_REVISION}~${CODENAME}"; \
    mkdir -p "${PKGROOT}/DEBIAN"; \
    rm -f "${PKGROOT}/usr/share/terminfo/g/ghostty"; \
    mkdir -p /tmp/shlibs/debian; \
    printf 'Source: ghostty\nPackage: ghostty\nArchitecture: %s\n' "${ARCH}" \
      > /tmp/shlibs/debian/control; \
    DEPENDS="$(cd /tmp/shlibs && dpkg-shlibdeps -O "${PKGROOT}/usr/bin/ghostty" \
      | sed -n 's/^shlibs:Depends=//p')"; \
    { \
      echo "Package: ghostty"; \
      echo "Version: ${PKG_VERSION}"; \
      echo "Section: utils"; \
      echo "Priority: optional"; \
      echo "Architecture: ${ARCH}"; \
      echo "Maintainer: ${MAINTAINER}"; \
      echo "Depends: ${DEPENDS}"; \
      echo "Recommends: ncurses-term"; \
      echo "Homepage: https://ghostty.org"; \
      echo "Vcs-Browser: https://github.com/kaliatech/ghostty-debian"; \
      echo "Vcs-Git: https://github.com/kaliatech/ghostty-debian.git"; \
      echo "Description: Fast, native, GPU-accelerated terminal emulator"; \
      echo " Ghostty is a terminal emulator that differentiates itself from other"; \
      echo " terminal emulators in a few key ways: fast, feature-rich, and native."; \
      echo " This build was compiled from the official release source tarball"; \
      echo " (ReleaseFast) and packaged for ${DISTRO} ${CODENAME}."; \
    } > "${PKGROOT}/DEBIAN/control"; \
    mkdir -p /out; \
    dpkg-deb --build --root-owner-group "${PKGROOT}" \
      "/out/ghostty_${PKG_VERSION}_${ARCH}.deb"

FROM scratch AS export
COPY --from=builder /out/*.deb /
