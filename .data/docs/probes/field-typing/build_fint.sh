#!/bin/sh
# Builds luau-analyze-fint from .data/projects/luau (out of tree). Usage: build_fint.sh BUILD_DIR
# BUILD_DIR must hold a Release ninja build of target Luau.Analyze.CLI:
#   cmake -G Ninja -DCMAKE_BUILD_TYPE=Release .data/projects/luau && ninja Luau.Analyze.CLI
set -e
B=$1; P=$(cd "$(dirname "$0")" && pwd); L=$(cd "$P/../../../projects/luau" && pwd)
I="-I$L/Analysis/include -I$L/Ast/include -I$L/Common/include -I$L/Config/include -I$L/CLI/include -I$L/Require/include -I$L/VM/include"
c++ -O3 -DNDEBUG $I -Dmain=analyze_main -c "$L/CLI/src/Analyze.cpp" -o "$B/Analyze_renamed.o"
c++ -O3 -DNDEBUG $I -c "$P/fint_main.cpp" -o "$B/fint_main.o"
cd "$B"
c++ -O3 fint_main.o Analyze_renamed.o CMakeFiles/Luau.Analyze.CLI.dir/CLI/src/AnalyzeRequirer.cpp.o -o luau-analyze-fint \
	libLuau.Analysis.a libLuau.CLI.lib.a libLuau.Require.a -lpthread libLuau.Config.a libLuau.Compiler.a libLuau.Ast.a \
	libLuau.Bytecode.a libLuau.VM.a libLuau.Common.a
echo "$B/luau-analyze-fint"
