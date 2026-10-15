// Times luau_load (bytecode deserialization, what a Roblox client does with a
// replicated ModuleScript) and the first call of the chunk (running the module's
// top level, what require does next). Build against Luau 0.742's VM.
// Usage: loadcost FILE.bc [iterations]
#include "lua.h"
#include "lualib.h"
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <algorithm>

int main(int argc, char** argv) {
    std::ifstream f(argv[1], std::ios::binary);
    std::stringstream ss; ss << f.rdbuf();
    std::string bc = ss.str();
    int iters = argc > 2 ? atoi(argv[2]) : 50;
    std::vector<double> load, run;
    for (int i = 0; i < iters; i++) {
        lua_State* L = luaL_newstate();
        luaL_openlibs(L);
        auto t0 = std::chrono::steady_clock::now();
        if (luau_load(L, "=probe", bc.data(), bc.size(), 0) != 0) { printf("load error: %s\n", lua_tostring(L, -1)); return 1; }
        auto t1 = std::chrono::steady_clock::now();
        if (lua_pcall(L, 0, 1, 0) != 0) { printf("run error: %s\n", lua_tostring(L, -1)); return 1; }
        auto t2 = std::chrono::steady_clock::now();
        load.push_back(std::chrono::duration<double, std::micro>(t1 - t0).count());
        run.push_back(std::chrono::duration<double, std::micro>(t2 - t1).count());
        lua_close(L);
    }
    std::sort(load.begin(), load.end()); std::sort(run.begin(), run.end());
    printf("bytes=%zu load_us_median=%.1f load_us_min=%.1f top_level_us_median=%.1f ns_per_byte=%.2f\n",
           bc.size(), load[iters / 2], load[0], run[iters / 2], load[iters / 2] * 1000.0 / bc.size());
}
