#pragma once

// Phase 7.2 hello-world UE4SS C++ mod. Not the real adapter -- proves a C++ mod can build
// against this machine's UE4SS v3.0.1 and load alongside the already-installed AP_Randomizer
// C++ mod (agent_docs/phases/phase7.md). CppUserModBase interface confirmed by reading
// UE4SS/include/Mod/CppUserModBase.hpp directly (RE-UE4SS, MIT -- agent_docs/licensing.md),
// not from memory. No pseudoregalia-archipelago source was read to write this.

#include <Mod/CppUserModBase.hpp>

namespace MeshGhostPseudo
{
    class Plugin : public RC::CppUserModBase
    {
      public:
        Plugin();
        ~Plugin() override;

        auto on_unreal_init() -> void override;
    };
} // namespace MeshGhostPseudo
