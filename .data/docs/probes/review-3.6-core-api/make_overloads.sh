#!/bin/sh
# Generates the overload-count probes. Usage: make_overloads.sh (writes into this directory)
cd "$(dirname "$0")"
gen_view() { # $1 = overload count; writes the H and View aliases
	n=$1
	echo 'export type H<T> = { derive: (self: H<T>, options: { fn: () -> T?, policy: "drop" | "deliver" }) -> () }'
	printf 'export type View = { field: '
	i=1; while [ $i -le $n ]; do
		[ $i -gt 1 ] && printf ' & '
		case $((i % 3)) in 0) T=number;; 1) T=vector;; 2) T=string;; esac
		printf '((self: View, path: "f%d") -> H<%s>)' $i $T
		i=$((i + 1))
	done
	echo ' }'
}
for n in 8 9 32; do { echo '--!strict'; echo "-- generated-path shape: field() as $n literal overloads, in a checked module"; gen_view $n; echo 'local M: View = nil :: any'; echo 'return M'; } > overloads_$n.luau; done
# the consumer of the 32-overload shard
cat > overloads_consumer.luau <<'X'
--!strict
local Net = require("./overloads_32")
Net:field("f3"):derive({ fn = function() return 1 end, policy = "drop" })
Net:field("f1"):derive({ fn = function() return 1 end, policy = "drop" }) -- EXPECT error: f1 is vector
Net:field("nope") -- EXPECT error
X
# the fix: the alias in a --!nocheck types module, the checked shard annotates from any
{ echo '--!nocheck'; echo '-- the overload alias in the --!nocheck types module'; gen_view 32; echo 'return {}'; } > overloads_types.luau
printf -- '--!strict\nlocal T = require("./overloads_types")\nlocal M: T.View = nil :: any\nreturn M\n' > overloads_shard_fixed.luau
sed 's#"./overloads_32"#"./overloads_shard_fixed"#' overloads_consumer.luau > overloads_consumer_fixed.luau
