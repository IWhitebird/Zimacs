#!/usr/bin/env bash
# Fails if a binary holds any VEX-encoded (AVX) instruction, which would
# die with SIGILL on older processors.
#
# Safety-checked builds put an 8-byte function type tag, 0xc105cafe and a
# hash, before each C function. objdump decodes it as code, and a hash that
# ends in a VEX prefix then reads as an AVX instruction, so the instruction
# after each tag is skipped.
set -euo pipefail

binary=${1:?usage: check-baseline.sh BINARY}

count=$(objdump -d "$binary" | awk -F'\t' '
  NF < 3 { next }
  {
    bytes = $2
    gsub(/ +$/, "", bytes)
    if (state == 2) { state = 0; next }
    if (bytes == "fe ca") { state = 1 }
    else if (state == 1 && bytes ~ /^05 /) { state = 2 }
    else { state = 0 }
    if ($3 ~ /^v[a-z]/) { n++; print "  " $1 " " $3 > "/dev/stderr" }
  }
  END { print n + 0 }
')

echo "VEX-encoded instructions: $count"
test "$count" -eq 0
