// Probe host for codecs-in-scripts: loads several Luau chunks into one VM, each interpreted or native,
// so a native shard can be timed against interpreted game scripts (the Roblox default for scripts without
// --!native). Also times luau_load (bytecode deserialisation) and native compilation per module.
//
// Build against a Luau build tree (see run.sh):
//   g++ -O2 -std=c++17 host.cpp -I<luau>/VM/include -I<luau>/Compiler/include -I<luau>/CodeGen/include \
//       <build>/libLuau.CodeGen.a <build>/libLuau.VM.a <build>/libLuau.Compiler.a <build>/libLuau.Ast.a \
//       <build>/libLuau.Common.a -o host
//
// Usage:
//   host run NAME=FILE:MODE ... SCRIPT:MODE     MODE is interp, native (every function) or roblox (only
//                                               --!native modules and @native functions); each NAME=FILE chunk's return value
//                                               becomes global NAME before the next chunk runs
//   host load FILE REPS [O]                     bytecode size, luau_load time, native compile time
#include "lua.h"
#include "lualib.h"
#include "luacode.h"
#include "luacodegen.h"
#include "Luau/CodeGen.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <algorithm>

static std::string readFile(const std::string& path)
{
    std::ifstream f(path, std::ios::binary);
    if (!f)
    {
        fprintf(stderr, "cannot read %s\n", path.c_str());
        exit(2);
    }
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static std::string compile(const std::string& src, int opt, int debug)
{
    lua_CompileOptions o = {};
    o.optimizationLevel = opt;
    o.debugLevel = debug;
    size_t n = 0;
    char* bc = luau_compile(src.data(), src.size(), &o, &n);
    std::string out(bc, n);
    free(bc);
    return out;
}

static double now()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static lua_State* newState()
{
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    if (luau_codegen_supported())
        luau_codegen_create(L);
    return L;
}

static int runChunk(lua_State* L, const std::string& path, int mode, int opt)
{
    std::string bc = compile(readFile(path), opt, 1);
    std::string chunk = "=" + path;
    if (luau_load(L, chunk.c_str(), bc.data(), bc.size(), 0) != 0)
    {
        fprintf(stderr, "load %s: %s\n", path.c_str(), lua_tostring(L, -1));
        exit(1);
    }
    if (mode == 1)
        luau_codegen_compile(L, -1);
    else if (mode == 2)
    {
        // as on a Roblox server: only --!native modules and @native functions
        Luau::CodeGen::CompilationOptions co;
        co.flags = Luau::CodeGen::CodeGen_OnlyNativeModules;
        Luau::CodeGen::compile(L, -1, co);
    }
    if (lua_pcall(L, 0, 1, 0) != 0)
    {
        fprintf(stderr, "run %s: %s\n", path.c_str(), lua_tostring(L, -1));
        exit(1);
    }
    return 1;
}

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        fprintf(stderr, "usage: host run NAME=FILE:MODE ... SCRIPT:MODE | host load FILE REPS [O]\n");
        return 2;
    }
    int opt = getenv("LUAU_O") ? atoi(getenv("LUAU_O")) : 2;
    if (strcmp(argv[1], "run") == 0)
    {
        lua_State* L = newState();
        for (int i = 2; i < argc; i++)
        {
            std::string spec = argv[i];
            std::string name;
            size_t eq = spec.find('=');
            if (eq != std::string::npos)
            {
                name = spec.substr(0, eq);
                spec = spec.substr(eq + 1);
            }
            size_t colon = spec.rfind(':');
            std::string path = spec.substr(0, colon);
            std::string m = spec.substr(colon + 1);
            int mode = m == "native" ? 1 : m == "roblox" ? 2 : 0;
            runChunk(L, path, mode, opt);
            if (!name.empty())
                lua_setglobal(L, name.c_str());
            else
                lua_pop(L, 1);
        }
        lua_close(L);
        return 0;
    }
    if (strcmp(argv[1], "load") == 0)
    {
        std::string src = readFile(argv[2]);
        int reps = atoi(argv[3]);
        int o = argc > 4 ? atoi(argv[4]) : 2;
        std::string bc0 = compile(src, o, 0);
        std::string bc1 = compile(src, o, 1);
        std::vector<double> tl, tn;
        for (int r = 0; r < 7; r++)
        {
            lua_State* L = newState();
            double t0 = now();
            for (int i = 0; i < reps; i++)
            {
                luau_load(L, "=m", bc1.data(), bc1.size(), 0);
                lua_pop(L, 1);
            }
            double t1 = now();
            for (int i = 0; i < reps; i++)
            {
                luau_load(L, "=m", bc1.data(), bc1.size(), 0);
                luau_codegen_compile(L, -1);
                lua_pop(L, 1);
            }
            double t2 = now();
            tl.push_back((t1 - t0) / reps * 1e6);
            tn.push_back((t2 - t1) / reps * 1e6 - (t1 - t0) / reps * 1e6);
            lua_close(L);
        }
        std::sort(tl.begin(), tl.end());
        std::sort(tn.begin(), tn.end());
        printf("{\"file\":\"%s\",\"bytecode_g0\":%zu,\"bytecode_g1\":%zu,\"load_us\":%.2f,\"native_compile_us\":%.2f}\n",
            argv[2], bc0.size(), bc1.size(), tl[3], tn[3]);
        return 0;
    }
    return 2;
}
