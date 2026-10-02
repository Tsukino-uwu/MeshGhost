// The two exports UE4SS loads this DLL through, shaped as in the dllmain.cpp of RE-UE4SS's cppmods examples.

#include <Plugin.hpp>

extern "C"
{
    __declspec(dllexport) RC::CppUserModBase* start_mod()
    {
        return new MeshGhostPseudo::Plugin();
    }

    __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* mod)
    {
        delete mod;
    }
}
