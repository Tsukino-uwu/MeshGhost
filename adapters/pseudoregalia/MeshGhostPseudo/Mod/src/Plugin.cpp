#include <Plugin.hpp>

#include <algorithm>
#include <cstdio>
#include <cwctype>
#include <format>
#include <utility>

#include <BridgeClient.hpp>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Unreal/AActor.hpp>
#include <Unreal/FHitResult.hpp>
#include <Unreal/Hooks.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/World.hpp>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

namespace MeshGhostPseudo
{
    using namespace RC;
    using namespace RC::Unreal;

    // Log bridge stats every ~2s -- same cadence as 7.1/step-1's position log, chosen for
    // readability, not tied to a real need. local_state itself is sent every tick per
    // PROTOCOL.md's tick loop ("send local_state every frame, state may be nil"), not throttled.
    constexpr uint64_t LOG_INTERVAL_TICKS = 120;

    constexpr auto GAME_ID = "pseudoregalia";
    constexpr auto BRIDGE_HOST = "127.0.0.1";
    constexpr uint16_t BRIDGE_PORT = 7778;

    // User-requested diagnostic, 2026-08-13: when true, on_update() skips the bridge/network
    // stack entirely (no core.exe/relay.exe needed) and instead drives one hijacked ghost purely
    // from local reflection reads -- isolates the render-freeze investigation from networking.
    // Flip back to false to return to the real networked adapter.
    constexpr bool LOCAL_OFFSET_TEST_MODE = true;
    constexpr double LOCAL_OFFSET_TEST_X = 150.0;
    constexpr auto LOCAL_OFFSET_TEST_ID = "local-test";

    namespace
    {
        // StringType is std::wstring on this build (confirmed: RE-UE4SS/deps/first/String/
        // include/String/StringType.hpp, CharType = wchar_t unless FORCE_U16 is defined, which
        // it isn't here). The bridge is a plain byte socket expecting UTF-8 JSON text, so every
        // string field needs this conversion before going on the wire.
        auto to_utf8(const StringType& wide) -> std::string
        {
            if (wide.empty())
            {
                return {};
            }
            int needed = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
            std::string result(static_cast<size_t>(needed), '\0');
            WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), result.data(), needed, nullptr, nullptr);
            return result;
        }

        // Minimal JSON string escaping -- only quote and backslash are realistically possible in
        // an Unreal object path (e.g. "/Game/Maps/ZONE_LowerCastle.ZONE_LowerCastle:PersistentLevel"),
        // but escaped defensively to match the Lua adapter's jsonString() safety.
        auto json_escape(const std::string& s) -> std::string
        {
            std::string out;
            out.reserve(s.size() + 2);
            for (char c : s)
            {
                if (c == '"' || c == '\\')
                {
                    out.push_back('\\');
                }
                out.push_back(c);
            }
            return out;
        }

        // Finds the real local PlayerController + its Pawn, or nullptr/nullptr if neither
        // currently exists. See the two bugs already fixed and recorded in
        // agent_docs/pitfalls.md's "Engine reflection / API availability" section:
        // FindFirstOf returns the CDO (need FindAllOf + RF_ClassDefaultObject filter), and Pawn
        // is an inherited property (need GetValuePtrByPropertyNameInChain, not the plain version).
        auto find_local_controller_and_pawn() -> std::pair<UObject*, UObject*>
        {
            std::vector<UObject*> controllers;
            UObjectGlobals::FindAllOf(STR("PlayerController"), controllers);
            for (UObject* candidate : controllers)
            {
                if (!candidate || candidate->HasAnyFlags(RF_ClassDefaultObject))
                {
                    continue;
                }
                UObject** pawn_ptr = candidate->GetValuePtrByPropertyNameInChain<UObject*>(STR("Pawn"));
                if (pawn_ptr && *pawn_ptr)
                {
                    return {candidate, *pawn_ptr};
                }
            }
            return {nullptr, nullptr};
        }

        // Minimal, non-general JSON field extraction -- deliberately not a full parser, matching
        // the Lua adapter's own minimalism (its jsonString()/hand-built envelopes, not a generic
        // decoder). Safe here because the wire format is fixed-shape and server-generated
        // (adapters/_template/PROTOCOL.md), not adversarial input.
        auto json_string_field(const std::string& s, const std::string& key) -> std::string
        {
            std::string needle = "\"" + key + "\":\"";
            size_t pos = s.find(needle);
            if (pos == std::string::npos)
            {
                return {};
            }
            pos += needle.size();
            size_t end = s.find('"', pos);
            if (end == std::string::npos)
            {
                return {};
            }
            return s.substr(pos, end - pos);
        }

        auto json_vec3_field(const std::string& s, const std::string& key, double& a, double& b, double& c) -> bool
        {
            std::string needle = "\"" + key + "\":[";
            size_t pos = s.find(needle);
            if (pos == std::string::npos)
            {
                return false;
            }
            pos += needle.size();
            return std::sscanf(s.c_str() + pos, "%lf,%lf,%lf", &a, &b, &c) == 3;
        }

        // JSON player_id values in this wire format are always plain ASCII ids (e.g. "p1-ghost",
        // stamped by the core, never user-typed free text) -- a byte-widen is safe and avoids
        // pulling in a full UTF-8 decoder just for log lines.
        auto to_wide_ascii(const std::string& s) -> StringType
        {
            return StringType(s.begin(), s.end());
        }

        // Best-effort extra safety margin for the hijack design (user-requested 2026-08-13):
        // interactive/quest-relevant objects (chairs you can sit on, notes you can read) almost
        // certainly aren't plain StaticMeshActor instances -- that base engine class has no
        // built-in interaction support, so anything with attached behavior would need a custom
        // Blueprint subclass instead, which wouldn't even match this FindAllOf("StaticMeshActor")
        // search. This keyword skip is a belt-and-suspenders check on top of that, not the primary
        // safeguard -- it can't catch an interactive object that happens to still be named
        // generically, only ones whose name gives it away.
        constexpr std::wstring_view HIJACK_EXCLUDE_KEYWORDS[] = {
            L"Chair", L"Note", L"Item", L"Quest", L"NPC", L"Pickup", L"Key", L"Book", L"Letter", L"Interact"};

        auto name_has_excluded_keyword(const StringType& full_name) -> bool
        {
            for (std::wstring_view keyword : HIJACK_EXCLUDE_KEYWORDS)
            {
                auto it = std::search(full_name.begin(), full_name.end(), keyword.begin(), keyword.end(), [](wchar_t a, wchar_t b) {
                    return towlower(a) == towlower(b);
                });
                if (it != full_name.end())
                {
                    return true;
                }
            }
            return false;
        }
    } // namespace

    Plugin::Plugin() : CppUserModBase()
    {
        ModName = STR("MeshGhostPseudo");
        ModVersion = STR("0.3.0");
        ModDescription = STR("MeshGhost adapter for Pseudoregalia (Phase 7, C++ rewrite, hijack-based ghosts)");
        ModAuthors = STR("MeshGhost");
    }

    Plugin::~Plugin() = default;

    // Kept from the "Fatal world leaks detected" investigation: dumps every remote's ghost
    // pointer/world whenever called, useful for the LoadMap hook below and for any future
    // diagnostics. See agent_docs/phases/phase7.md's 7.5-in-C++ entries and the plan at
    // lowlevelfatalerror-file-d-build-ue5-sync-zazzy-star.md for the full investigation history.
    auto Plugin::log_remote_state(const wchar_t* context) -> void
    {
        Output::send(STR("[MeshGhostPseudo] remote state dump ({}): {} remote(s)\n"), context, remotes.size());
        for (auto& [id, remote] : remotes)
        {
            Output::send(STR("[MeshGhostPseudo]   remote {}: ghost={} hijack_world={}\n"),
                         to_wide_ascii(id),
                         static_cast<void*>(remote.ghost),
                         static_cast<void*>(remote.hijack_world));
        }
    }

    // Stops tracking one remote's ghost. Never touches the underlying actor -- it was never
    // spawned by us (see the hijack design in Plugin.hpp's RemoteGhost comment), so it isn't ours
    // to destroy; the level's own normal teardown handles a real, always-registered prop like any
    // other actor once its world unloads. Keeps the map entry so ensure_ghost_hijacked can find a
    // fresh hijack target once render_remote resumes in whatever world comes next.
    auto Plugin::release_ghost(const std::string& player_id) -> void
    {
        auto it = remotes.find(player_id);
        if (it == remotes.end() || !it->second.ghost)
        {
            return;
        }
        Output::send(STR("[MeshGhostPseudo] releasing remote {}: ghost={} hijack_world={}\n"),
                     to_wide_ascii(player_id),
                     static_cast<void*>(it->second.ghost),
                     static_cast<void*>(it->second.hijack_world));
        hijacked_actors.erase(it->second.ghost);
        it->second.ghost = nullptr;
        it->second.hijack_world = nullptr;
    }

    auto Plugin::release_all_ghosts(const wchar_t* reason) -> void
    {
        for (auto& [id, remote] : remotes)
        {
            if (!remote.ghost)
            {
                continue;
            }
            Output::send(STR("[MeshGhostPseudo] releasing ghost for remote {} ({}): ghost={} hijack_world={}\n"),
                         to_wide_ascii(id),
                         reason,
                         static_cast<void*>(remote.ghost),
                         static_cast<void*>(remote.hijack_world));
            hijacked_actors.erase(remote.ghost);
            remote.ghost = nullptr;
            remote.hijack_world = nullptr;
        }
    }

    auto Plugin::on_unreal_init() -> void
    {
        Output::send(STR("[MeshGhostPseudo] on_unreal_init reached.\n"));
        unreal_ready = true;
        bridge = std::make_unique<BridgeClient>(BRIDGE_HOST, BRIDGE_PORT);

        // Kept from the investigation: releases every remote's ghost reference synchronously
        // before a LoadMap-driven transition proceeds. With the hijack design this is now just a
        // safety net against touching a dangling pointer post-transition (the level destroys the
        // hijacked prop itself, normally, as part of its own teardown) -- not a leak fix, since
        // there's nothing left for us to leak once we never spawn anything. Call shape (callback +
        // FCallbackOptions, returning a GlobalCallbackId, no separate HookLoadMap() call needed)
        // confirmed from cppmods/EventViewerMod/src/Middleware.cpp, an already-approved MIT
        // reference this phase.
        Hook::RegisterLoadMapPreCallback(
            [this](Hook::TCallbackIterationData<bool>&, UEngine*, FWorldContext&, FURL, UPendingNetGame*, FString&) {
                Output::send(STR("[MeshGhostPseudo] HOOK: LoadMap PRE fired.\n"));
                log_remote_state(STR("LoadMap PRE, before release"));
                release_all_ghosts(STR("LoadMap PRE"));
            },
            Hook::FCallbackOptions{.OwnerModName = STR("MeshGhostPseudo"), .HookName = STR("ReleaseGhostsBeforeLoadMap")});
        Hook::RegisterLoadMapPostCallback(
            [this](Hook::TCallbackIterationData<bool>&, UEngine*, FWorldContext&, FURL, UPendingNetGame*, FString&) {
                Output::send(STR("[MeshGhostPseudo] HOOK: LoadMap POST fired.\n"));
                log_remote_state(STR("LoadMap POST"));
            },
            Hook::FCallbackOptions{.OwnerModName = STR("MeshGhostPseudo"), .HookName = STR("DiagnosticLoadMapPost")});

        // THE render-freeze fix -- see game_thread_tick's own doc comment in Plugin.hpp. Runs
        // every real engine frame, on the actual game thread, unlike on_update() (UE4SS's own
        // ~5ms polling thread). All actor reads/writes now happen here instead.
        Hook::RegisterEngineTickPostCallback(
            [this](Hook::TCallbackIterationData<void>&, UEngine*, float, bool) { game_thread_tick(); },
            Hook::FCallbackOptions{.OwnerModName = STR("MeshGhostPseudo"), .HookName = STR("GameThreadTick")});
    }

    // Redesigned 2026-08-13 after the "Fatal world leaks detected" investigation found no working
    // actor-destroy mechanism on this build (K2_DestroyActor silently no-ops -- confirmed via a
    // GetWorld() readback showing the "destroyed" actor still fully alive seconds later; see
    // agent_docs/pitfalls.md and the plan at lowlevelfatalerror-file-d-build-ue5-sync-zazzy-star.md).
    // Never spawns anything: finds an already-existing, already-registered StaticMeshActor in the
    // local player's current world and hijacks it as the remote's ghost instead. Since nothing new
    // is ever created, there is never anything that needs destroying -- the level's own normal
    // teardown (which has always worked correctly for its own real props) handles cleanup
    // transparently. This also removes the whole auto-possess safety-fix machinery from the prior
    // spawn-based design: a StaticMeshActor can never auto-possess, so that bug class can't recur.
    auto Plugin::ensure_ghost_hijacked(const std::string& player_id, UObject* local_pawn) -> void
    {
        auto existing = remotes.find(player_id);
        if (existing != remotes.end() && existing->second.ghost)
        {
            return;
        }
        if (!local_pawn)
        {
            return;
        }

        auto* local_pawn_actor = static_cast<AActor*>(local_pawn);
        UWorld* world = static_cast<UWorld*>(local_pawn_actor->GetWorld());
        if (!world)
        {
            return;
        }

        // Simplified 2026-08-13 once the real render-freeze cause (on_update() running off the
        // game thread, see verified.md) was found and fixed -- the "prefer already-Movable"
        // heuristic tried here earlier was chasing a symptom of that bug, not a real requirement,
        // and it tended to grab gameplay-relevant Movable objects (walls, platforms) instead of
        // safe decoration -- exactly backwards from what a "safe to hijack" heuristic should
        // prefer. Back to simple first-eligible-candidate selection.
        std::vector<UObject*> candidates;
        UObjectGlobals::FindAllOf(STR("StaticMeshActor"), candidates);
        AActor* hijack_target = nullptr;
        for (UObject* candidate_obj : candidates)
        {
            if (!candidate_obj || candidate_obj->HasAnyFlags(RF_ClassDefaultObject))
            {
                continue;
            }
            auto* candidate = static_cast<AActor*>(candidate_obj);
            if (static_cast<UWorld*>(candidate->GetWorld()) != world)
            {
                continue; // not in the local player's current world
            }
            if (hijacked_actors.contains(candidate))
            {
                continue; // already in use by another remote
            }
            if (name_has_excluded_keyword(candidate->GetFullName()))
            {
                continue; // possibly interactive/quest-relevant -- see HIJACK_EXCLUDE_KEYWORDS
            }
            hijack_target = candidate;
            break;
        }

        if (!hijack_target)
        {
            Output::send(STR("[MeshGhostPseudo] no available StaticMeshActor to hijack for remote {} in this world yet.\n"), to_wide_ascii(player_id));
            return;
        }

        hijack_target->SetActorEnableCollision(false);

        // Ported from the Lua adapter's already-confirmed Mobility fix (Phase 7.4, this exact
        // build): a StaticMeshActor's root component defaults to Static mobility, which silently
        // ignores runtime position changes. Direct property write, not the setter UFunction, per
        // this whole phase's established working pattern for this build. Now that writes happen
        // on the real game thread (game_thread_tick), this should actually take visible effect.
        // EComponentMobility::Movable == 2, same value used successfully in the Lua fix.
        UObject** root_component_ptr = hijack_target->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent"));
        if (root_component_ptr && *root_component_ptr)
        {
            uint8_t* mobility_ptr = (*root_component_ptr)->GetValuePtrByPropertyNameInChain<uint8_t>(STR("Mobility"));
            if (mobility_ptr)
            {
                *mobility_ptr = 2;
                Output::send(STR("[MeshGhostPseudo] set hijacked actor's RootComponent Mobility to Movable (readback: {})\n"), *mobility_ptr);
            }
            else
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: could not find Mobility property on hijacked actor's RootComponent -- it may not move.\n"));
            }
        }
        else
        {
            Output::send(STR("[MeshGhostPseudo] WARNING: could not find RootComponent on hijacked actor -- it may not move.\n"));
        }

        hijacked_actors.insert(hijack_target);

        RemoteGhost& remote = remotes[player_id];
        remote.ghost = hijack_target;
        remote.hijack_world = world;
        FVector current_loc = hijack_target->K2_GetActorLocation();
        remote.target_x = current_loc.X();
        remote.target_y = current_loc.Y();
        remote.target_z = current_loc.Z();
        Output::send(STR("[MeshGhostPseudo] hijacked existing actor for remote {} in world_ptr={} ({})\n"),
                     to_wide_ascii(player_id),
                     static_cast<void*>(world),
                     hijack_target->GetFullName());
    }

    // Parses one received NDJSON line per PROTOCOL.md's wire form and upserts/erases the
    // `remotes` map accordingly. Does not reposition anything itself -- redraw happens
    // unconditionally every tick in on_update, per PROTOCOL.md's "redraw every entry currently in
    // the remote-ghost map, unconditionally" rule (network updates arrive far slower than render).
    auto Plugin::handle_bridge_line(const std::string& line, UObject* local_pawn) -> void
    {
        std::string type = json_string_field(line, "type");
        if (type == "render_remote")
        {
            std::string player_id = json_string_field(line, "player_id");
            if (player_id.empty())
            {
                return;
            }
            double x = 0, y = 0, z = 0;
            if (!json_vec3_field(line, "position", x, y, z))
            {
                return; // state was null or malformed -- nothing to render this frame
            }
            double pitch = 0, yaw = 0, roll = 0;
            json_vec3_field(line, "orientation", pitch, yaw, roll); // best-effort, defaults to 0

            ensure_ghost_hijacked(player_id, local_pawn);
            auto it = remotes.find(player_id);
            if (it != remotes.end())
            {
                it->second.target_x = x;
                it->second.target_y = y;
                it->second.target_z = z;
                it->second.target_pitch = pitch;
                it->second.target_yaw = yaw;
                it->second.target_roll = roll;
            }
        }
        else if (type == "despawn_remote")
        {
            std::string player_id = json_string_field(line, "player_id");
            if (!player_id.empty())
            {
                release_ghost(player_id);
                remotes.erase(player_id);
                Output::send(STR("[MeshGhostPseudo] despawned remote {}\n"), to_wide_ascii(player_id));
            }
        }
    }

    // Self-contained local-only test path -- see LOCAL_OFFSET_TEST_MODE's comment. No bridge, no
    // core/relay, no render_remote parsing: reads the local pawn's own position directly and
    // targets (position.X + offset, position.Y, position.Z), reusing the same hijack/redraw/
    // bHidden-toggle machinery as the real networked path so this is a genuine apples-to-apples
    // isolation of the render-freeze question, not a different code path entirely.
    auto Plugin::run_local_offset_test_tick() -> void
    {
        auto [controller, pawn_obj] = find_local_controller_and_pawn();
        UWorld* current_world = nullptr;
        if (pawn_obj)
        {
            auto* pawn = static_cast<AActor*>(pawn_obj);
            FVector pawn_loc = pawn->K2_GetActorLocation();
            current_world = static_cast<UWorld*>(pawn->GetWorld());

            ensure_ghost_hijacked(LOCAL_OFFSET_TEST_ID, pawn_obj);
            auto it = remotes.find(LOCAL_OFFSET_TEST_ID);
            if (it != remotes.end())
            {
                it->second.target_x = pawn_loc.X() + LOCAL_OFFSET_TEST_X;
                it->second.target_y = pawn_loc.Y();
                it->second.target_z = pawn_loc.Z();
            }
        }

        FHitResult unused_hit_result;
        for (auto& [id, remote] : remotes)
        {
            if (!remote.ghost)
            {
                continue;
            }
            if (current_world && remote.hijack_world && remote.hijack_world != current_world)
            {
                Output::send(STR("[MeshGhostPseudo] (local-test) remote {} ghost's world changed -- releasing stale reference, will hijack fresh.\n"), to_wide_ascii(id));
                hijacked_actors.erase(remote.ghost);
                remote.ghost = nullptr;
                remote.hijack_world = nullptr;
                continue;
            }
            FVector target_loc(remote.target_x, remote.target_y, remote.target_z);
            FRotator target_rot(remote.target_pitch, remote.target_yaw, remote.target_roll);
            remote.ghost->K2_SetActorLocationAndRotation(target_loc, target_rot, false, unused_hit_result, false);

            if (tick_count % LOG_INTERVAL_TICKS == 0)
            {
                FVector actual_loc = remote.ghost->K2_GetActorLocation();
                Output::send(STR("[MeshGhostPseudo] (local-test) remote {} redraw: intended=({},{},{}) actual=({},{},{})\n"),
                             to_wide_ascii(id),
                             target_loc.X(),
                             target_loc.Y(),
                             target_loc.Z(),
                             actual_loc.X(),
                             actual_loc.Y(),
                             actual_loc.Z());

                bool* hidden_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<bool>(STR("bHidden"));
                if (hidden_ptr)
                {
                    *hidden_ptr = true;
                    *hidden_ptr = false;
                }
            }
        }
    }

    // Runs on the real game thread (registered via RegisterEngineTickPostCallback in
    // on_unreal_init) -- see this method's declaration comment in Plugin.hpp for why this split
    // exists. All actor reads/writes for both the real networked path and
    // LOCAL_OFFSET_TEST_MODE happen here now.
    auto Plugin::game_thread_tick() -> void
    {
        if (!unreal_ready)
        {
            return;
        }

        if constexpr (LOCAL_OFFSET_TEST_MODE)
        {
            run_local_offset_test_tick();
            return;
        }

        // Populated below whenever the local pawn/world resolve this tick; used to detect a
        // remote ghost whose hijack_world has since been torn down (e.g. the local player
        // transitioned areas) so we stop touching it -- it was never ours to destroy, but a
        // dangling pointer into a torn-down world must not be dereferenced either.
        UWorld* current_world = nullptr;

        auto [controller, pawn_obj] = find_local_controller_and_pawn();
        if (controller && pawn_obj)
        {
            auto* pawn = static_cast<AActor*>(pawn_obj);
            FVector location = pawn->K2_GetActorLocation();
            FRotator rotation = pawn->K2_GetActorRotation();
            current_world = static_cast<UWorld*>(pawn->GetWorld());
            if (current_world != last_logged_world)
            {
                Output::send(STR("[MeshGhostPseudo] local world changed: pawn={} world_ptr={}\n"),
                             pawn->GetFullName(),
                             static_cast<void*>(current_world));
                last_logged_world = current_world;
            }

            std::string area_id;
            if (current_world)
            {
                UObject** level_ptr = current_world->GetValuePtrByPropertyNameInChain<UObject*>(STR("PersistentLevel"));
                if (level_ptr && *level_ptr)
                {
                    area_id = to_utf8((*level_ptr)->GetFullName());
                }
            }

            // anim: placeholder per 7.3's decision, not a final vocabulary -- real playback
            // is 7.6's problem. "idle" is enough to prove the wire shape end to end.
            std::string local_state = std::format(
                "{{\"type\":\"local_state\",\"payload\":{{\"state\":{{\"area_id\":\"{}\",\"position\":[{},{},{}],"
                "\"orientation\":[{},{},{}],\"anim\":\"idle\"}}}}}}",
                json_escape(area_id),
                location.X(),
                location.Y(),
                location.Z(),
                rotation.GetPitch(),
                rotation.GetYaw(),
                rotation.GetRoll());
            std::lock_guard<std::mutex> lock(state_mutex);
            cached_local_state_json = local_state;
        }
        else
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            cached_local_state_json = R"({"type":"local_state","payload":{"state":null}})";
        }

        std::vector<std::string> lines_to_process;
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            lines_to_process.swap(pending_incoming_lines);
        }
        for (const std::string& line : lines_to_process)
        {
            handle_bridge_line(line, pawn_obj);
        }

        // Redraw every currently-known remote unconditionally, every tick -- per PROTOCOL.md,
        // not only on ticks where new network data arrived.
        FHitResult unused_hit_result;
        for (auto& [id, remote] : remotes)
        {
            if (!remote.ghost)
            {
                continue;
            }
            // Stale-world check first: only meaningful once current_world has actually resolved
            // this tick (it's null on ticks where the local pawn/controller aren't found, e.g.
            // mid-transition -- don't treat that as "the world changed", just skip the check).
            if (current_world && remote.hijack_world && remote.hijack_world != current_world)
            {
                Output::send(STR("[MeshGhostPseudo] remote {} ghost's world changed (local player transitioned) -- releasing stale reference, will hijack fresh.\n"),
                             to_wide_ascii(id));
                hijacked_actors.erase(remote.ghost);
                remote.ghost = nullptr;
                remote.hijack_world = nullptr;
                continue;
            }
            FVector target_loc(remote.target_x, remote.target_y, remote.target_z);
            FRotator target_rot(remote.target_pitch, remote.target_yaw, remote.target_roll);
            remote.ghost->K2_SetActorLocationAndRotation(target_loc, target_rot, false, unused_hit_result, false);

            if (tick_count % LOG_INTERVAL_TICKS == 0)
            {
                FVector actual_loc = remote.ghost->K2_GetActorLocation();
                Output::send(STR("[MeshGhostPseudo] remote {} redraw: intended=({},{},{}) actual=({},{},{})\n"),
                             to_wide_ascii(id),
                             target_loc.X(),
                             target_loc.Y(),
                             target_loc.Z(),
                             actual_loc.X(),
                             actual_loc.Y(),
                             actual_loc.Z());

                bool* hidden_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<bool>(STR("bHidden"));
                if (hidden_ptr)
                {
                    *hidden_ptr = true;
                    *hidden_ptr = false;
                }
            }
        }
    }

    // Phase 7.5-in-C++, step 3 (hijack redesign): pure networking now -- connects, sends the
    // latest cached local_state (built by game_thread_tick, the real game thread), and hands off
    // received lines for game_thread_tick to process. No actor reads/writes happen on this thread
    // anymore (see game_thread_tick's doc comment for why that mattered).
    auto Plugin::on_update() -> void
    {
        if (!unreal_ready)
        {
            return;
        }

        ++tick_count;
        ++ticks_since_ready;

        if constexpr (LOCAL_OFFSET_TEST_MODE)
        {
            return; // handled entirely by game_thread_tick in this mode
        }

        if (!bridge)
        {
            return;
        }

        bridge->tick_connect();

        if (bridge->is_connected())
        {
            if (!bridge->hello_sent())
            {
                std::string hello = std::string("{\"type\":\"hello\",\"payload\":{\"game_id\":\"") + GAME_ID + "\"}}";
                if (bridge->send_line(hello))
                {
                    bridge->mark_hello_sent();
                }
            }

            std::string local_state_to_send;
            {
                std::lock_guard<std::mutex> lock(state_mutex);
                local_state_to_send = cached_local_state_json;
            }
            if (!local_state_to_send.empty())
            {
                bridge->send_line(local_state_to_send);
            }

            std::vector<std::string> received_lines = bridge->poll_lines();
            if (!received_lines.empty())
            {
                std::lock_guard<std::mutex> lock(state_mutex);
                for (std::string& line : received_lines)
                {
                    pending_incoming_lines.push_back(std::move(line));
                }
            }
        }

        if (tick_count % LOG_INTERVAL_TICKS == 0)
        {
            const auto& stats = bridge->stats();
            Output::send<LogLevel::Normal>(
                STR("[MeshGhostPseudo] bridge: connected={} connect_attempts={} send_ok={} send_fail={} "
                    "lines_received={} lines_malformed={}\n"),
                bridge->is_connected(),
                stats.connect_attempts,
                stats.send_ok,
                stats.send_fail,
                stats.lines_received,
                stats.lines_malformed);
        }
    }
} // namespace MeshGhostPseudo
