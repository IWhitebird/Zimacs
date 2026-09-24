#!/bin/sh
# Builds the web version and drops it into the site, so the page can run the
# real editor instead of showing a picture of one.
#
#   sh scripts/build-demo.sh
#
# The output is committed, since the site is deployed straight from the
# repository. Run this again whenever the editor changes.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/www/public/demo"

command -v zig >/dev/null 2>&1 || {
  printf 'error: zig is not on your PATH\n' >&2
  exit 1
}

printf 'Building the web target, this takes a few minutes the first time\n'
(cd "$root" && zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall)

[ -f "$root/zig-out/web/Zimacs.html" ] || {
  printf 'error: the build produced no zig-out/web/Zimacs.html\n' >&2
  exit 1
}

rm -rf "$out"
mkdir -p "$out"
# Not the .map: it is 3.5 MB of sourcemap nobody visiting the site needs.
cp "$root/zig-out/web/Zimacs.html" "$out/"
cp "$root/zig-out/web/Zimacs.js" "$out/"
cp "$root/zig-out/web/Zimacs.wasm" "$out/"

printf '\nDemo ready in www/public/demo\n'
ls -la "$out"
printf '\nNow run:  cd www && npm run build\n'
