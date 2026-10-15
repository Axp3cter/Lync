#!/bin/sh
# Times every call-site form of gen.py in three scenarios. Usage: sh bench.sh HOST GENDIR > bench.out
# client: everything interpreted (Roblox clients have no native code).
# server: runtime and shard native (a --!native shard), game script as on a Roblox server (only @native functions).
# native: every chunk native (upper bound).
H=$1; G=$2
for f in "$G"/bench_*.luau; do
  for sc in client server native; do
    case $sc in
      client) m=interp; s=interp ;;
      server) m=native; s=roblox ;;
      native) m=native; s=native ;;
    esac
    printf '{"scenario":"%s",' "$sc"
    "$H" run RT="$G/rt.luau:$m" Net="$G/shard.luau:$m" "$f:$s" | sed 's/^{//'
  done
done
