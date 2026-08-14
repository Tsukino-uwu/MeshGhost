#include <Plugin.hpp>

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdio>
#include <cwctype>
#include <format>
#include <utility>

#include <BridgeClient.hpp>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Unreal/AActor.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/FFrame.hpp>
#include <Unreal/FHitResult.hpp>
#include <Unreal/Hooks.hpp>
#include <Unreal/UFunctionStructs.hpp>
#include <Unreal/UnrealVersion.hpp>
#include <Unreal/UObject.hpp>
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
    // Sent as this adapter's bridge Hello alongside GAME_ID (internal/bridge.Hello's
    // game_version field, added for relay-safety hardening -- see the ADR in
    // agent_docs/architecture.md). This is this *mod's* own version, not Pseudoregalia's
    // game build -- no cited API exists to read that, and CLAUDE.md's "no addresses/APIs
    // from memory" rule means one isn't guessed at here. Opaque to the core/relay,
    // compared only by equality: it catches two peers running different revisions of this
    // mod, the most likely real source of a silent protocol mismatch.
    constexpr auto ADAPTER_VERSION = "phase7.6";
    constexpr auto BRIDGE_HOST = "127.0.0.1";
    constexpr uint16_t BRIDGE_PORT = 7778;

    // User-requested diagnostic, 2026-08-13: when true, on_update() skips the bridge/network
    // stack entirely (no core.exe/relay.exe needed) and instead drives one hijacked ghost purely
    // from local reflection reads -- isolates the render-freeze investigation from networking.
    // Flip back to false to return to the real networked adapter.
    // Phase 7.6, 2026-08-13: flipped back to false -- the render-freeze this mode was built to
    // isolate is fixed (RegisterEngineTickPostCallback); this diagnostic was done with then.
    // Flipped true again same day (user-requested), repurposed for the facing-direction
    // investigation: run_local_offset_test_tick now uses the same spawn-based ghost mechanism as
    // the real networked path (see its own comment), so this mode gives a true no-networking
    // repro of the rotation bug -- one game instance, no relay.exe/meshghost.exe needed at all.
    // Facing-direction fix confirmed live 2026-08-13 (see verified.md) -- flipped back to false
    // to restore the real networked adapter as the normal shipping path.
    constexpr bool LOCAL_OFFSET_TEST_MODE = false;
    constexpr double LOCAL_OFFSET_TEST_X = 150.0;
    constexpr auto LOCAL_OFFSET_TEST_ID = "local-test";

    // User-requested, 2026-08-13: rather than mirroring the real player's own yaw (which requires
    // walking around to see change), force-cycle the ghost's target yaw through four fixed
    // directions on a timer, so it's immediately obvious on screen whether the ghost can turn at
    // all, independent of whether it's matching the real player correctly.
    // Facing-direction fix confirmed live 2026-08-13 -- flipped back to false to restore real
    // yaw-mirroring as the normal shipping behavior.
    constexpr bool FORCE_ROTATION_CYCLE_TEST = false;
    constexpr uint64_t ROTATION_CYCLE_TICKS = 180; // ~3s at a typical 60fps game thread

    // Phase 7.6: one-constant control between the two ghost designs. true = spawn a clone of the
    // player's own pawn class (real player model, can animate -- what Phase 7.6 is actually for),
    // ported from the Lua adapter's already-proven trySpawnRemoteGhost, but now with every
    // spawn/reposition call made from game_thread_tick (the real game thread) instead of the
    // pre-fix on_update() the original C++ spawn attempt used -- see RemoteGhost's comment in
    // Plugin.hpp for why that distinction is the whole point of this retest. false = the older
    // hijack-an-existing-StaticMeshActor design, kept as an instant revert if the world-leak crash
    // reproduces even on the game thread.
    constexpr bool SPAWN_BASED_GHOSTS = true;

    // Ported from main.lua's MIN_PLAUSIBLE_DISTANCE (probe_ghost/Scripts/main.lua): refuse to
    // spawn against a transform still sitting near the origin -- a real placed pawn transform is
    // never this close to (0,0,0), so this is "the engine hasn't placed this pawn yet", not a
    // real location.
    constexpr double MIN_PLAUSIBLE_DISTANCE = 100.0;

    // Used by release_ghost to park a despawned ghost far out of the playable area, added in a
    // review pass. NEVER destroy the actor -- K2_DestroyActor is confirmed to silently no-op on
    // this build (see the "no working destroy mechanism" comment on ensure_ghost_hijacked), and
    // earlier attempts to work around that caused the "Fatal world leaks detected" crashes this
    // design deliberately avoids. Before this, a peer leaving mid-area left its ghost frozen in
    // place, visible, until the next area transition's own teardown finally reclaimed it; moving
    // it via the already-proven call_set_actor_location_and_rotation path (the same one the
    // redraw loop already calls every tick) fixes the visible-freeze without touching actor
    // lifetime at all -- the level's own teardown on area change is completely unaffected and
    // still does the real cleanup, exactly as before this change. Symmetric with
    // MIN_PLAUSIBLE_DISTANCE's own reasoning: a real placed level position is never this far
    // below the playable area either.
    constexpr double DESPAWN_PARK_Z = -500000.0;

    // User-requested 2026-08-13, re-added: mirrors Lua's original SPAWN_DELAY_TICKS
    // (probe_ghost/Scripts/main.lua, ~5s at that build's tick rate) -- holds off spawning any
    // ghost until this many real game-thread ticks after the local pawn first becomes valid, so
    // the player's own camera settles on a real target first. This is what let the original
    // investigation catch the camera re-pick as a clean, isolated, ~2.6ms-after-spawn event
    // (agent_docs/phases/phase7.md's Phase 7.4 saga) instead of it being tangled up with level-
    // entry camera setup. ~300 ticks at a typical 60fps game thread ~= 5s.
    constexpr uint64_t SPAWN_DELAY_TICKS = 300;

    // User-requested toggle, 2026-08-13: try re-enabling ghost collision as a real fix for the
    // stuck-falling-pose and can't-grab-ledges bugs (both plausibly need a real physics trace to
    // detect ground/ledge contact, which an ActorEnableCollision(false) ghost can never provide),
    // rather than continuing to guess at state-mirroring workarounds. Re-reading phase7.md's own
    // history first: collision-disable was never actually proven necessary -- it was added
    // defensively during the Phase 7.4 drag-bug investigation, but the real causes found later (a
    // live-reference position-mutation bug, then a separate auto-possess bug) were both unrelated
    // to collision; the disable call was "left in place as a reasonable safety measure even though
    // they turned out not to be the actual fix" (phase7.md). Lower risk than it first looked, but
    // still a real behavior change (the ghost can now physically push the real player, get stuck
    // in world geometry on a teleport that lands inside a wall, etc.) -- a named toggle here rather
    // than a silent hardcode, per the user's own "maybe a feature/toggle later" framing.
    // Reverted 2026-08-13 -- tried twice now, both real risk with no solidity gained:
    // (1) blanket SetActorEnableCollision(true) alone: did NOT make the ghost solid (real player
    // walked straight through it), but let melee attack and kill it, which killed the REAL
    // player's own character too. (2) Added SetCollisionResponseToChannel(Pawn, Block) on the
    // ghost's own capsule on top (call_set_collision_response_to_channel): confirmed via log that
    // the function was genuinely found and called (no reflection failure) -- still no solidity.
    // Leading theory: UE's dynamic-vs-dynamic actor blocking needs BOTH sides' collision response
    // to agree on Block, and only the ghost's side was ever changed; the real player's own
    // capsule was very likely never configured to Block the Pawn channel at all, since two-pawn
    // contact was never a real case in this single-player game. Fixing that would mean touching
    // the REAL PLAYER's own live collision component, not just the ghost's -- a materially bigger
    // risk than anything tried so far, on top of an already-demonstrated melee-death danger that
    // is STILL UNRESOLVED. Do not re-enable without explicit go-ahead, and treat any attempt to
    // modify the real player's own collision setup as its own separate, carefully-scoped decision.
    constexpr bool GHOST_COLLISION_ENABLED = false;

    // Redone landed?/jumped? pulse mirror, 2026-08-13 (follow-up session) -- see
    // RemoteGhost::target_land_count's comment in Plugin.hpp for the full root-cause story (the
    // first attempt read/wrote the wrong object, animBPref->landed?/jumped? rather than the pawn,
    // and was a silent no-op on both ends). Ticks to hold landed?/jumped? true on the ghost's own
    // AnimBP once a rising edge is observed on the wire, since the AnimBP's own update graph may
    // re-evaluate and stomp a single-tick write before its state machine transition sees it.
    constexpr uint32_t PULSE_HOLD_TICKS = 3;

    // Read-only diagnostic, 2026-08-13: an every-tick trace (gated on "state looks interesting",
    // not the usual ~2s LOG_INTERVAL_TICKS cadence, since a one-frame AnimBP pulse can't be seen
    // at 2s resolution) of every field plausibly gating the stuck-falling/stuck-ledge-hang
    // transitions, both local and on the ghost, plus a readback of the ghost's own animBPref-
    // >landed?/jumped? right after we write it -- per CLAUDE.md, a write that "ran without errors"
    // is not evidence it actually stuck. Confirmed live 2026-08-13 (both the falling-pose fix and,
    // after adding Montage_Stop, the ledge-hang-stuck-forever fix) -- flipped back to false, same
    // as LOCAL_OFFSET_TEST_MODE/FORCE_ROTATION_CYCLE_TEST after their own investigations concluded.
    constexpr bool ANIM_PULSE_TRACE = false;

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

        // Same minimal-parser philosophy as json_string_field/json_vec3_field above. Used for the
        // animation-state fields nested under "extras" -- key names (move_state, h_speed, etc.)
        // are distinct enough that a whole-string search is safe without properly scoping to the
        // "extras" object, same tradeoff already made for every other field here.
        auto json_number_field(const std::string& s, const std::string& key, double& out) -> bool
        {
            std::string needle = "\"" + key + "\":";
            size_t pos = s.find(needle);
            if (pos == std::string::npos)
            {
                return false;
            }
            pos += needle.size();
            return std::sscanf(s.c_str() + pos, "%lf", &out) == 1;
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

        // Phase 7.6: C++ equivalent of Lua's `ghost:IsValid()`, read from UE4SS's own binding
        // (RE-UE4SS/UE4SS/include/LuaType/LuaUObject.hpp:721-733) rather than guessed. Lua's real
        // check also confirms the object is still present in Lua's own wrapper-lifetime cache
        // (`is_object_in_global_unreal_object_map`), which has no equivalent for a raw C++
        // pointer -- but `IsUnreachable()` is the actual engine-level "the garbage collector has
        // condemned this object" signal Lua's check is built on
        // (deps/first/Unreal/include/Unreal/UObject.hpp:285-287), and is a plain public member
        // function, not Lua-specific.
        auto actor_is_alive(AActor* actor) -> bool
        {
            return actor != nullptr && !actor->IsUnreachable();
        }

        // Clamps a remote-controlled double to a valid uint8_t range before narrowing. Added in
        // a review pass: static_cast<uint8_t>(double) is undefined behavior -- not just "wraps",
        // the way an integer-to-integer narrowing would -- if the value is NaN or outside
        // [0, 255]. move_state/action_state/anim_jump_type/movement_mode all come from a remote
        // peer's extras map, which the Go core only bounds by serialized byte size
        // (protocol.MaxExtrasBytes), not by per-field numeric range or finiteness -- unlike
        // Position, which the core's own storeRemoteState now rejects outright if non-finite
        // (see the ADR in agent_docs/architecture.md), extras values reach here unchecked.
        auto clamp_to_uint8(double value) -> uint8_t
        {
            if (std::isnan(value) || value < 0.0)
            {
                return 0;
            }
            if (value > 255.0)
            {
                return 255;
            }
            return static_cast<uint8_t>(value);
        }

        // 'landed?'/'jumped?' (and every other per-frame anim local: 'Move State', 'landed?', etc.)
        // live on animBPref -- the AnimBP instance -- not on the pawn itself, confirmed via the
        // real reflection dump (see PULSE_HOLD_TICKS's comment above). One hop through
        // GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")) reaches it, same pattern
        // already used elsewhere in this file for CharacterMovement/CapsuleComponent/VisualMesh.
        // Returns false (not found treated the same as "not currently true") if animBPref, or the
        // named bool on it, doesn't resolve -- e.g. a hijacked StaticMeshActor ghost has neither.
        auto read_animbp_bool(UObject* actor, const wchar_t* name) -> bool
        {
            if (!actor)
            {
                return false;
            }
            UObject** abp = actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref"));
            if (!abp || !*abp)
            {
                return false;
            }
            bool* value = (*abp)->GetValuePtrByPropertyNameInChain<bool>(name);
            return value && *value;
        }

        // Write counterpart of read_animbp_bool -- used to drive the ghost's own AnimBP directly,
        // since (unlike moveState/actionState/etc.) landed?/jumped? are set by the AnimBP's own
        // event graph in response to a delegate (LandedDelegate/playerLanded?) the ghost's
        // collision-disabled CharacterMovementComponent can never fire, so mirroring the pawn side
        // alone (the pattern used for every other animation field in this file) cannot work here.
        // No-op, safely, if animBPref or the named bool doesn't resolve (e.g. hijack-mode ghost).
        auto write_animbp_bool(UObject* actor, const wchar_t* name, bool value) -> void
        {
            if (!actor)
            {
                return;
            }
            UObject** abp = actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref"));
            if (!abp || !*abp)
            {
                return;
            }
            if (bool* ptr = (*abp)->GetValuePtrByPropertyNameInChain<bool>(name))
            {
                *ptr = value;
            }
        }

        // Phase 7.6 spawn-safety guard, new (not in the Lua adapter, which never spawned from the
        // title screen because it happened to only reach a real level by the time it first ran):
        // the original C++ spawn crash's ghost was a clone of the title screen's own transient
        // DefaultPawn. Never spawn against anything but the real player pawn class.
        auto class_looks_like_player(UObject* pawn) -> bool
        {
            if (!pawn)
            {
                return false;
            }
            UClass* pawn_class = pawn->GetClassPrivate();
            if (!pawn_class)
            {
                return false;
            }
            StringType class_name = pawn_class->GetFullName();
            constexpr std::wstring_view NEEDLE = L"PlayerGoat";
            auto it = std::search(class_name.begin(), class_name.end(), NEEDLE.begin(), NEEDLE.end(), [](wchar_t a, wchar_t b) {
                return towlower(a) == towlower(b);
            });
            return it != class_name.end();
        }

        // Phase 7.6 bugfix: calling ProcessEvent with a hand-rolled local struct sized by our own
        // guess at a UFunction's real parameter layout is unsafe -- if the function's actual
        // reflected parameter block (UFunction::GetPropertiesSize(), the real size UHT generated
        // for it) is larger than what we guessed, the engine writes past the end of our local
        // buffer into unrelated stack memory. This is the likely cause of a real regression: the
        // first version of the SetViewTargetWithBlend restore call (a 5-field guessed struct)
        // didn't just fail to fix the camera, it broke camera control entirely -- consistent with
        // stack corruption, not a logic bug. Fix: always size the Parms buffer from the function's
        // own GetPropertiesSize(), zero-initialized (matching every default argument value both
        // this call and the Possess call need: 0.0f, enum value 0, false are all all-zero-bits),
        // and only write the one pointer-typed argument every caller here needs, at offset 0 --
        // safe because it's always the first declared parameter (Possess(APawn* InPawn) and
        // SetViewTargetWithBlend(AActor* NewViewTarget, ...) both are). This mirrors what UE4SS's
        // own Lua binding does under the hood (allocates a real, correctly-sized Parms buffer per
        // function rather than a fixed guessed struct), just without Lua's marshalling layer.
        auto call_ufunction_with_leading_actor_arg(UObject* target, UFunction* function, AActor* actor_arg) -> void
        {
            if (!target || !function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < static_cast<int32_t>(sizeof(AActor*)))
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: UFunction {} has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             function->GetName(),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            *reinterpret_cast<AActor**>(params_buffer.data()) = actor_arg;
            target->ProcessEvent(function, params_buffer.data());
        }

        // User-requested, 2026-08-13: an attempt at real physical solidity, since the earlier
        // SetActorEnableCollision(true) test made the ghost killable but never blocking (see
        // agent_docs/risks.md's ghost-collision entry). This game was single-player -- pawn-vs-
        // pawn blocking is a case that plausibly never needed to exist, so the fix is likely a
        // per-channel *collision response* change (Block, not Overlap/Ignore), which is separate
        // from SetActorEnableCollision and not reachable via the plain property reflection used
        // everywhere else in this file (that data lives inside BodyInstance, a UE-internal struct
        // this SDK doesn't expose the layout of -- reading/writing it via a guessed offset would
        // be exactly the "address from memory" CLAUDE.md forbids). The safe path is the real
        // UFunction, UPrimitiveComponent::SetCollisionResponseToChannel(ECollisionChannel Channel,
        // ECollisionResponse NewResponse) -- unlike call_ufunction_with_leading_actor_arg's single
        // pointer argument at a known offset-0, this has two small (byte-sized) parameters whose
        // offsets aren't assumed here -- each parameter's own real FProperty::GetOffset_Internal()
        // is used, the same general technique UE4SS's own Lua ProcessEvent marshalling uses
        // (confirmed via dump_object.lua's Property:GetOffset_Internal() calls) and consistent
        // with this file's existing "don't guess a struct layout" standard.
        auto call_set_collision_response_to_channel(UObject* target, UFunction* function, uint8_t channel, uint8_t response) -> void
        {
            if (!target || !function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 2)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetCollisionResponseToChannel has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            int params_written = 0;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (!property || params_written >= 2)
                {
                    continue;
                }
                params_buffer[static_cast<size_t>(property->GetOffset_Internal())] = (params_written == 0) ? channel : response;
                ++params_written;
            }
            if (params_written < 2)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetCollisionResponseToChannel reflected {} parameter(s), expected 2 -- refusing to call it.\n"),
                             params_written);
                return;
            }
            target->ProcessEvent(function, params_buffer.data());
        }

        // Ledge-hang-stuck-forever fix, 2026-08-13: the landed?/jumped? pulse mirror (see
        // PULSE_HOLD_TICKS's comment) provably resets the ghost's moveState/actionState/
        // movementMode correctly on every real landing, yet the user confirmed live the ghost
        // stays frozen in the ledge-hang POSE regardless of any later jump/slide/land -- a pose
        // that outlives every state-machine byte resetting is the signature of an Anim Montage
        // (started once via a "Play Anim Montage" node, independent of the state machine), not a
        // state-machine transition. Confirmed real, not guessed: log_pawn_reflection_once's
        // UFunction enumeration found 'Montage_Stop' on animBPref's class chain, and a follow-up
        // read-only FProperty dump of that exact function (not assumed from general Unreal Engine
        // knowledge, per CLAUDE.md) confirmed its real parameters: 'InBlendOutTime' (FloatProperty,
        // offset 0) and 'Montage' (ObjectProperty, offset 8, left null in the zeroed buffer below --
        // UAnimInstance::Montage_Stop's own documented behavior for a null Montage argument is to
        // stop whatever is currently playing, which is exactly what's wanted here since which
        // specific UAnimMontage asset played the hang pose was never determined and doesn't need to
        // be). Matched by property NAME here, not just assumed position, in case a future engine
        // update on this SDK ever reorders them.
        auto call_montage_stop(UObject* anim_instance, float blend_out_time) -> void
        {
            if (!anim_instance)
            {
                return;
            }
            UFunction* function = anim_instance->GetFunctionByNameInChain(STR("Montage_Stop"));
            if (!function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < static_cast<int32_t>(sizeof(float)))
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: Montage_Stop has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool found_blend_out = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property && property->GetName() == STR("InBlendOutTime"))
                {
                    *std::bit_cast<float*>(params_buffer.data() + property->GetOffset_Internal()) = blend_out_time;
                    found_blend_out = true;
                }
                // 'Montage' (the UAnimMontage* to stop) is deliberately left null -- see this
                // function's own comment above for why that's the correct value here, not a
                // shortcut.
            }
            if (!found_blend_out)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: Montage_Stop's 'InBlendOutTime' parameter was not found by name -- refusing to call it.\n"));
                return;
            }
            anim_instance->ProcessEvent(function, params_buffer.data());
        }

        // Facing-direction root cause, found 2026-08-13: the vendored RE-UE4SS SDK's own
        // K2_SetActorLocationAndRotation/K2_SetActorRotation (RE-UE4SS/deps/first/Unreal/src/
        // AActor.cpp) marshal FRotator's Pitch/Yaw/Roll as hardcoded `float` into the reflected
        // parameter buffer, unlike FVector's X/Y/Z, which correctly branch on engine version via
        // UE_COPY_VECTOR (BPMacros.hpp). Pseudoregalia is UE 5.1, where the real FRotator fields
        // are `double` -- so every rotation write above put 4 bytes of float into an 8-byte slot
        // of a zeroed buffer, leaving the upper 4 bytes zero. The engine then read back a denormal
        // near zero (confirmed: 90.0f's bit pattern in a zeroed double slot is exactly
        // 5.529052754e-315, matching the ~5.5e-315 "garbage" logged during the investigation) --
        // this is why position (written in the very same call) always stuck while rotation never
        // did, and why a forced 0/90/180/270 yaw cycle produced no visible change: every value
        // became ~0.
        //
        // Fix: a local, version-aware replacement for just this one function, following the same
        // "don't guess a struct layout, read real FProperty offsets" pattern as
        // call_set_collision_response_to_channel above. This can't be fixed by patching the SDK
        // itself -- RE-UE4SS is a git submodule, so this repo tracks only its pinned commit, never
        // its file contents; an edit to BPMacros.hpp would be invisible to anyone cloning this
        // repo and wiped by any `git submodule update`. See agent_docs/pitfalls.md.
        //
        // NOTE: this only covers K2_SetActorLocationAndRotation, the one rotation-writing function
        // this file actually calls. The same float/double bug affects K2_SetActorRotation and
        // presumably every other native FRotator-taking function in this SDK -- do not assume any
        // of those are safe to call directly; route any future rotation write through a helper
        // like this one instead.
        auto call_set_actor_location_and_rotation(AActor* actor, const FVector& new_location, const FRotator& new_rotation) -> void
        {
            if (!actor)
            {
                return;
            }

            static UFunction* function = UObjectGlobals::StaticFindObject<UFunction*>(
                nullptr, nullptr, STR("/Script/Engine.Actor:K2_SetActorLocationAndRotation"));
            if (!function)
            {
                // Cached null is permanent for the process lifetime by
                // design (a core Engine UFunction either exists once the
                // game is running or it never will, so retrying every call
                // buys nothing but cost) -- but the warning itself was not
                // throttled the same way, so every single caller (once per
                // ghost per tick) printed it forever. Found in a review
                // pass; gated the same way the layout-diagnostic message
                // below already is.
                static bool logged_warning_once = false;
                if (!logged_warning_once)
                {
                    Output::send(STR("[MeshGhostPseudo] WARNING: could not find K2_SetActorLocationAndRotation -- ghost rotation will not be set.\n"));
                    logged_warning_once = true;
                }
                return;
            }

            FProperty* location_property = function->FindProperty(FName(STR("NewLocation"), FNAME_Find));
            FProperty* rotation_property = function->FindProperty(FName(STR("NewRotation"), FNAME_Find));
            FProperty* sweep_property = function->FindProperty(FName(STR("bSweep"), FNAME_Find));
            FProperty* teleport_property = function->FindProperty(FName(STR("bTeleport"), FNAME_Find));
            if (!location_property || !rotation_property || !sweep_property || !teleport_property)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: K2_SetActorLocationAndRotation is missing an expected top-level parameter -- refusing to call it.\n"));
                return;
            }

            UScriptStruct* location_struct = static_cast<FStructProperty*>(location_property)->GetStruct();
            UScriptStruct* rotation_struct = static_cast<FStructProperty*>(rotation_property)->GetStruct();
            FProperty* x_property = location_struct ? location_struct->FindProperty(FName(STR("X"), FNAME_Find)) : nullptr;
            FProperty* y_property = location_struct ? location_struct->FindProperty(FName(STR("Y"), FNAME_Find)) : nullptr;
            FProperty* z_property = location_struct ? location_struct->FindProperty(FName(STR("Z"), FNAME_Find)) : nullptr;
            FProperty* pitch_property = rotation_struct ? rotation_struct->FindProperty(FName(STR("Pitch"), FNAME_Find)) : nullptr;
            FProperty* yaw_property = rotation_struct ? rotation_struct->FindProperty(FName(STR("Yaw"), FNAME_Find)) : nullptr;
            FProperty* roll_property = rotation_struct ? rotation_struct->FindProperty(FName(STR("Roll"), FNAME_Find)) : nullptr;
            if (!x_property || !y_property || !z_property || !pitch_property || !yaw_property || !roll_property)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: K2_SetActorLocationAndRotation's NewLocation/NewRotation struct is missing an expected inner field -- refusing to call it.\n"));
                return;
            }

            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < static_cast<int32_t>(location_property->GetOffset_Internal() + location_property->GetSize())
                || parms_size < static_cast<int32_t>(rotation_property->GetOffset_Internal() + rotation_property->GetSize()))
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: K2_SetActorLocationAndRotation has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"), parms_size);
                return;
            }

            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            uint8_t* base = params_buffer.data();
            int32_t loc_base = location_property->GetOffset_Internal();
            int32_t rot_base = rotation_property->GetOffset_Internal();

            // Mirrors UE_COPY_VECTOR (BPMacros.hpp): double on UE 5.0+, float below -- this is the
            // branch the rotation path was missing.
            static const bool use_float = Version::IsBelow(5, 0);
            static bool logged_once = false;
            if (!logged_once)
            {
                Output::send(STR("[MeshGhostPseudo] call_set_actor_location_and_rotation: NewLocation@{} NewRotation@{} inner_type={} parms_size={}\n"),
                             loc_base, rot_base, use_float ? STR("float") : STR("double"), parms_size);
                logged_once = true;
            }

            if (use_float)
            {
                *std::bit_cast<float*>(base + loc_base + x_property->GetOffset_Internal()) = static_cast<float>(new_location.X());
                *std::bit_cast<float*>(base + loc_base + y_property->GetOffset_Internal()) = static_cast<float>(new_location.Y());
                *std::bit_cast<float*>(base + loc_base + z_property->GetOffset_Internal()) = static_cast<float>(new_location.Z());
                *std::bit_cast<float*>(base + rot_base + pitch_property->GetOffset_Internal()) = static_cast<float>(new_rotation.GetPitch());
                *std::bit_cast<float*>(base + rot_base + yaw_property->GetOffset_Internal()) = static_cast<float>(new_rotation.GetYaw());
                *std::bit_cast<float*>(base + rot_base + roll_property->GetOffset_Internal()) = static_cast<float>(new_rotation.GetRoll());
            }
            else
            {
                *std::bit_cast<double*>(base + loc_base + x_property->GetOffset_Internal()) = new_location.X();
                *std::bit_cast<double*>(base + loc_base + y_property->GetOffset_Internal()) = new_location.Y();
                *std::bit_cast<double*>(base + loc_base + z_property->GetOffset_Internal()) = new_location.Z();
                *std::bit_cast<double*>(base + rot_base + pitch_property->GetOffset_Internal()) = new_rotation.GetPitch();
                *std::bit_cast<double*>(base + rot_base + yaw_property->GetOffset_Internal()) = new_rotation.GetYaw();
                *std::bit_cast<double*>(base + rot_base + roll_property->GetOffset_Internal()) = new_rotation.GetRoll();
            }

            *std::bit_cast<bool*>(base + sweep_property->GetOffset_Internal()) = false;
            *std::bit_cast<bool*>(base + teleport_property->GetOffset_Internal()) = true;

            actor->ProcessEvent(function, params_buffer.data());
        }
    } // namespace

    Plugin::Plugin() : CppUserModBase()
    {
        ModName = STR("MeshGhostPseudo");
        ModVersion = STR("0.4.0");
        ModDescription = STR("MeshGhost adapter for Pseudoregalia (Phase 7.6, spawn-based ghosts on the game thread)");
        ModAuthors = STR("MeshGhost");
    }

    // Unregisters every detour this mod installed, found missing in a review pass: the
    // GlobalCallbackId/CallbackId each Register*/RegisterPreHook call below returns was
    // previously discarded, so on mod unload/reload every one of these detours stayed active,
    // pointing at this (about-to-be-freed) Plugin instance -- a real dangling-callback hazard,
    // even though normal single-session play never unloads the mod and so never exercised it.
    // Hook::ERROR_ID (0) / -1 mean "never actually registered" (e.g. svtwb_function was never
    // found), guarded the same way the registration sites themselves guard a failed lookup.
    Plugin::~Plugin()
    {
        if (load_map_pre_callback_id != Hook::ERROR_ID)
        {
            Hook::UnregisterCallback(load_map_pre_callback_id);
        }
        if (load_map_post_callback_id != Hook::ERROR_ID)
        {
            Hook::UnregisterCallback(load_map_post_callback_id);
        }
        if (engine_tick_post_callback_id != Hook::ERROR_ID)
        {
            Hook::UnregisterCallback(engine_tick_post_callback_id);
        }
        if (svtwb_function && svtwb_hook_id != -1)
        {
            svtwb_function->UnregisterHook(svtwb_hook_id);
        }
    }

    // Kept from the "Fatal world leaks detected" investigation: dumps every remote's ghost
    // pointer/world whenever called, useful for the LoadMap hook below and for any future
    // diagnostics. See agent_docs/phases/phase7.md's 7.5-in-C++ entries and the plan at
    // lowlevelfatalerror-file-d-build-ue5-sync-zazzy-star.md for the full investigation history.
    auto Plugin::log_remote_state(const wchar_t* context) -> void
    {
        Output::send(STR("[MeshGhostPseudo] remote state dump ({}): {} remote(s)\n"), context, remotes.size());
        for (auto& [id, remote] : remotes)
        {
            Output::send(STR("[MeshGhostPseudo]   remote {}: ghost={} owning_world={}\n"),
                         to_wide_ascii(id),
                         static_cast<void*>(remote.ghost),
                         static_cast<void*>(remote.owning_world));
        }
    }

    // Stops tracking one remote's ghost. Never destroys the underlying actor -- see
    // DESPAWN_PARK_Z's own comment for why that's a hard rule here, not a missed optimization.
    // Under the hijack design the actor was never ours to destroy anyway; under the spawn design
    // (Phase 7.6), a level transition destroys it out from under us on its own (confirmed live
    // throughout the Lua saga) and game_thread_tick's own staleness check (actor_is_alive) is
    // what actually notices and clears a dead ghost after that happens.
    //
    // Found in a review pass: before parking the ghost below, a peer despawning mid-area (not via
    // an area transition) left its ghost standing frozen in place, visible, until the *next* area
    // transition's teardown finally reclaimed it -- cosmetic, but real. Parking moves it far out
    // of the playable area via the same proven move call the redraw loop already uses every tick,
    // with no change to actor lifetime at all; the level's own eventual teardown on area change is
    // completely unaffected and still does the real cleanup, exactly as before this change.
    //
    // Keeps the map entry so the next ensure_ghost_spawned/ensure_ghost_hijacked call can produce
    // a fresh ghost once render_remote resumes in whatever world comes next.
    auto Plugin::release_ghost(const std::string& player_id) -> void
    {
        auto it = remotes.find(player_id);
        if (it == remotes.end() || !it->second.ghost)
        {
            return;
        }
        Output::send(STR("[MeshGhostPseudo] releasing remote {}: ghost={} owning_world={}\n"),
                     to_wide_ascii(player_id),
                     static_cast<void*>(it->second.ghost),
                     static_cast<void*>(it->second.owning_world));

        FVector park_loc(it->second.target_x, it->second.target_y, DESPAWN_PARK_Z);
        FRotator park_rot(it->second.target_pitch, it->second.target_yaw, it->second.target_roll);
        call_set_actor_location_and_rotation(it->second.ghost, park_loc, park_rot);

        hijacked_actors.erase(it->second.ghost);
        it->second.ghost = nullptr;
        it->second.owning_world = nullptr;
    }

    auto Plugin::release_all_ghosts(const wchar_t* reason) -> void
    {
        for (auto& [id, remote] : remotes)
        {
            if (!remote.ghost)
            {
                continue;
            }
            Output::send(STR("[MeshGhostPseudo] releasing ghost for remote {} ({}): ghost={} owning_world={}\n"),
                         to_wide_ascii(id),
                         reason,
                         static_cast<void*>(remote.ghost),
                         static_cast<void*>(remote.owning_world));
            hijacked_actors.erase(remote.ghost);
            remote.ghost = nullptr;
            remote.owning_world = nullptr;
        }
    }

    auto Plugin::release_all_ghosts_parked(const wchar_t* reason) -> void
    {
        Output::send(STR("[MeshGhostPseudo] parking all ghosts ({}): {} remote(s)\n"), reason, remotes.size());
        for (auto& [id, remote] : remotes)
        {
            if (!remote.ghost)
            {
                continue;
            }
            release_ghost(id);
        }
    }

    auto Plugin::on_unreal_init() -> void
    {
        Output::send(STR("[MeshGhostPseudo] on_unreal_init reached.\n"));
        unreal_ready = true;
        bridge = std::make_unique<BridgeClient>(BRIDGE_HOST, BRIDGE_PORT);

        // Kept from the investigation: releases every remote's ghost reference synchronously
        // before a LoadMap-driven transition proceeds. This drops our own bookkeeping (a dangling-
        // pointer safety net, same as it always was) -- it does NOT destroy the actor itself, so
        // under the spawn design (Phase 7.6) it is deliberately NOT relied on as the fix for the
        // original "Fatal world leaks detected" crash. Whether that crash still happens now that
        // spawn/reposition calls run on the game thread (unlike the original spawn attempt) is
        // exactly what this retest is for -- see RemoteGhost's comment in Plugin.hpp. Call shape
        // (callback + FCallbackOptions, returning a GlobalCallbackId, no separate HookLoadMap()
        // call needed) confirmed from cppmods/EventViewerMod/src/Middleware.cpp, an
        // already-approved MIT reference this phase.
        load_map_pre_callback_id = Hook::RegisterLoadMapPreCallback(
            [this](Hook::TCallbackIterationData<bool>&, UEngine*, FWorldContext&, FURL, UPendingNetGame*, FString&) {
                Output::send(STR("[MeshGhostPseudo] HOOK: LoadMap PRE fired.\n"));
                log_remote_state(STR("LoadMap PRE, before release"));
                release_all_ghosts(STR("LoadMap PRE"));

                // Crash fix, found live 2026-08-13: entering a new area crashed with
                // EXCEPTION_ACCESS_VIOLATION inside the camera fight-back hook. last_known_good_
                // view_target is a raw AActor* cached across calls -- calling ->IsUnreachable() on
                // it (the existing staleness check) dereferences the object's own memory, which is
                // only safe if the object is merely GC-unreachable-but-still-allocated, not if a
                // level transition has actually freed it. Unlike Lua's IsValid() (which checks a
                // separate live-object registry before ever touching the object's own memory,
                // see actor_is_alive's comment), there is no safe way to test a raw AActor* for
                // "has this been fully freed" here -- so never let the pointer survive into a
                // transition in the first place. Same reasoning as release_all_ghosts above, just
                // for the camera's cached reference instead of the ghosts' own.
                last_known_good_view_target = nullptr;
            },
            Hook::FCallbackOptions{.OwnerModName = STR("MeshGhostPseudo"), .HookName = STR("ReleaseGhostsBeforeLoadMap")});
        load_map_post_callback_id = Hook::RegisterLoadMapPostCallback(
            [this](Hook::TCallbackIterationData<bool>&, UEngine*, FWorldContext&, FURL, UPendingNetGame*, FString&) {
                Output::send(STR("[MeshGhostPseudo] HOOK: LoadMap POST fired.\n"));
                log_remote_state(STR("LoadMap POST"));
            },
            Hook::FCallbackOptions{.OwnerModName = STR("MeshGhostPseudo"), .HookName = STR("DiagnosticLoadMapPost")});

        // THE render-freeze fix -- see game_thread_tick's own doc comment in Plugin.hpp. Runs
        // every real engine frame, on the actual game thread, unlike on_update() (UE4SS's own
        // ~5ms polling thread). All actor reads/writes now happen here instead.
        engine_tick_post_callback_id = Hook::RegisterEngineTickPostCallback(
            [this](Hook::TCallbackIterationData<void>&, UEngine*, float, bool) { game_thread_tick(); },
            Hook::FCallbackOptions{.OwnerModName = STR("MeshGhostPseudo"), .HookName = STR("GameThreadTick")});

        // Third attempt, using UFunction::RegisterPreHook instead of a ProcessEvent filter -- see
        // this function's own comment for why the first two never even fired.
        register_camera_fightback_hook();
    }

    // Phase 7.6, third attempt. Root cause of why the first two attempts never even fired: this
    // game calls SetViewTargetWithBlend as a *native* function (FUNC_Native), and confirmed by
    // reading UE4SS's own Lua RegisterHook implementation directly
    // (RE-UE4SS/UE4SS/src/Mod/LuaMod.cpp:3907-3921) -- for a native UFunction, Lua's RegisterHook
    // does NOT use a ProcessEvent hook at all; it calls UFunction::RegisterPreHook/RegisterPostHook
    // directly on the function object, which patches the function's own native entry point and
    // catches every call regardless of whether it's dispatched through ProcessEvent or called
    // directly by the engine's own native C++ code. RegisterProcessEventPostCallback (the previous
    // two attempts) only ever sees ProcessEvent-dispatched (Blueprint VM) calls -- a genuinely
    // different, narrower set of calls than what Lua's RegisterHook covers, which is why it never
    // fired even once (confirmed: zero DIAGNOSTIC log lines across a live run that visibly hit the
    // bug).
    //
    // This also enables a strictly safer design than "let the wrong call happen, then make a
    // second corrective call": RegisterPreHook fires BEFORE the engine's own native call runs, and
    // UnrealScriptFunctionCallableContext::GetParams<T>() gives direct access to the *engine's
    // own*, already-correctly-sized argument buffer (TheStack.Locals()) -- so the fix is to read
    // and, if needed, overwrite NewViewTarget (the first argument, offset 0) in place before the
    // real call proceeds. No second call, no guessed buffer size, no reentrancy, no defer-to-next-
    // tick needed -- the corrected value is simply what the engine's own call uses.
    auto Plugin::register_camera_fightback_hook() -> void
    {
        svtwb_function = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/Engine.PlayerController:SetViewTargetWithBlend"));
        if (!svtwb_function)
        {
            Output::send(STR("[MeshGhostPseudo] WARNING: could not find SetViewTargetWithBlend UFunction -- camera fight-back disabled this session.\n"));
            return;
        }

        struct SetViewTargetWithBlendLocals
        {
            AActor* NewViewTarget;
        };

        svtwb_hook_id = svtwb_function->RegisterPreHook(
            [this](UnrealScriptFunctionCallableContext& ctx, void*) {
                SetViewTargetWithBlendLocals& locals = ctx.GetParams<SetViewTargetWithBlendLocals>();
                AActor* target = locals.NewViewTarget;
                if (!target || target->IsUnreachable())
                {
                    return;
                }

                if (!any_ghost_ever_spawned)
                {
                    last_known_good_view_target = target;
                    return;
                }

                if (!last_known_good_view_target || last_known_good_view_target->IsUnreachable())
                {
                    // A level transition destroys the previous area's camera rig, invalidating
                    // last_known_good_view_target permanently -- re-baseline on the first call
                    // after a transition instead of leaving the fight-back mechanism disabled
                    // forever (Lua's confirmed fix for the exact same failure mode).
                    last_known_good_view_target = target;
                    return;
                }

                if (target == last_known_good_view_target)
                {
                    return;
                }

                Output::send(STR("[MeshGhostPseudo] camera fight-back: rewriting NewViewTarget from {} to {} before the real call runs.\n"),
                             target->GetFullName(),
                             last_known_good_view_target->GetFullName());
                locals.NewViewTarget = last_known_good_view_target;
            },
            nullptr);
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
        remote.owning_world = world;
        FVector current_loc = hijack_target->K2_GetActorLocation();
        remote.target_x = current_loc.X();
        remote.target_y = current_loc.Y();
        remote.target_z = current_loc.Z();
        Output::send(STR("[MeshGhostPseudo] hijacked existing actor for remote {} in world_ptr={} ({})\n"),
                     to_wide_ascii(player_id),
                     static_cast<void*>(world),
                     hijack_target->GetFullName());
    }

    // Phase 7.6: spawn-based ghost design, retested on the real game thread (this function is only
    // ever called from game_thread_tick's own call chain -- see handle_bridge_line below). Ported
    // field-for-field from the Lua adapter's trySpawnRemoteGhost
    // (probe_ghost/Scripts/main.lua:596-650), which spawned this exact way and survived real area
    // transitions -- the only C++ spawn attempt that ever crashed made every one of these calls
    // from on_update() (UE4SS's own polling thread) instead. See RemoteGhost's comment in
    // Plugin.hpp for the full reasoning.
    auto Plugin::ensure_ghost_spawned(const std::string& player_id, UObject* local_pawn, UObject* local_controller) -> void
    {
        auto existing = remotes.find(player_id);
        if (existing != remotes.end() && existing->second.ghost)
        {
            return;
        }
        if (!local_pawn || !local_controller)
        {
            return;
        }

        // Re-added 2026-08-13 (user-requested): hold off spawning until the player's own camera
        // has had time to settle on a real target -- see SPAWN_DELAY_TICKS's own comment for why.
        if (ticks_since_pawn_valid < SPAWN_DELAY_TICKS)
        {
            return;
        }

        // Refuse to spawn against the title-screen's transient DefaultPawn -- the original C++
        // spawn crash's ghost was exactly this. No ghost exists until the real player pawn exists.
        if (!class_looks_like_player(local_pawn))
        {
            return;
        }

        auto* local_pawn_actor = static_cast<AActor*>(local_pawn);
        UWorld* world = static_cast<UWorld*>(local_pawn_actor->GetWorld());
        if (!world)
        {
            return;
        }

        FVector spawn_loc = local_pawn_actor->K2_GetActorLocation();
        FRotator spawn_rot = local_pawn_actor->K2_GetActorRotation();

        // Lua's MIN_PLAUSIBLE_DISTANCE guard (main.lua): a pawn whose transform hasn't been
        // placed yet by the engine reads back near the origin -- wait for a real placement rather
        // than spawning the clone there.
        double distance_from_origin = std::sqrt(spawn_loc.X() * spawn_loc.X() + spawn_loc.Y() * spawn_loc.Y() + spawn_loc.Z() * spawn_loc.Z());
        if (distance_from_origin < MIN_PLAUSIBLE_DISTANCE)
        {
            return;
        }

        UClass* pawn_class = local_pawn->GetClassPrivate();
        if (!pawn_class)
        {
            return;
        }

        AActor* ghost = world->SpawnActor(pawn_class, &spawn_loc, &spawn_rot);
        if (!ghost)
        {
            Output::send(STR("[MeshGhostPseudo] SpawnActor returned nullptr for remote {}.\n"), to_wide_ascii(player_id));
            return;
        }

        // Facing-direction investigation, 2026-08-13: bisecting whether the ghost's
        // CapsuleComponent RelativeRotation is already garbage right at spawn (before Possess,
        // collision, or any redraw-loop write ever touches it) or develops later. Read-only,
        // fires once per spawn. Also checking the ghost's own bOrientRotationToMovement here since
        // it's nearly free once this block exists -- confirmed true on the real player already,
        // never checked on the ghost.
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: spawn_rot passed to SpawnActor = (pitch={}, yaw={}, roll={})\n"),
                         spawn_rot.GetPitch(), spawn_rot.GetYaw(), spawn_rot.GetRoll());
            if (UObject** spawn_capsule_ptr = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); spawn_capsule_ptr && *spawn_capsule_ptr)
            {
                if (FRotator* spawn_capsule_rot = (*spawn_capsule_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
                {
                    Output::send(STR("[MeshGhostPseudo] DIAG: ghost CapsuleComponent RelativeRotation immediately after SpawnActor = (pitch={}, yaw={}, roll={})\n"),
                                 spawn_capsule_rot->GetPitch(), spawn_capsule_rot->GetYaw(), spawn_capsule_rot->GetRoll());
                }
                else
                {
                    Output::send(STR("[MeshGhostPseudo] DIAG: ghost CapsuleComponent has no reflected RelativeRotation property.\n"));
                }
            }
            else
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: ghost has no reflected CapsuleComponent immediately after SpawnActor.\n"));
            }
            if (UObject** spawn_movement_ptr = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CharacterMovement")); spawn_movement_ptr && *spawn_movement_ptr)
            {
                if (bool* spawn_orient_ptr = (*spawn_movement_ptr)->GetValuePtrByPropertyNameInChain<bool>(STR("bOrientRotationToMovement")))
                {
                    Output::send(STR("[MeshGhostPseudo] DIAG: ghost CharacterMovement bOrientRotationToMovement = {} -- forcing to false\n"), *spawn_orient_ptr);
                    // Facing-direction fix attempt, 2026-08-13: confirmed via the spawn-time DIAG
                    // above that CapsuleComponent RelativeRotation is CORRECT immediately after
                    // SpawnActor (matches spawn_rot exactly) and only goes garbage sometime after
                    // -- ruling out spawn-time corruption. bOrientRotationToMovement=true (real
                    // player has this too) is the leading remaining candidate: the ghost is
                    // teleported, not driven by real movement input, so its
                    // CharacterMovementComponent's own internal velocity tracking is presumably
                    // near-zero/bogus -- if the component re-derives rotation from that every
                    // tick, it would explain rotation starting correct then being overwritten with
                    // garbage shortly after, independent of our own explicit rotation writes.
                    // Forcing this false leaves K2_SetActorLocationAndRotation as the sole source
                    // of truth for the ghost's rotation.
                    *spawn_orient_ptr = false;
                }
            }
        }

        // Auto-possess safety fix (Phase 7.4, agent_docs/pitfalls.md's "Spawned actors
        // auto-possessing" -- BP_PlayerGoatMain_C auto-possesses on spawn and will otherwise steal
        // control from the real player). GetFunctionByNameInChain matches Lua's
        // controller:Possess(pawn) call and the pattern already confirmed live for this exact call
        // in the earlier (pre-thread-fix) spawn attempt, agent_docs/phases/phase7.md:1045-1046 --
        // reflection worked for Possess even when it didn't for K2_DestroyActor/SetVisibility/
        // DestroyComponent, so this is not a shot in the dark. call_ufunction_with_leading_actor_arg
        // sizes the Parms buffer from the function's own real GetPropertiesSize() rather than a
        // hand-guessed struct -- see that helper's comment for why that distinction matters.
        UFunction* possess_fn = local_controller->GetFunctionByNameInChain(STR("Possess"));
        if (possess_fn)
        {
            call_ufunction_with_leading_actor_arg(local_controller, possess_fn, local_pawn_actor);
        }
        else
        {
            Output::send(STR("[MeshGhostPseudo] WARNING: Controller has no reflected Possess function -- the real player may lose control.\n"));
        }

        // Facing-direction bisection, 2026-08-13: rotation is confirmed correct immediately after
        // SpawnActor (the DIAG block above) but garbage by the time the redraw loop reads it.
        // bOrientRotationToMovement=false didn't change that. Next candidate: the ghost briefly
        // auto-possesses itself on spawn (this whole Possess() call above exists specifically to
        // hand control back), so this checks whether the corruption happens during/because of
        // that possess/un-possess cycle -- reading right after it, before anything else
        // (collision, animation writes) touches the ghost.
        if (UObject** post_possess_capsule_ptr = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); post_possess_capsule_ptr && *post_possess_capsule_ptr)
        {
            if (FRotator* post_possess_rot = (*post_possess_capsule_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: ghost CapsuleComponent RelativeRotation immediately after Possess() = (pitch={}, yaw={}, roll={})\n"),
                             post_possess_rot->GetPitch(), post_possess_rot->GetYaw(), post_possess_rot->GetRoll());
            }
        }

        ghost->SetActorEnableCollision(GHOST_COLLISION_ENABLED);

        // Physical-solidity attempt -- see call_set_collision_response_to_channel's own comment.
        // STILL DOES NOT ADDRESS THE MELEE-DAMAGE RISK from the earlier collision test (see
        // agent_docs/risks.md) -- this only adds a Block response on the standard Pawn channel on
        // top of whatever collision was already enabled; it does not touch whatever channel the
        // real player's melee hit-detection actually queries, which is still unidentified. Only
        // meaningful while GHOST_COLLISION_ENABLED is true.
        if constexpr (GHOST_COLLISION_ENABLED)
        {
            // ECollisionChannel::ECC_Pawn = 2, ECollisionResponse::ECR_Block = 2 -- stable public
            // UE engine constants (Engine/EngineTypes.h), not this game's own data, unchanged
            // since UE4's initial public release.
            constexpr uint8_t ECC_PAWN = 2;
            constexpr uint8_t ECR_BLOCK = 2;
            if (UObject** ghost_capsule_ptr = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); ghost_capsule_ptr && *ghost_capsule_ptr)
            {
                UObject* ghost_capsule = *ghost_capsule_ptr;
                UFunction* set_response_fn = ghost_capsule->GetFunctionByNameInChain(STR("SetCollisionResponseToChannel"));
                if (set_response_fn)
                {
                    call_set_collision_response_to_channel(ghost_capsule, set_response_fn, ECC_PAWN, ECR_BLOCK);
                    Output::send(STR("[MeshGhostPseudo] attempted SetCollisionResponseToChannel(Pawn, Block) on ghost capsule for remote {}.\n"), to_wide_ascii(player_id));
                }
                else
                {
                    Output::send(STR("[MeshGhostPseudo] WARNING: ghost CapsuleComponent has no reflected SetCollisionResponseToChannel function.\n"));
                }
            }
        }

        any_ghost_ever_spawned = true; // gates the camera fight-back hook -- see its own comment

        RemoteGhost& remote = remotes[player_id];
        remote.ghost = ghost;
        remote.owning_world = world;
        remote.target_x = spawn_loc.X();
        remote.target_y = spawn_loc.Y();
        remote.target_z = spawn_loc.Z();
        Output::send(STR("[MeshGhostPseudo] spawned ghost for remote {} in world_ptr={} ({})\n"),
                     to_wide_ascii(player_id),
                     static_cast<void*>(world),
                     ghost->GetFullName());
    }

    // Parses one received NDJSON line per PROTOCOL.md's wire form and upserts/erases the
    // `remotes` map accordingly. Does not reposition anything itself -- redraw happens
    // unconditionally every tick in on_update, per PROTOCOL.md's "redraw every entry currently in
    // the remote-ghost map, unconditionally" rule (network updates arrive far slower than render).
    auto Plugin::handle_bridge_line(const std::string& line, UObject* local_pawn, UObject* local_controller) -> void
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

            // Animation-state mirror (see verified.md's "ghost animation" entry) -- best-effort,
            // each defaults to 0 if missing (e.g. an older peer build without this field yet).
            double move_state = 0, action_state = 0, h_speed = 0, v_speed = 0, anim_jump_type = 0, movement_mode = 0;
            json_number_field(line, "move_state", move_state);
            json_number_field(line, "action_state", action_state);
            json_number_field(line, "h_speed", h_speed);
            json_number_field(line, "v_speed", v_speed);
            json_number_field(line, "anim_jump_type", anim_jump_type);
            json_number_field(line, "movement_mode", movement_mode);
            double land_count = 0, jump_count = 0;
            json_number_field(line, "land_count", land_count);
            json_number_field(line, "jump_count", jump_count);

            // Checked before ensure_ghost_spawned/ensure_ghost_hijacked, both of which insert a
            // default-constructed RemoteGhost via remotes[player_id] on their very first call for
            // a given player_id regardless of whether the spawn/hijack itself succeeds -- so this
            // is true exactly once per remote, on the call that creates its entry.
            bool is_new_remote = remotes.find(player_id) == remotes.end();

            if constexpr (SPAWN_BASED_GHOSTS)
            {
                ensure_ghost_spawned(player_id, local_pawn, local_controller);
            }
            else
            {
                ensure_ghost_hijacked(player_id, local_pawn);
            }
            auto it = remotes.find(player_id);
            if (it != remotes.end())
            {
                // Loopback ghost offset, 2026-08-14 -- user-requested, generalized from the same
                // fix in adapters/pokemon/emerald/meshghost_emerald.lua's drawRemotes(). A
                // loopback-echoed ghost (internal/relay's dev-only -loopback flag, id =
                // "<id>-ghost") otherwise renders exactly on top of the real player -- it's an
                // echo of your own position by definition -- which made it hard to visually
                // judge ghost rendering quality against the real character side by side. Nudge
                // it sideways purely for local rendering; never changes what's actually
                // sent/received over the network (target_x/y/z here is only ever a local render
                // target). Reuses LOCAL_OFFSET_TEST_X's already-established 150.0 unit magnitude
                // (see that constant's own history above) -- a value already found usable in
                // this game for the same "visibly separate a test ghost from the player" purpose.
                //
                // Two genuinely different, both-valid loopback use cases, per the user
                // (2026-08-14): offset (this default) for visually judging rendering/animation
                // quality side by side, since an exact overlap makes the two impossible to tell
                // apart; zero offset for verifying the ghost actually tracks the real position
                // exactly, which an offset would obscure. Toggle by changing LOCAL_OFFSET_TEST_X
                // above to 0.0 -- deliberately a plain constant, not a runtime flag, since
                // -loopback itself is already a dev-only relay flag never meant to run in a real
                // session.
                static const std::string ghost_suffix = "-ghost";
                double loopback_offset_x = 0.0;
                if (player_id.size() >= ghost_suffix.size() &&
                    player_id.compare(player_id.size() - ghost_suffix.size(), ghost_suffix.size(), ghost_suffix) == 0)
                {
                    loopback_offset_x = LOCAL_OFFSET_TEST_X;
                }
                it->second.target_x = x + loopback_offset_x;
                it->second.target_y = y;
                it->second.target_z = z;
                it->second.target_pitch = pitch;
                it->second.target_yaw = yaw;
                it->second.target_roll = roll;
                it->second.target_move_state = move_state;
                it->second.target_action_state = action_state;
                it->second.target_h_speed = h_speed;
                it->second.target_v_speed = v_speed;
                it->second.target_anim_jump_type = anim_jump_type;
                it->second.target_movement_mode = movement_mode;
                it->second.target_land_count = land_count;
                it->second.target_jump_count = jump_count;
                if (is_new_remote)
                {
                    // Baseline last_seen_* to this first sample -- found in a review pass.
                    // RemoteGhost's default member initializers leave last_seen_land_count/
                    // last_seen_jump_count at 0, so a peer that joins mid-session with an
                    // already-nonzero land/jump count (they landed or jumped several times
                    // before this ghost even existed) would otherwise have
                    // target_land_count > last_seen_land_count on the very next redraw tick,
                    // firing a spurious landing/jump pulse (and the Montage_Stop it drives) the
                    // instant the ghost spawns, before the peer has actually done anything new.
                    it->second.last_seen_land_count = land_count;
                    it->second.last_seen_jump_count = jump_count;
                }
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
            FRotator pawn_rot = pawn->K2_GetActorRotation();
            current_world = static_cast<UWorld*>(pawn->GetWorld());

            // Bug found immediately, 2026-08-13: this path bypasses game_thread_tick's normal
            // body entirely (LOCAL_OFFSET_TEST_MODE's own early return), which is the only place
            // ticks_since_pawn_valid is normally incremented -- ensure_ghost_spawned's
            // SPAWN_DELAY_TICKS gate never passed, so no ghost was ever spawning in this mode.
            // Mirrors the same class_looks_like_player-gated increment used there.
            if (class_looks_like_player(pawn_obj))
            {
                ++ticks_since_pawn_valid;
            }
            else
            {
                ticks_since_pawn_valid = 0;
            }

            // User-requested 2026-08-13: wired to the same spawn-based ghost mechanism as the
            // real networked path (handle_bridge_line's identical if constexpr), so the
            // facing-direction bug can be reproduced with a single game instance and no relay/
            // core/bridge processes running, ruling networking out as a variable entirely. Before
            // this change, LOCAL_OFFSET_TEST_MODE always hijacked an existing level actor instead
            // -- a structurally different ghost that never exercised SpawnActor at all, so it
            // couldn't have reproduced this bug regardless of networking.
            if constexpr (SPAWN_BASED_GHOSTS)
            {
                ensure_ghost_spawned(LOCAL_OFFSET_TEST_ID, pawn_obj, controller);
            }
            else
            {
                ensure_ghost_hijacked(LOCAL_OFFSET_TEST_ID, pawn_obj);
            }
            auto it = remotes.find(LOCAL_OFFSET_TEST_ID);
            if (it != remotes.end())
            {
                it->second.target_x = pawn_loc.X() + LOCAL_OFFSET_TEST_X;
                it->second.target_y = pawn_loc.Y();
                it->second.target_z = pawn_loc.Z();
                it->second.target_pitch = pawn_rot.GetPitch();
                if constexpr (FORCE_ROTATION_CYCLE_TEST)
                {
                    // Cycles 0 -> 90 -> 180 -> 270 -> 0 ... on a fixed timer, independent of the
                    // real player's own facing -- see the constant's own comment.
                    constexpr double CYCLE_YAWS[] = {0.0, 90.0, 180.0, 270.0};
                    size_t cycle_index = (tick_count / ROTATION_CYCLE_TICKS) % 4;
                    if (tick_count % ROTATION_CYCLE_TICKS == 0)
                    {
                        Output::send(STR("[MeshGhostPseudo] (local-test) forcing ghost yaw to {}\n"), CYCLE_YAWS[cycle_index]);
                    }
                    it->second.target_yaw = CYCLE_YAWS[cycle_index];
                }
                else
                {
                    // Mirror real rotation -- the original offset-only test never set this at all
                    // (didn't need to, before facing was in scope).
                    it->second.target_yaw = pawn_rot.GetYaw();
                }
                it->second.target_roll = pawn_rot.GetRoll();
            }
        }

        for (auto& [id, remote] : remotes)
        {
            if (!remote.ghost)
            {
                continue;
            }
            if (current_world && remote.owning_world && remote.owning_world != current_world)
            {
                Output::send(STR("[MeshGhostPseudo] (local-test) remote {} ghost's world changed -- releasing stale reference, will hijack fresh.\n"), to_wide_ascii(id));
                hijacked_actors.erase(remote.ghost);
                remote.ghost = nullptr;
                remote.owning_world = nullptr;
                continue;
            }
            FVector target_loc(remote.target_x, remote.target_y, remote.target_z);
            FRotator target_rot(remote.target_pitch, remote.target_yaw, remote.target_roll);
            // Facing-direction root cause fix, 2026-08-13: the three writes this used to stack
            // (K2_SetActorLocationAndRotation, K2_SetActorRotation, a direct RelativeRotation
            // property poke plus a bHiddenInGame render-nudge) were all working around the same
            // single bug -- the vendored SDK's native rotator marshaling truncates to float on a
            // double-FRotator (UE5) engine. See call_set_actor_location_and_rotation's own comment
            // for the full root cause. One correct call replaces all of that.
            call_set_actor_location_and_rotation(remote.ghost, target_loc, target_rot);

            // Fine-grained bisection for the first 15 ticks after spawn -- see
            // RemoteGhost::ticks_since_spawn's comment. Logs every tick instead of only every
            // LOG_INTERVAL_TICKS (~2s), to find out exactly when (if at all, this early)
            // rotation readback goes from correct to garbage.
            ++remote.ticks_since_spawn;
            if (remote.ticks_since_spawn <= 15)
            {
                double reflected_yaw_early = -9999.0;
                if (UObject** early_capsule_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); early_capsule_ptr && *early_capsule_ptr)
                {
                    if (FRotator* early_rot = (*early_capsule_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
                    {
                        reflected_yaw_early = early_rot->GetYaw();
                    }
                }
                Output::send(STR("[MeshGhostPseudo] (local-test) EARLY remote {} tick {} since spawn: reflected_yaw={}\n"),
                             to_wide_ascii(id),
                             remote.ticks_since_spawn,
                             reflected_yaw_early);
            }

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

                // Same rotation trace as game_thread_tick's real networked path, for a true
                // no-networking repro of the facing-direction investigation.
                FRotator actual_rot = remote.ghost->K2_GetActorRotation();
                double reflected_yaw = -9999.0;
                if (UObject** g_capsule_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); g_capsule_ptr && *g_capsule_ptr)
                {
                    if (FRotator* g_relative_rot = (*g_capsule_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
                    {
                        reflected_yaw = g_relative_rot->GetYaw();
                    }
                }
                Output::send(STR("[MeshGhostPseudo] (local-test) TRACE remote {} yaw: sent={} K2_actual={} reflected_actual={}\n"),
                             to_wide_ascii(id),
                             target_rot.GetYaw(),
                             actual_rot.GetYaw(),
                             reflected_yaw);

                bool* hidden_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<bool>(STR("bHidden"));
                if (hidden_ptr)
                {
                    *hidden_ptr = true;
                    *hidden_ptr = false;
                }
            }
        }
    }

    // See declaration comment in Plugin.hpp. Uses the real native reflection API
    // (TFieldRange<FProperty>, RE-UE4SS/deps/first/Unreal/include/.../UnrealType.hpp:3117 defines
    // the template; usage grounded against RE-UE4SS/UE4SS/src/GUI/Dumpers.cpp:412, which iterates
    // a live UObject's class the same way for its own property-value dumper), not the Lua-exposed
    // UStruct:ForEachProperty binding -- that binding is confirmed missing on this exact installed
    // build (v3.0.1 Beta, SHA 733e5969; see phase7.md's BP_PlayerCam_C investigation, "attempt to
    // call a nil value" on every call). This walks real UStruct::ChildProperties memory directly,
    // via our own statically-linked, version-matched copy of the reflection code, so it isn't
    // subject to that gap.
    auto Plugin::log_pawn_reflection_once(AActor* pawn) -> void
    {
        if (pawn_reflection_logged || !pawn)
        {
            return;
        }
        pawn_reflection_logged = true;

        UClass* pawn_class = pawn->GetClassPrivate();
        if (!pawn_class)
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: local pawn has no class, cannot reflect.\n"));
            return;
        }

        Output::send(STR("[MeshGhostPseudo] DIAG: reflecting local pawn class {}\n"), pawn_class->GetFullName());
        for (FProperty* property : TFieldRange<FProperty>(pawn_class, EFieldIterationFlags::Default))
        {
            if (!property)
            {
                continue;
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: property '{}' ({})\n"), property->GetName(), property->GetClass().GetName());
        }
        Output::send(STR("[MeshGhostPseudo] DIAG: end of pawn reflection dump.\n"));

        // Follow-up per user request: animBPref looked like the pawn's reference to its own anim
        // Blueprint instance -- confirm what class it actually points to (and what fields THAT
        // class exposes) before assuming moveState/actionState/horizontalSpeed/verticalSpeed on
        // the pawn are really what drives it, rather than something else entirely.
        UObject** anim_bp_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref"));
        if (!anim_bp_ptr || !*anim_bp_ptr)
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: animBPref is null or property not found on the pawn instance.\n"));
            return;
        }
        UObject* anim_bp = *anim_bp_ptr;
        UClass* anim_bp_class = anim_bp->GetClassPrivate();
        if (!anim_bp_class)
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: animBPref value has no class.\n"));
            return;
        }
        Output::send(STR("[MeshGhostPseudo] DIAG: animBPref points to instance '{}' of class {}\n"),
                     anim_bp->GetFullName(),
                     anim_bp_class->GetFullName());
        for (FProperty* property : TFieldRange<FProperty>(anim_bp_class, EFieldIterationFlags::Default))
        {
            if (!property)
            {
                continue;
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: animBPref property '{}' ({})\n"), property->GetName(), property->GetClass().GetName());
        }
        Output::send(STR("[MeshGhostPseudo] DIAG: end of animBPref reflection dump.\n"));

        // Follow-up, 2026-08-13 (ledge-hang-stuck-forever investigation): the landed?/jumped?
        // pulse fix (see PULSE_HOLD_TICKS's comment) provably resets moveState/actionState/
        // movementMode correctly on the ghost within ~1s of a real landing -- confirmed via a live
        // TRACE remote readback -- yet the user reports the ghost stays frozen in the ledge-hang
        // POSE indefinitely regardless of any later jump/slide/land on the real player's side. A
        // pose that survives every state-machine byte resetting correctly is the signature of an
        // Anim Montage (played once via a "Play Anim Montage" node and independent of the state
        // machine's own Move State variable) rather than a state-machine transition -- consistent
        // with OnMontageStarted/OnMontageEnded/ActiveAnimNotifyState already showing up in the
        // animBPref property dump above. Per CLAUDE.md, no UFunction name gets called here on a
        // guess -- enumerating every real UFunction on animBPref's class chain (the same
        // TFieldRange pattern already used for FProperty above, just over UFunction instead) so
        // whatever the real montage-stop entry point is called on THIS build gets read off the
        // engine, not assumed from general Unreal Engine knowledge.
        Output::send(STR("[MeshGhostPseudo] DIAG: enumerating animBPref UFunctions...\n"));
        for (UFunction* function : TFieldRange<UFunction>(anim_bp_class, EFieldIterationFlags::Default))
        {
            if (!function)
            {
                continue;
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: animBPref function '{}' PropertiesSize={}\n"),
                         function->GetName(),
                         function->GetPropertiesSize());
        }
        Output::send(STR("[MeshGhostPseudo] DIAG: end of animBPref UFunction dump.\n"));

        // Follow-up, same investigation: Montage_Stop's real parameter NAMES, not assumed from
        // general Unreal Engine knowledge -- PropertiesSize=16 is consistent with a (float, object
        // pointer) pair, but per CLAUDE.md that consistency is not confirmation. Same FProperty/
        // GetOffset_Internal pattern already used to safely call
        // call_set_actor_location_and_rotation/call_set_collision_response_to_channel -- read-only
        // here, no call made yet.
        if (UFunction* montage_stop_fn = anim_bp->GetFunctionByNameInChain(STR("Montage_Stop")))
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: Montage_Stop real signature (PropertiesSize={}):\n"), montage_stop_fn->GetPropertiesSize());
            for (FProperty* property : TFieldRange<FProperty>(montage_stop_fn, EFieldIterationFlags::None))
            {
                if (!property)
                {
                    continue;
                }
                Output::send(STR("[MeshGhostPseudo] DIAG: Montage_Stop param '{}' ({}) offset={}\n"),
                             property->GetName(),
                             property->GetClass().GetName(),
                             property->GetOffset_Internal());
            }
        }
        else
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: Montage_Stop not found via GetFunctionByNameInChain (unexpected -- was listed in the UFunction enumeration above).\n"));
        }

        // Follow-up, 2026-08-13: user reports the spawned ghost gets stuck in a "flying"/airborne
        // idle pose after jumping (a slide forcibly resets it back to grounded). Leading theory:
        // the ghost's SetActorEnableCollision(false) (ensure_ghost_spawned, added deliberately so
        // the ghost never physically pushes/blocks the real player) means its own real
        // CharacterMovementComponent can never detect ground contact -- if the AnimBP's
        // fall-to-land transition reads that component's real grounded state directly (separate
        // from the moveState byte we already mirror), it would get stuck exactly this way. Confirm
        // the component and its real property names before assuming this rather than guessing at
        // a property name to poke.
        UObject** movement_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("CharacterMovement"));
        if (!movement_ptr || !*movement_ptr)
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: CharacterMovement is null or property not found on the pawn instance.\n"));
            return;
        }
        UObject* movement = *movement_ptr;
        UClass* movement_class = movement->GetClassPrivate();
        if (!movement_class)
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: CharacterMovement value has no class.\n"));
            return;
        }
        Output::send(STR("[MeshGhostPseudo] DIAG: CharacterMovement points to instance '{}' of class {}\n"),
                     movement->GetFullName(),
                     movement_class->GetFullName());
        for (FProperty* property : TFieldRange<FProperty>(movement_class, EFieldIterationFlags::Default))
        {
            if (!property)
            {
                continue;
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: CharacterMovement property '{}' ({})\n"), property->GetName(), property->GetClass().GetName());
        }
        Output::send(STR("[MeshGhostPseudo] DIAG: end of CharacterMovement reflection dump.\n"));

        // Follow-up, 2026-08-13: user asked how to make the ghost physically solid after the
        // collision test showed SetActorEnableCollision(true) let the ghost be hit/killed but did
        // NOT make it block the real player's movement. Standard UE mechanism: collision
        // enable/disable is separate from per-channel collision RESPONSE (Block/Overlap/Ignore) --
        // likely this class's capsule responds to the Pawn channel with Overlap, not Block, which
        // is why melee could hit it (an overlap query) but walking into it did nothing. Dumping
        // CapsuleComponent's own top-level properties to see what's actually configured before
        // guessing at a channel/response to change -- the detailed per-channel response data lives
        // inside BodyInstance (a UE-internal struct not exposed in this SDK's minimal headers), so
        // this may only get us part of the way; logged either way rather than assumed.
        UObject** capsule_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent"));
        if (!capsule_ptr || !*capsule_ptr)
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: CapsuleComponent is null or property not found on the pawn instance.\n"));
            return;
        }
        UObject* capsule = *capsule_ptr;
        UClass* capsule_class = capsule->GetClassPrivate();
        if (!capsule_class)
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: CapsuleComponent value has no class.\n"));
            return;
        }
        Output::send(STR("[MeshGhostPseudo] DIAG: CapsuleComponent points to instance '{}' of class {}\n"),
                     capsule->GetFullName(),
                     capsule_class->GetFullName());
        for (FProperty* property : TFieldRange<FProperty>(capsule_class, EFieldIterationFlags::Default))
        {
            if (!property)
            {
                continue;
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: CapsuleComponent property '{}' ({})\n"), property->GetName(), property->GetClass().GetName());
        }
        Output::send(STR("[MeshGhostPseudo] DIAG: end of CapsuleComponent reflection dump.\n"));

        // Follow-up, 2026-08-13: facing-direction investigation. The capsule's own RelativeRotation
        // read back as implausible garbage via two independent methods (K2_GetActorRotation() and
        // direct property reflection), while the ghost visually stays stable in one direction --
        // suggesting this game doesn't drive visual character facing through capsule/actor
        // rotation at all. `VisualMesh` (found in the top-level pawn property dump above) is the
        // likely candidate for wherever facing actually lives -- dumping its properties and, since
        // a scale-based left/right flip is a common pattern in games with wallRight?/leftAttack?-
        // style directional properties (already seen on the pawn), also printing its actual
        // RelativeRotation and RelativeScale3D values directly, not just names.
        UObject** visual_mesh_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh"));
        if (!visual_mesh_ptr || !*visual_mesh_ptr)
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: VisualMesh is null or property not found on the pawn instance.\n"));
            return;
        }
        UObject* visual_mesh = *visual_mesh_ptr;
        UClass* visual_mesh_class = visual_mesh->GetClassPrivate();
        if (!visual_mesh_class)
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: VisualMesh value has no class.\n"));
            return;
        }
        Output::send(STR("[MeshGhostPseudo] DIAG: VisualMesh points to instance '{}' of class {}\n"),
                     visual_mesh->GetFullName(),
                     visual_mesh_class->GetFullName());
        for (FProperty* property : TFieldRange<FProperty>(visual_mesh_class, EFieldIterationFlags::Default))
        {
            if (!property)
            {
                continue;
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: VisualMesh property '{}' ({})\n"), property->GetName(), property->GetClass().GetName());
        }
        if (FRotator* vm_rot = visual_mesh->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: VisualMesh RelativeRotation = (pitch={}, yaw={}, roll={})\n"),
                         vm_rot->GetPitch(), vm_rot->GetYaw(), vm_rot->GetRoll());
        }
        if (FVector* vm_scale = visual_mesh->GetValuePtrByPropertyNameInChain<FVector>(STR("RelativeScale3D")))
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: VisualMesh RelativeScale3D = (x={}, y={}, z={})\n"),
                         vm_scale->X(), vm_scale->Y(), vm_scale->Z());
        }
        Output::send(STR("[MeshGhostPseudo] DIAG: end of VisualMesh reflection dump.\n"));
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

        // Populated below whenever the local pawn/world resolve this tick; used as the cheaper of
        // the two staleness checks below (owning_world has since been torn down, e.g. the local
        // player transitioned areas) -- a dangling pointer into a torn-down world must not be
        // dereferenced.
        UWorld* current_world = nullptr;

        auto [controller, pawn_obj] = find_local_controller_and_pawn();
        if (controller && pawn_obj)
        {
            // Bug found live 2026-08-13: this must only count while possessing the REAL player
            // pawn. The title screen's own DefaultPawn is a valid controller+pawn pair too and
            // sits there for several real seconds before "Start" -- counting from any valid pawn
            // meant the delay had already elapsed by the time real gameplay began, confirmed by
            // the log ("local world changed: pawn=BP_PlayerGoatMain_C" and "spawned ghost" firing
            // at the same timestamp, not ~5s apart).
            if (class_looks_like_player(pawn_obj))
            {
                ++ticks_since_pawn_valid;
                log_pawn_reflection_once(static_cast<AActor*>(pawn_obj));
            }
            else
            {
                ticks_since_pawn_valid = 0;
            }
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

            // Real animation state (see verified.md's "ghost animation" entry): read straight off
            // the fields the pawn's own ABP_PlayerGoat_C anim instance mirrors every tick,
            // confirmed by name via the read-only reflection dump (log_pawn_reflection_once).
            // "anim" itself stays the 7.3 placeholder -- this data travels via "extras" instead
            // (Extras is the established opaque-structured-data field, e.g. Emerald's
            // extras.gender, so no core/protocol change is needed).
            uint8_t* move_state_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("moveState"));
            uint8_t* action_state_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("actionState"));
            double* h_speed_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("horizontalSpeed"));
            double* v_speed_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("verticalSpeed"));
            uint8_t* anim_jump_type_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("animJumpType"));

            // "Stuck flying after jump" fix (see RemoteGhost::target_movement_mode's comment):
            // also mirror the real CharacterMovementComponent's own MovementMode byte, confirmed
            // via reflection to be a real property on this build's stock component.
            uint8_t movement_mode = 0;
            bool orient_rotation_to_movement = false;
            if (UObject** movement_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("CharacterMovement")); movement_ptr && *movement_ptr)
            {
                if (uint8_t* movement_mode_ptr = (*movement_ptr)->GetValuePtrByPropertyNameInChain<uint8_t>(STR("MovementMode")))
                {
                    movement_mode = *movement_mode_ptr;
                }
                // Facing-direction investigation, 2026-08-13: if this is true, the ghost's own
                // CharacterMovementComponent may re-derive rotation from its own (near-zero, since
                // it's teleported not driven by real input) internal velocity every tick, fighting
                // our explicit K2_SetActorLocationAndRotation yaw write -- confirmed as a real
                // property via reflection (log_pawn_reflection_once's CharacterMovement dump), not
                // guessed at. Checking the real player's own value here, not yet acted on.
                if (bool* orient_ptr = (*movement_ptr)->GetValuePtrByPropertyNameInChain<bool>(STR("bOrientRotationToMovement")))
                {
                    orient_rotation_to_movement = *orient_ptr;
                }
            }

            // Redone landed?/jumped? pulse mirror (see PULSE_HOLD_TICKS's comment): these live on
            // animBPref, not the pawn -- read_animbp_bool does the extra hop. Edge-detected against
            // the previous tick's raw value so a pulse held true for more than one tick (plausible
            // at 60Hz) is still counted once per real landing/jump, not once per tick it reads true.
            bool landed_now = read_animbp_bool(pawn, STR("landed?"));
            bool jumped_now = read_animbp_bool(pawn, STR("jumped?"));
            if (landed_now && !prev_landed_raw)
            {
                ++landed_count;
            }
            if (jumped_now && !prev_jumped_raw)
            {
                ++jumped_count;
            }
            prev_landed_raw = landed_now;
            prev_jumped_raw = jumped_now;

            // Dense every-tick trace for this investigation -- LOG_INTERVAL_TICKS (~2s) cannot see
            // a one-frame AnimBP pulse. Gated on "airborne or a pulse fired this tick" so a full
            // jump/land or grab/release cycle is readable without flooding the log at 60Hz while
            // grounded and idle. See ANIM_PULSE_TRACE's own comment.
            if constexpr (ANIM_PULSE_TRACE)
            {
                if (movement_mode != 1 || landed_now || jumped_now)
                {
                    uint8_t* prev_move_state_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("previousMoveState"));
                    uint8_t* prev_action_state_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("previousActionState"));
                    double* move_uptime_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("moveStateUptime"));
                    double* action_uptime_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("actionStateUptime"));
                    uint8_t* control_state_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("controlState"));
                    Output::send(STR("[MeshGhostPseudo] PULSE local: moveState={} prevMoveState={} actionState={} prevActionState={} moveUptime={} actionUptime={} controlState={} movementMode={} landed={} jumped={} landed_count={} jumped_count={}\n"),
                                 move_state_ptr ? static_cast<int>(*move_state_ptr) : -1,
                                 prev_move_state_ptr ? static_cast<int>(*prev_move_state_ptr) : -1,
                                 action_state_ptr ? static_cast<int>(*action_state_ptr) : -1,
                                 prev_action_state_ptr ? static_cast<int>(*prev_action_state_ptr) : -1,
                                 move_uptime_ptr ? *move_uptime_ptr : -1.0,
                                 action_uptime_ptr ? *action_uptime_ptr : -1.0,
                                 control_state_ptr ? static_cast<int>(*control_state_ptr) : -1,
                                 static_cast<int>(movement_mode),
                                 landed_now,
                                 jumped_now,
                                 landed_count,
                                 jumped_count);
                }
            }

            // Live trace for the "stuck flying after jump, slide resets it" investigation --
            // reusing the existing ~2s log cadence (LOG_INTERVAL_TICKS) so this can run through a
            // full jump/stuck/slide/recovered cycle without flooding the log.
            if (tick_count % LOG_INTERVAL_TICKS == 0)
            {
                Output::send(STR("[MeshGhostPseudo] TRACE local: moveState={} actionState={} hSpeed={} vSpeed={} animJumpType={} movementMode={} landed={} jumped={} yaw={} bOrientRotationToMovement={}\n"),
                             move_state_ptr ? static_cast<int>(*move_state_ptr) : -1,
                             action_state_ptr ? static_cast<int>(*action_state_ptr) : -1,
                             h_speed_ptr ? *h_speed_ptr : -1.0,
                             v_speed_ptr ? *v_speed_ptr : -1.0,
                             anim_jump_type_ptr ? static_cast<int>(*anim_jump_type_ptr) : -1,
                             static_cast<int>(movement_mode),
                             landed_now,
                             jumped_now,
                             rotation.GetYaw(),
                             orient_rotation_to_movement);

                // Facing-direction investigation, continued: is VisualMesh's own
                // RelativeRotation/RelativeScale3D what actually changes when the real player
                // turns around? The one-shot dump caught only a single snapshot (yaw=-90,
                // scale=(1,1,1)) -- logging on the existing trace cadence to see it live across a
                // real turn.
                if (UObject** vm_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh")); vm_ptr && *vm_ptr)
                {
                    FRotator* vm_rot = (*vm_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation"));
                    FVector* vm_scale = (*vm_ptr)->GetValuePtrByPropertyNameInChain<FVector>(STR("RelativeScale3D"));
                    Output::send(STR("[MeshGhostPseudo] TRACE local VisualMesh: rot=(pitch={},yaw={},roll={}) scale=(x={},y={},z={})\n"),
                                 vm_rot ? vm_rot->GetPitch() : -9999.0,
                                 vm_rot ? vm_rot->GetYaw() : -9999.0,
                                 vm_rot ? vm_rot->GetRoll() : -9999.0,
                                 vm_scale ? vm_scale->X() : -9999.0,
                                 vm_scale ? vm_scale->Y() : -9999.0,
                                 vm_scale ? vm_scale->Z() : -9999.0);
                }
                // Missing cross-check: does the REAL PLAYER's own capsule RelativeRotation change
                // correctly with turning? Only the ghost's capsule rotation was ever confirmed
                // garbage so far -- if the real player's own capsule rotation tracks turning
                // correctly here, that means capsule rotation really is the right mechanism and
                // the bug is specific to the ghost (fixable), not a wrong theory about how this
                // game drives facing at all.
                if (UObject** cap_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); cap_ptr && *cap_ptr)
                {
                    if (FRotator* cap_rot = (*cap_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE local CapsuleComponent RelativeRotation: pitch={} yaw={} roll={}\n"),
                                     cap_rot->GetPitch(), cap_rot->GetYaw(), cap_rot->GetRoll());
                    }
                    else
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE local CapsuleComponent RelativeRotation: property not found.\n"));
                    }
                }
            }

            // landed_count/jumped_count are monotonic (see Plugin.hpp's comment on them), so unlike
            // the old bool latch, no clear-after-send handoff step is needed -- whatever value is
            // baked into this tick's JSON is simply the count as of this tick; on_update no longer
            // needs to touch these members at all.
            //
            // std::format runs unlocked -- found in a review pass: it's a pure computation with
            // no access to any state on_update's thread also touches, so holding state_mutex
            // across it (as this used to) only needlessly extended the critical section against
            // that other thread for no correctness benefit. Only the final assignment into
            // cached_local_state_json, which on_update does read, needs the lock.
            std::string local_state = std::format(
                "{{\"type\":\"local_state\",\"payload\":{{\"state\":{{\"area_id\":\"{}\",\"position\":[{},{},{}],"
                "\"orientation\":[{},{},{}],\"anim\":\"idle\","
                "\"extras\":{{\"move_state\":{},\"action_state\":{},\"h_speed\":{},\"v_speed\":{},\"anim_jump_type\":{},\"movement_mode\":{},"
                "\"land_count\":{},\"jump_count\":{}}}"
                "}}}}}}",
                json_escape(area_id),
                location.X(),
                location.Y(),
                location.Z(),
                rotation.GetPitch(),
                rotation.GetYaw(),
                rotation.GetRoll(),
                move_state_ptr ? static_cast<int>(*move_state_ptr) : 0,
                action_state_ptr ? static_cast<int>(*action_state_ptr) : 0,
                h_speed_ptr ? *h_speed_ptr : 0.0,
                v_speed_ptr ? *v_speed_ptr : 0.0,
                anim_jump_type_ptr ? static_cast<int>(*anim_jump_type_ptr) : 0,
                static_cast<int>(movement_mode),
                landed_count,
                jumped_count);
            {
                std::lock_guard<std::mutex> lock(state_mutex);
                cached_local_state_json = std::move(local_state);
            }
        }
        else
        {
            ticks_since_pawn_valid = 0; // e.g. back at the title screen -- re-arm the spawn delay
            std::lock_guard<std::mutex> lock(state_mutex);
            cached_local_state_json = R"({"type":"local_state","payload":{"state":null}})";
        }

        std::vector<std::string> lines_to_process;
        bool disconnect_cleanup_pending = false;
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            lines_to_process.swap(pending_incoming_lines);
            disconnect_cleanup_pending = bridge_disconnect_cleanup_pending;
            bridge_disconnect_cleanup_pending = false;
        }
        for (const std::string& line : lines_to_process)
        {
            handle_bridge_line(line, pawn_obj, controller);
        }
        if (disconnect_cleanup_pending)
        {
            release_all_ghosts_parked(STR("bridge disconnected"));
        }

        // Redraw every currently-known remote unconditionally, every tick -- per PROTOCOL.md,
        // not only on ticks where new network data arrived.
        for (auto& [id, remote] : remotes)
        {
            if (!remote.ghost)
            {
                continue;
            }
            // Staleness check, ported from Lua's per-tick `not remote.ghost:IsValid()` poll
            // (probe_ghost/Scripts/main.lua:787-794). See actor_is_alive's own comment for why
            // this is IsValid()'s real C++ equivalent, not a guess.
            //
            // Reviewed for the same cached-raw-pointer risk that caused the real, confirmed
            // last_known_good_view_target crash (see the LoadMap PRE hook's comment): calling
            // ->IsUnreachable() on a raw AActor* is only safe if the object is merely GC-
            // unreachable-but-still-allocated, not if its memory has actually been freed already.
            // For the one destruction path this codebase has ever actually observed -- a level
            // transition -- that's covered proactively, not reactively: release_all_ghosts fires
            // in the very same LoadMap PRE hook (before the transition proceeds) and nulls
            // remote.ghost there, so by the time this line would run afterward, `if (!remote.ghost)
            // continue;` above has already skipped it; this check never sees a LoadMap-transition-
            // freed pointer at all. This line remains as a defensive second layer for any actor
            // destruction that *doesn't* route through UEngine::LoadMap (a streaming sub-level
            // unload, EndPlay-driven destruction, unrelated GC) -- genuinely possible, but not a
            // path this project has ever reproduced a crash through, unlike the LoadMap one. Not
            // hardened further pending an actual reproduction, per CLAUDE.md's "no addresses/fixes
            // from memory" standard applied to speculative crash fixes: a change here carries real
            // risk in a file with a proven crash history from exactly this class of edit.
            if (!actor_is_alive(remote.ghost))
            {
                Output::send(STR("[MeshGhostPseudo] remote {} ghost is no longer valid (level transition) -- releasing stale reference, will respawn fresh.\n"),
                             to_wide_ascii(id));
                hijacked_actors.erase(remote.ghost);
                remote.ghost = nullptr;
                remote.owning_world = nullptr;
                continue;
            }
            // Cheaper secondary check: only meaningful once current_world has actually resolved
            // this tick (it's null on ticks where the local pawn/controller aren't found, e.g.
            // mid-transition -- don't treat that as "the world changed", just skip the check).
            if (current_world && remote.owning_world && remote.owning_world != current_world)
            {
                Output::send(STR("[MeshGhostPseudo] remote {} ghost's world changed (local player transitioned) -- releasing stale reference, will respawn fresh.\n"),
                             to_wide_ascii(id));
                hijacked_actors.erase(remote.ghost);
                remote.ghost = nullptr;
                remote.owning_world = nullptr;
                continue;
            }
            FVector target_loc(remote.target_x, remote.target_y, remote.target_z);
            FRotator target_rot(remote.target_pitch, remote.target_yaw, remote.target_roll);
            // Facing-direction root cause fix, 2026-08-13: the real bug was never bTeleport --
            // it was the vendored SDK's K2_SetActorLocationAndRotation marshaling FRotator's
            // Pitch/Yaw/Roll as hardcoded float into a double-sized slot on this UE5 game (see
            // call_set_actor_location_and_rotation's comment for the full root cause). bTeleport
            // is still true here, matching the local-test path and the "this is a teleport, not a
            // physics move" reasoning below -- just no longer the fix itself.
            call_set_actor_location_and_rotation(remote.ghost, target_loc, target_rot);

            // Ghost animation (see verified.md's "ghost animation" entry): the ghost is a full
            // spawned clone of the same BP_PlayerGoatMain_C class, so it has its own
            // moveState/actionState/horizontalSpeed/verticalSpeed/animJumpType and its own
            // already-attached ABP_PlayerGoat_C anim instance mirroring them every tick, same as
            // the real player. Writing the real player's values onto the ghost's copies each tick
            // should make the ghost's anim instance drive itself the same way -- no direct AnimBP
            // writes needed. No-ops safely (nullptr checks) in hijack mode, where the ghost is a
            // StaticMeshActor with no such properties.
            if (uint8_t* g_move_state = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("moveState")))
            {
                *g_move_state = clamp_to_uint8(remote.target_move_state);
            }
            if (uint8_t* g_action_state = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("actionState")))
            {
                *g_action_state = clamp_to_uint8(remote.target_action_state);
            }
            if (double* g_h_speed = remote.ghost->GetValuePtrByPropertyNameInChain<double>(STR("horizontalSpeed")))
            {
                *g_h_speed = remote.target_h_speed;
            }
            if (double* g_v_speed = remote.ghost->GetValuePtrByPropertyNameInChain<double>(STR("verticalSpeed")))
            {
                *g_v_speed = remote.target_v_speed;
            }
            if (uint8_t* g_anim_jump_type = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("animJumpType")))
            {
                *g_anim_jump_type = clamp_to_uint8(remote.target_anim_jump_type);
            }
            // "Stuck flying after jump" fix -- see RemoteGhost::target_movement_mode's comment.
            if (UObject** g_movement_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CharacterMovement")); g_movement_ptr && *g_movement_ptr)
            {
                if (uint8_t* g_movement_mode = (*g_movement_ptr)->GetValuePtrByPropertyNameInChain<uint8_t>(STR("MovementMode")))
                {
                    *g_movement_mode = clamp_to_uint8(remote.target_movement_mode);
                }
            }
            // Redone landed?/jumped? pulse mirror (see PULSE_HOLD_TICKS's comment): a rising edge
            // in the received counter arms a hold window, decremented every tick regardless of
            // whether a new render_remote line arrived this tick (this loop runs unconditionally
            // per PROTOCOL.md), and write_animbp_bool targets the ghost's own animBPref -- the
            // object these fields actually live on, unlike every other field mirrored above.
            bool land_edge = remote.target_land_count > remote.last_seen_land_count;
            bool jump_edge = remote.target_jump_count > remote.last_seen_jump_count;
            if (land_edge)
            {
                remote.last_seen_land_count = remote.target_land_count;
                remote.landed_hold_ticks = PULSE_HOLD_TICKS;
            }
            if (jump_edge)
            {
                remote.last_seen_jump_count = remote.target_jump_count;
                remote.jumped_hold_ticks = PULSE_HOLD_TICKS;
            }
            bool write_landed = remote.landed_hold_ticks > 0;
            bool write_jumped = remote.jumped_hold_ticks > 0;
            write_animbp_bool(remote.ghost, STR("landed?"), write_landed);
            write_animbp_bool(remote.ghost, STR("jumped?"), write_jumped);
            if (remote.landed_hold_ticks > 0)
            {
                --remote.landed_hold_ticks;
            }
            if (remote.jumped_hold_ticks > 0)
            {
                --remote.jumped_hold_ticks;
            }

            // Ledge-hang-stuck-forever fix (see call_montage_stop's own comment for the full
            // theory and how Montage_Stop's real signature was confirmed): a land_edge or
            // jump_edge is exactly the moment the real player left whatever held pose they were
            // in (dropping off a ledge and touching ground fires a landed pulse; jumping off fires
            // a jumped pulse -- confirmed via the live trace of a real hang->release->land cycle),
            // so this is the right moment to force-stop any lingering montage on the ghost too,
            // not merely mirror the continuous state that a montage doesn't listen to anyway.
            if (land_edge || jump_edge)
            {
                if (UObject** g_abp_for_montage = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_for_montage && *g_abp_for_montage)
                {
                    // Blend-out tightened 2026-08-13 (user-confirmed live: the fix worked but the
                    // ghost held the hang pose a bit longer than the real player, on top of the
                    // ~100ms interpolation delay already inherent to the pipeline) -- 0.0s cuts
                    // instead of blending, closing the rest of the gap.
                    call_montage_stop(*g_abp_for_montage, 0.0f);
                    if constexpr (ANIM_PULSE_TRACE)
                    {
                        Output::send(STR("[MeshGhostPseudo] PULSE remote {}: called Montage_Stop (land_edge={} jump_edge={})\n"),
                                     to_wide_ascii(id),
                                     land_edge,
                                     jump_edge);
                    }
                }
            }

            if constexpr (ANIM_PULSE_TRACE)
            {
                if (write_landed || write_jumped || land_edge || jump_edge)
                {
                    // Readback immediately after the write above -- per CLAUDE.md, "it ran without
                    // errors" is not evidence the AnimBP's own update graph didn't immediately
                    // overwrite it before the next frame renders.
                    bool rb_landed = read_animbp_bool(remote.ghost, STR("landed?"));
                    bool rb_jumped = read_animbp_bool(remote.ghost, STR("jumped?"));
                    Output::send(STR("[MeshGhostPseudo] PULSE remote {}: land_count={} jump_count={} landed_hold={} jumped_hold={} wrote_landed={} wrote_jumped={} readback_landed={} readback_jumped={}\n"),
                                 to_wide_ascii(id),
                                 remote.target_land_count,
                                 remote.target_jump_count,
                                 remote.landed_hold_ticks,
                                 remote.jumped_hold_ticks,
                                 write_landed,
                                 write_jumped,
                                 rb_landed,
                                 rb_jumped);
                }
            }

            if (tick_count % LOG_INTERVAL_TICKS == 0)
            {
                // Read back what actually stuck on the ghost after our writes above, not just
                // what we intended to write -- "ran without errors" isn't evidence something took
                // effect, per CLAUDE.md.
                uint8_t* rb_move_state = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("moveState"));
                uint8_t* rb_action_state = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("actionState"));
                double* rb_v_speed = remote.ghost->GetValuePtrByPropertyNameInChain<double>(STR("verticalSpeed"));
                int rb_movement_mode = -1;
                if (UObject** rb_movement_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CharacterMovement")); rb_movement_ptr && *rb_movement_ptr)
                {
                    if (uint8_t* rb_movement_mode_ptr = (*rb_movement_ptr)->GetValuePtrByPropertyNameInChain<uint8_t>(STR("MovementMode")))
                    {
                        rb_movement_mode = static_cast<int>(*rb_movement_mode_ptr);
                    }
                }
                Output::send(STR("[MeshGhostPseudo] TRACE remote {}: sent moveState={} actionState={} vSpeed={} movementMode={} | readback moveState={} actionState={} vSpeed={} movementMode={}\n"),
                             to_wide_ascii(id),
                             static_cast<int>(remote.target_move_state),
                             static_cast<int>(remote.target_action_state),
                             remote.target_v_speed,
                             static_cast<int>(remote.target_movement_mode),
                             rb_move_state ? static_cast<int>(*rb_move_state) : -1,
                             rb_action_state ? static_cast<int>(*rb_action_state) : -1,
                             rb_v_speed ? *rb_v_speed : -1.0,
                             rb_movement_mode);

                FVector actual_loc = remote.ghost->K2_GetActorLocation();
                Output::send(STR("[MeshGhostPseudo] remote {} redraw: intended=({},{},{}) actual=({},{},{})\n"),
                             to_wide_ascii(id),
                             target_loc.X(),
                             target_loc.Y(),
                             target_loc.Z(),
                             actual_loc.X(),
                             actual_loc.Y(),
                             actual_loc.Z());

                // Facing-direction investigation, 2026-08-13: read back the ghost's actual yaw
                // after our K2_SetActorLocationAndRotation write, to see whether it's sticking or
                // being reverted (e.g. by the ghost's own CharacterMovementComponent, if
                // bOrientRotationToMovement is fighting it -- see the local-side TRACE log).
                FRotator actual_rot = remote.ghost->K2_GetActorRotation();
                // Cross-check via direct property reflection -- K2_GetActorRotation()'s own
                // readback came back as implausible garbage on a previous run despite
                // K2_GetActorLocation() on the same object working fine in the same call. This
                // retry's first version read via RootComponent and got the exact same garbage as
                // the native call, which (since the ghost visually looks stable, not glitching)
                // points at reading the wrong object rather than genuinely corrupt data --
                // RootComponent may not resolve reliably on a freshly spawned actor. Retrying via
                // CapsuleComponent instead, already proven reliable elsewhere in this file
                // (log_pawn_reflection_once's dump, the animation-state mirroring code).
                double reflected_yaw = -9999.0;
                if (UObject** g_capsule_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); g_capsule_ptr && *g_capsule_ptr)
                {
                    if (FRotator* g_relative_rot = (*g_capsule_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
                    {
                        reflected_yaw = g_relative_rot->GetYaw();
                    }
                }
                Output::send(STR("[MeshGhostPseudo] TRACE remote {} yaw: sent={} K2_actual={} reflected_actual={}\n"),
                             to_wide_ascii(id),
                             target_rot.GetYaw(),
                             actual_rot.GetYaw(),
                             reflected_yaw);

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

        bool now_connected = bridge->is_connected();
        if (bridge_was_connected && !now_connected)
        {
            // See release_all_ghosts_parked's comment -- the actual parking must happen on the
            // game thread, so this only arms the flag; game_thread_tick does the real work.
            std::lock_guard<std::mutex> lock(state_mutex);
            bridge_disconnect_cleanup_pending = true;
        }
        bridge_was_connected = now_connected;

        if (now_connected)
        {
            if (!bridge->hello_sent())
            {
                std::string hello = std::string("{\"type\":\"hello\",\"payload\":{\"game_id\":\"") + GAME_ID +
                    "\",\"game_version\":\"" + ADAPTER_VERSION + "\"}}";
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
