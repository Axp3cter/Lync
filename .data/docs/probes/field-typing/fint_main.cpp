// Claim 1 instrument: luau-analyze from .data/projects/luau with integer flags (FInt/DFInt) settable from the
// environment, LUAU_FINT="Name=value,Name=value". Built by build_fint.sh; the analyzer itself is unchanged.
#include "Luau/Common.h"
#include <stdlib.h>
#include <string.h>
#include <string>
int analyze_main(int argc, char** argv);
int main(int argc, char** argv)
{
    if (const char* list = getenv("LUAU_FINT"))
    {
        std::string rest = list;
        while (!rest.empty())
        {
            size_t comma = rest.find(',');
            std::string item = rest.substr(0, comma);
            size_t eq = item.find('=');
            std::string name = item.substr(0, eq);
            int value = atoi(item.substr(eq + 1).c_str());
            bool found = false;
            for (Luau::FValue<int>* f = Luau::FValue<int>::list; f; f = f->next)
                if (name == f->name) { f->value = value; found = true; }
            if (!found) { fprintf(stderr, "fint: no flag %s\n", name.c_str()); return 2; }
            rest = comma == std::string::npos ? "" : rest.substr(comma + 1);
        }
    }
    return analyze_main(argc, argv);
}
