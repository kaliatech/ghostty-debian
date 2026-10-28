#!/bin/sh
# Rebuilds the prebuilt GResource bundle in a Ghostty release tarball so it
# uses the current src/apprt/gtk/css/style.css. Run from the source root
# after patching style.css.
#
# Release tarballs ship src/apprt/gtk/ghostty_resources.c, generated from
# style.css, the icons and the compiled blueprints, and the build uses it
# in place of those sources. Patching style.css alone changes nothing.
# Generating the bundle from scratch needs blueprint-compiler 0.20, which
# Ubuntu 24.04 doesn't have, so this unpacks the shipped bundle, swaps in
# the stylesheet and packs it again.
set -eu
RES=src/apprt/gtk/ghostty_resources.c
PREFIX=/com/mitchellh/ghostty
WORK="$(mktemp -d)"

# gresource reads bundles from ELF sections, so compile the C file first.
cc -c $(pkg-config --cflags gio-2.0) "$RES" -o "$WORK/res.o"
gresource list "$WORK/res.o" | grep -qx "$PREFIX/style.css"

mkdir "$WORK/root"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<gresources>'
  echo "  <gresource prefix=\"$PREFIX\">"
  for path in $(gresource list "$WORK/res.o"); do
    rel="${path#"$PREFIX"/}"
    mkdir -p "$WORK/root/$(dirname "$rel")"
    gresource extract "$WORK/res.o" "$path" > "$WORK/root/$rel"
    echo "    <file>$rel</file>"
  done
  echo '  </gresource>'
  echo '</gresources>'
} > "$WORK/resources.xml"

cp src/apprt/gtk/css/style.css "$WORK/root/style.css"
glib-compile-resources --sourcedir "$WORK/root" --c-name ghostty \
  --generate-source --target "$RES" "$WORK/resources.xml"
rm -rf "$WORK"
echo "repacked $RES with patched style.css"
