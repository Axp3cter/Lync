#!/bin/sh
# Times every call-site form of gen.py in three scenarios. Usage: sh bench.sh HOST GENDIR [CPU] > bench.out
# client: everything interpreted (Roblox clients have no native code).
# server: runtime and shard native (a --!native shard), game script as on a Roblox server (only @native functions).
# native: every chunk native (upper bound).
H=$1; G=$2; CPU=${3:-3}
for f in "$G"/bench_*.luau "$G"/dec_move6_*.luau; do
  for sc in client server native; do
    case $sc in
      client) m=interp; s=interp ;;
      server) m=native; s=roblox ;;
      native) m=native; s=native ;;
    esac
    case $f in
      */dec_*) mods="Dec=$G/dec_shard.luau:$m" ;;
      *) mods="RT=$G/rt.luau:$m Net=$G/shard.luau:$m" ;;
    esac
    printf '{"scenario":"%s",' "$sc"
    taskset -c "$CPU" "$H" run $mods "$f:$s" | sed 's/^{//'
  done
done
