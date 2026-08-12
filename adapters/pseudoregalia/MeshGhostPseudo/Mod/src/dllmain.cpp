// Windows DLL entry point (UE4SS loads this module). Mod logic lives in Plugin.cpp/hpp.
// Shape confirmed against RE-UE4SS's own cppmods/EventViewerMod/src/dllmain.cpp and
// cppmods/KismetDebuggerMod/src/dllmain.cpp (MIT, see agent_docs/licensing.md).

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
