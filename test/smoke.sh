#!/bin/bash
# Headless GUI smoke test for a ghostty .deb. Run it inside a container of
# the distro the package was built for, e.g. from the repo root:
#
#   docker run --rm -v "$PWD/build:/b:ro" -v "$PWD/test:/t:ro" \
#     -v "$PWD/build/smoke:/out" ubuntu:24.04 \
#     bash /t/smoke.sh /b/ghostty_1.4.0-1~noble_amd64.deb
#
# Installs the package, starts ghostty under Xvfb with software OpenGL,
# drives tabs, splits, the command palette, the quit dialog and the
# inspector with xdotool, and writes screenshots and the ghostty log to
# /out. Fails if ghostty exits early, logs any GTK/GLib criticals, or GTK
# can't parse Ghostty's own CSS.
set -u
DEB="${1:?usage: smoke.sh /path/to/ghostty.deb}"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq >/dev/null
apt-get install -y -qq "$DEB" xvfb xdotool imagemagick dbus \
  libgl1-mesa-dri libegl-mesa0 >/dev/null 2>&1 \
  || { echo "FAIL: could not install $DEB"; exit 1; }

# Broken custom CSS exercises the CSS error logging path, which
# patches/noble/01-gtk-4.14-build.patch modifies. Its errors are all on
# line 1, which the CSS check below skips. window-theme = ghostty turns on
# the extra runtime CSS that patches/noble/02-gtk-4.14-css.patch rewrites.
mkdir -p /root/.config/ghostty /out
printf 'gtk-custom-css = /root/broken.css\nwindow-theme = ghostty\n' \
  > /root/.config/ghostty/config
printf 'window { background: ;;; nonsense-prop: 12px }\n' > /root/broken.css

Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
export DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 GHOSTTY_LOG=stderr
sleep 2

shot() { import -window root "/out/$1.png" 2>/dev/null; }

dbus-run-session -- ghostty > /out/ghostty.log 2>&1 &
sleep 6
shot 1-startup
xdotool key ctrl+shift+t; sleep 1
xdotool key ctrl+shift+o; sleep 1
xdotool key ctrl+shift+e; sleep 1
xdotool type --delay 20 'echo hello from $(ghostty --version | head -1)'
xdotool key Return; sleep 1
shot 2-tabs-splits
xdotool key ctrl+shift+p; sleep 1
shot 3-command-palette
xdotool key Escape; sleep 1
xdotool type --delay 20 'sleep 300'; xdotool key Return; sleep 1
xdotool key ctrl+shift+q; sleep 2
shot 4-quit-confirm
xdotool key Escape; sleep 1
xdotool key ctrl+shift+i; sleep 2
shot 5-inspector

RUNNING="$(pgrep -c -x ghostty || true)"
pkill -x ghostty; sleep 1
chmod -R a+rw /out

grep -E 'GTK version|libadwaita version' /out/ghostty.log
echo "=== warnings (deduplicated)"
grep -E '^(warning|error)|WARNING|CRITICAL' /out/ghostty.log \
  | sed -E 's/[0-9]{4,}/N/g' | sort | uniq -c | sort -rn

CRITICALS="$(grep -c -E 'CRITICAL|critical\(' /out/ghostty.log || true)"
# style.css is Ghostty's bundled stylesheet; <data> past line 1 is its
# runtime CSS.
CSS_ERRORS="$(grep -E 'Theme parser error|css parsing failed' /out/ghostty.log \
  | grep -c -v '<data>:1:' || true)"
if [ "$RUNNING" = "0" ]; then
  echo "FAIL: ghostty exited before the test finished"; exit 1
fi
if [ "$CRITICALS" != "0" ]; then
  echo "FAIL: $CRITICALS GTK/GLib criticals in log"; exit 1
fi
if [ "$CSS_ERRORS" != "0" ]; then
  echo "FAIL: $CSS_ERRORS errors parsing Ghostty's CSS"; exit 1
fi
echo "PASS"
