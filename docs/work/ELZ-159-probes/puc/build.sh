#!/bin/sh
set -eu
cd "$(dirname "$0")"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '%s\n' 'Copy the probes outside the checkout before building.' >&2
  exit 1
fi
version=5.4.9
sha=2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6
archive="lua-$version.tar.gz"
if [ ! -f "$archive" ]; then
  curl -fL "${LUA_URL:-https://www.lua.org/ftp/$archive}" -o "$archive"
fi
printf '%s  %s\n' "$sha" "$archive" | sha256sum -c -
tar -xzf "$archive"
flags='-O2 -DLUA_USE_LINUX'
output=host
if [ "${LUA_FIXED_SEED:-0}" = 1 ]; then
  flags="$flags -D'luai_makeseed(L)=0'"
  output=host-fixed-seed
fi
make -C "lua-$version/src" clean
make -C "lua-$version/src" liblua.a MYCFLAGS="$flags"
cc -O2 -Wall -Wextra -Werror -I"lua-$version/src" host.c "lua-$version/src/liblua.a" -lm -ldl -o "$output"
