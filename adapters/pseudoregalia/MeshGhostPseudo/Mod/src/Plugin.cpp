#include <Plugin.hpp>

#include <DynamicOutput/DynamicOutput.hpp>

namespace MeshGhostPseudo
{
    using namespace RC;

    Plugin::Plugin() : CppUserModBase()
    {
        ModName = STR("MeshGhostPseudo");
        ModVersion = STR("0.1.0");
        ModDescription = STR("MeshGhost adapter for Pseudoregalia (Phase 7, hello-world stage)");
        ModAuthors = STR("MeshGhost");
    }

    Plugin::~Plugin() = default;

    // Fires once the 'Unreal' module is ready -- the earliest point FindFirstOf/UEHelpers-style
    // reflection would be safe to use (7.3 onward). For 7.2 this only proves the mod loaded and
    // reached that point without crashing or being skipped due to a coexistence conflict with
    // AP_Randomizer.
    auto Plugin::on_unreal_init() -> void
    {
        Output::send(STR("[MeshGhostPseudo] Phase 7.2 hello-world mod loaded, on_unreal_init reached.\n"));
    }
} // namespace MeshGhostPseudo
