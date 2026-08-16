# Per-mod CMakeLists.txt, shape per RE-UE4SS's own C++ mod guide (MIT, see
# agent_docs/licensing.md) -- not copied from pseudoregalia-archipelago.
#
# OUTPUT_NAME is forced to "main" because UE4SS's C++ mod loader expects
# <ModFolder>/dlls/main.dll regardless of the CMake target name -- confirmed both by RE-UE4SS's
# own installing-a-c++-mod.md guide and by this machine's real, already-installed AP_Randomizer
# mod (ue4ss\Mods\AP_Randomizer\dlls\main.dll), not assumed.

set(TARGET MeshGhostPseudo)

add_library(${TARGET} SHARED
    src/dllmain.cpp
    src/Plugin.cpp
    src/BridgeClient.cpp
    src/CoreLauncher.cpp
)

target_include_directories(${TARGET} PRIVATE src)
target_link_libraries(${TARGET} PUBLIC UE4SS ws2_32)

set_target_properties(${TARGET} PROPERTIES OUTPUT_NAME "main")
