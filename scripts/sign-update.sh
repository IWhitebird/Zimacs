#!/bin/sh
# Signs a release binary so installed copies of Zimacs will accept it as an
# update. Run by the release workflow, with the Ed25519 private key in PEM
# form in ZIMACS_SIGNING_KEY.
#
#   sh scripts/sign-update.sh BINARY ASSET PLATFORM VERSION
#
# Writes ASSET, a copy of BINARY, and ASSET.sig. What gets signed is the
# binary followed by "\nzimacs-update:VERSION:PLATFORM", byte for byte what
# signedSuffix in src/core/selfupdate.zig expects.
set -eu

[ $# -eq 4 ] || {
  printf 'usage: %s BINARY ASSET PLATFORM VERSION\n' "$0" >&2
  exit 2
}
binary=$1
asset=$2
platform=$3
version=$4
root=$(cd "$(dirname "$0")/.." && pwd)

[ -n "${ZIMACS_SIGNING_KEY:-}" ] || {
  printf 'error: ZIMACS_SIGNING_KEY is not set\n' >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
printf '%s\n' "$ZIMACS_SIGNING_KEY" >"$work/key.pem"

# The key has to be the partner of the one compiled into Zimacs, or every
# installed copy would turn this release away.
expected=$(sed -n 's/^pub const public_key_hex = "\([0-9a-f]*\)";$/\1/p' "$root/src/core/selfupdate.zig")
actual=$(openssl pkey -in "$work/key.pem" -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d ' \n')
if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
  printf 'error: the signing key does not match the public key in selfupdate.zig\n' >&2
  exit 1
fi

cp "$binary" "$asset"
{
  cat "$binary"
  printf '\nzimacs-update:%s:%s' "$version" "$platform"
} >"$work/payload"
openssl pkeyutl -sign -rawin -inkey "$work/key.pem" -in "$work/payload" -out "$asset.sig"

# Checked before anything is uploaded.
openssl pkey -in "$work/key.pem" -pubout -out "$work/public.pem"
openssl pkeyutl -verify -pubin -inkey "$work/public.pem" -rawin \
  -in "$work/payload" -sigfile "$asset.sig" >/dev/null

printf 'signed %s for %s %s\n' "$asset" "$platform" "$version"
