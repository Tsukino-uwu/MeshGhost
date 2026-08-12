# Root CMakeLists.txt for the Phase 7.2 hello-world UE4SS C++ mod.
#
# Layout and content follow RE-UE4SS's own official guide verbatim in shape (not copied text):
# https://github.com/UE4SS-RE/RE-UE4SS/blob/main/docs/guides/creating-a-c++-mod.md
# (MIT-licensed, see agent_docs/licensing.md). No pseudoregalia-archipelago source was read to
# write this file.
#
# RE-UE4SS/ below is a git submodule, not yet added (git submodule add
# https://github.com/UE4SS-RE/RE-UE4SS RE-UE4SS, pinned to the SHA this machine's install
# actually runs -- 733e5969, see agent_docs/environment.md -- not just "latest"). Add it once
# the CMake/MSVC toolchain is confirmed working, immediately before the first real configure,
# so the pin is verified against a build that actually succeeds.

cmake_minimum_required(VERSION 3.22)
project(MeshGhostPseudoMods)

add_subdirectory(RE-UE4SS)
add_subdirectory(Mod)
