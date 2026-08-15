#pragma once

// Phase 7.2 hello-world UE4SS C++ mod. Not the real adapter -- proves a C++ mod can build
// against this machine's UE4SS v3.0.1 and load alongside the already-installed AP_Randomizer
// C++ mod (agent_docs/phases/phase7.md). CppUserModBase interface confirmed by reading
// UE4SS/include/Mod/CppUserModBase.hpp directly (RE-UE4SS, MIT -- agent_docs/licensing.md),
// not from memory. No pseudoregalia-archipelago source was read to write this.

#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <Mod/CppUserModBase.hpp>

namespace RC::Unreal
{
    class UObject;
    class AActor;
    class UWorld;
    class UFunction;
} // namespace RC::Unreal

namespace MeshGhostPseudo
{
    class BridgeClient;

    // One entry per remote player_id, driven entirely by render_remote/despawn_remote -- mirrors
    // the Lua adapter's `remotes` table (adapters/pseudoregalia/probe_ghost/Scripts/main.lua).
    //
    // Phase 7.6: the "no working destroy mechanism" verdict from the original "Fatal world leaks
    // detected" investigation (lowlevelfatalerror-file-d-build-ue5-sync-zazzy-star.md) was reached
    // entirely from calls made off the game thread (on_update(), UE4SS's own polling thread) --
    // discovered only afterwards, during the separate render-freeze investigation. The Lua
    // adapter, which DID spawn a clone of the player's pawn class successfully across real area
    // transitions, always made its spawn/reposition calls inside ExecuteInGameThread. Spawn-based
    // ghosts are back (see SPAWN_BASED_GHOSTS in Plugin.cpp) as a game-thread retest of that
    // verdict; the old hijack-an-existing-StaticMeshActor path (`ensure_ghost_hijacked`) is kept
    // intact as a one-constant revert if the leak reproduces.
    struct RemoteGhost
    {
        RC::Unreal::AActor* ghost{nullptr};
        RC::Unreal::UWorld* owning_world{nullptr}; // which UWorld `ghost` belongs to (spawned into, or hijacked from)
        double target_x{}, target_y{}, target_z{};
        double target_pitch{}, target_yaw{}, target_roll{};

        // Facing-direction bisection, 2026-08-13: rotation reads correct immediately after
        // SpawnActor and immediately after Possess() (same tick as spawn), but garbage by the
        // time the ~2s-interval TRACE log next reads it -- up to ~120 ticks of blind spot. Counts
        // redraw-loop ticks since this ghost was created so the first several can be logged
        // unconditionally, to find out whether corruption happens on the very next tick or later.
        uint32_t ticks_since_spawn{0};

        // Mirrors of the real player's own animation-driving state (see verified.md's "ghost
        // animation" entry) -- BP_PlayerGoatMain_C's ABP_PlayerGoat_C anim instance reads these
        // same fields (moveState/actionState/horizontalSpeed/verticalSpeed/animJumpType) off its
        // owning pawn every tick and mirrors them into its own locals, so writing them onto the
        // ghost's pawn each tick (game_thread_tick) makes the ghost's own already-attached anim
        // instance animate itself the same way for CONTINUOUS state. That reasoning does not hold
        // for landed?/jumped? below -- see target_land_count's comment.
        double target_move_state{}, target_action_state{}, target_h_speed{}, target_v_speed{}, target_anim_jump_type{};

        // Found live 2026-08-13: without this, the ghost gets stuck in an airborne/"flying" pose
        // after a jump (a slide forces a reset, since that's a different, non-grounded-gated
        // transition). Leading theory: the ghost's own real CharacterMovementComponent can never
        // detect ground contact (SetActorEnableCollision(false) in ensure_ghost_spawned, kept
        // deliberately so the ghost never physically pushes the real player), and at least one
        // AnimBP transition reads that component's real MovementMode directly rather than only
        // the moveState byte mirrored above. Confirmed via reflection dump that MovementMode is a
        // real, plain ByteProperty on the stock engine CharacterMovementComponent here (not a
        // custom subclass) -- mirrored the same opaque-copy way as moveState/actionState.
        double target_movement_mode{};

        // Dream Breaker (weapon) visibility mirror, added 2026-08-15 after a live-value trace
        // (verified.md's "Pseudoregalia ability field live-value trace" entry) confirmed
        // weaponEquipped?/animEquippedWeapon are CONTINUOUS "do you have the weapon" flags, not
        // one-shot pulses (591/616 samples true, never false again once obtained) -- same
        // opaque-copy shape as moveState/actionState above, not the landed?/jumped? pulse
        // pattern. Mirrors both the pawn-side and animBPref-side flag since the trace confirmed
        // both exist and move together but never confirmed which one (if either alone) actually
        // drives WeaponMesh's visibility -- cheap to write both, and this is the first real test
        // of whether either one does anything visible on the ghost at all.
        bool target_weapon_equipped{false};

        // Edge-detection for updateWeaponEquip (see call_update_weapon_equip's comment) -- that
        // function plausibly fires a one-shot montage each call, so it must only be called on a
        // real equip/unequip transition, not every redraw tick. weapon_equip_call_armed becomes
        // true the first time this ghost's real state is known, so the initial spawn state (the
        // ghost may spawn already equipped) is synced once without being treated as a spurious
        // "just equipped" transition on tick one.
        bool last_synced_weapon_equipped{false};
        bool weapon_equip_call_armed{false};

        // Outfit/costume mirror, added 2026-08-15 after a live value-diff straddling real costume
        // swaps (OUTFIT_TRACE, verified.md) found VisualMesh's own SkeletalMesh property directly
        // swaps to a different mesh asset per outfit -- unlike weapon, no boolean flag or animBPref
        // indirection at all. target_outfit_mesh holds the real object PATH (not the full
        // "ClassName Path" GetFullName() form -- see the local-read comment in tickRenders for
        // why); the ghost side resolves it via StaticFindObject and assigns directly to its own
        // VisualMesh.SkeletalMesh/SkinnedAsset. last_synced_outfit_mesh edge-gates the resolve/
        // assign so it only happens on an actual change, not every redraw tick.
        std::string target_outfit_mesh;
        std::string last_synced_outfit_mesh;

        // Retry throttle, found while reasoning about a peer using a modded outfit the receiving
        // machine doesn't have installed: without this, a StaticFindObject failure would retry
        // (and re-log a warning) every single tick forever, since target_outfit_mesh would never
        // equal last_synced_outfit_mesh. last_failed_outfit_mesh/last_outfit_attempt_tick throttle
        // retries of the SAME still-failing target to once per LOG_INTERVAL_TICKS, while a genuinely
        // NEW target (e.g. the peer swaps to a different outfit) still gets tried immediately.
        std::string last_failed_outfit_mesh;
        uint64_t last_outfit_attempt_tick{0};

        // Thrown Dream Breaker, added 2026-08-15 after the WEAPON_ACTOR_TRACE capture (see that
        // flag in Plugin.cpp, and verified.md). Everything else in this struct mirrors a state OF
        // the peer's character; this is the first thing that mirrors a SEPARATE world object.
        //
        // Measured lifecycle, which is what makes this tractable: a throw spawns a fresh
        // BP_looseWeapon_C actor and points the pawn's `weaponRef` at it; the actor flies a
        // ~2s ballistic arc under the engine's own ProjectileMovementComponent, bounces, comes to
        // rest, and on pickup is NOT destroyed but parked at world origin with `weaponRef` left
        // pointing at it. So "in hand" is the peer's own transform reading (0,0,0), and the whole
        // visual -- flight, wall bounces, resting pose -- is carried by position+rotation alone,
        // with no physics to reproduce on this side.
        //
        // weapon_actor is our own spawned copy, one per remote, reused across that peer's throws
        // and parked at DESPAWN_PARK_Z (never destroyed) whenever the peer's sword is in hand --
        // the same lifetime rule release_ghost applies to the ghost pawn itself, for the same
        // reason. Its collision is disabled at spawn: the real BP carries a `PlayerPickup` box,
        // so a collidable copy would let the local player walk into a peer's phantom sword and
        // actually pick it up, which is a game-state effect and outside this project's
        // visual-only posture.
        RC::Unreal::AActor* weapon_actor{nullptr};
        RC::Unreal::UWorld* weapon_actor_world{nullptr};
        bool target_weapon_thrown{false};
        std::string target_weapon_class;
        double target_weapon_x{}, target_weapon_y{}, target_weapon_z{};
        double target_weapon_pitch{}, target_weapon_yaw{}, target_weapon_roll{};

        // The peer's weaponState. Measured 2026-08-15: the real sword steps 0 -> 3 the moment it
        // lands, identically across five consecutive throws, and that state -- not any mesh offset
        // -- is what makes a landed sword read as resting on the floor rather than hanging in the
        // air. Our prop has collision off and is teleported rather than simulated, so it never
        // touches the ground and never runs the transition itself; mirroring the peer's value is
        // what stands in for the landing it never has.
        //
        // Edge-gated by last_synced_weapon_state, and for a sharper reason than saving work: the
        // Dream Breaker visibility bug was caused by calling a game transition function on every
        // tick, so by the time it ran on a real change its own "did this actually change?" check
        // saw nothing to do. Calling only on a real edge is the shape that fixed that.
        double target_weapon_state{};
        double last_synced_weapon_state{-1.0}; // -1 = nothing synced yet, outside any real state

        // The landed sword's glow ring. Sent as the NiagaraSystem asset's own object path, read off
        // the peer's real sword rather than hardcoded, so a build or mod with a different effect
        // still resolves. weapon_glow_component is our spawned copy: it lives and dies with the
        // prop (the prop is destroyed per throw), so it only needs clearing alongside it.
        std::string target_weapon_glow;
        RC::Unreal::UObject* weapon_glow_component{nullptr};

        // The empty-hand recall glow -- the white shimmer the real player shows while their sword
        // is thrown and recallable. Long listed as blocked (`status.md`), and it was never blocked
        // on finding a function: `manageRecallIdleFX` returned cleanly on a ghost and spawned
        // nothing, because its internal IsValid guards want state an unpossessed ghost lacks. It is
        // instead spawned directly, the same way the landed sword's ring is, which needs no guards
        // to pass. Gated purely on the peer's already-synced weaponEquipped? flag.
        RC::Unreal::UObject* recall_glow_component{nullptr};
        bool recall_glow_shown{false};
        // The peer's observed answer, not our recomputation of the game's rule -- see
        // RECALL_GLOW_ENABLED for why this is mirrored rather than derived.
        bool target_recall_glow{false};

        // One-shot: has this ghost been swept for a recall glow it built ITSELF at construction?
        // A ghost is a clone of the local player's own class reading the local save, so it can
        // spawn already glowing -- proven from timestamps, the ghost was glowing a full minute
        // before this adapter spawned any glow on it. Harmless-looking in loopback, where the peer
        // IS the local player, and wrong with a real peer: it would show the LOCAL player's state
        // on someone else's ghost, and nothing would ever clear it, since this adapter only tracks
        // the component it spawned itself.
        bool recall_glow_swept{false};

        // GHOST_SPAWN_WEAPON_TRACE bookkeeping: the tick this ghost spawned, and whether each of
        // the two samples has been taken. 0 = not spawned yet.
        uint64_t spawn_weapon_trace_tick{0};
        bool spawn_weapon_traced_at_spawn{false};
        bool spawn_weapon_traced_after{false};

        // Smoothed render position for the above. Needed because `extras` is NOT interpolated by
        // the core -- internal/core/interp.go interpolates `position` only and holds every extras
        // field from the older bracketing snapshot -- so these targets arrive in 20Hz steps while
        // the redraw loop runs at ~150Hz. Replaying them raw would render the measured smooth arc
        // as a visible ~15-unit-per-step stutter. Exponential smoothing toward the target is used
        // rather than a second interpolation buffer, deliberately: a real buffer here would be
        // duplicating the core's one genuinely reusable hard part into an adapter, which is the
        // exact leak agent_docs/contract.md's tick model exists to prevent.
        double render_weapon_x{}, render_weapon_y{}, render_weapon_z{};
        bool weapon_render_primed{false};

        // What we actually wrote to the prop last frame, kept solely so the NEXT frame can read the
        // actor's location BEFORE writing again and see whether anything moved it in between.
        // Exists because the original sinking diagnostic had a blind spot: it read the location
        // back immediately after our own write, which proves the write landed but cannot detect
        // drift applied between frames -- it would report "rock steady" in exactly the case where
        // something else drags the sword down every frame and we snap it back.
        double last_written_weapon_x{}, last_written_weapon_y{}, last_written_weapon_z{};
        bool weapon_write_recorded{false};

        // Retry throttle for resolving the peer's weapon class, same shape and same reason as
        // last_failed_outfit_mesh above: a peer whose weapon class doesn't resolve locally must
        // not re-attempt (and re-log) every single tick forever.
        std::string last_failed_weapon_class;
        uint64_t last_weapon_spawn_attempt_tick{0};

        // Montage mirror, added 2026-08-15 to fix the Dream Breaker THROW animation. Live capture
        // (verified.md / phase7.md) proved the throw is an Anim Montage
        // (dreamLady_WeaponThrow_Montage) and NOT any state-machine value this adapter mirrors --
        // moveState/actionState/animJumpType are bit-identical before and during a throw, so no
        // amount of property syncing could ever have reproduced it. Mirrored generically rather
        // than special-casing the one asset: the local side sends whatever montage is playing, so
        // every montage-driven animation this game has rides the same path.
        //
        // target_montage_count is a monotonic counter, the same shape as target_land_count and for
        // the same reason -- a montage that starts and ends between two sends would otherwise be
        // dropped entirely by the send cadence, and "did the count go up since I last looked" is
        // well-defined regardless of which snapshots arrive. last_seen_montage_count is baselined
        // on a peer's first sample so a mid-session joiner doesn't replay its last montage the
        // instant its ghost spawns (same fix as last_seen_land_count's).
        std::string target_montage;
        double target_montage_count{0};
        double last_seen_montage_count{0};

        // Stop half of the mirror (see the local montage_stop_count's comment). Same monotonic
        // counter shape, same first-sample baselining, for the same reason.
        double target_montage_stop_count{0};
        double last_seen_montage_stop_count{0};

        // Retry/spam guard, same role as last_failed_outfit_mesh above: a montage path that
        // doesn't resolve on this machine (peer on a different game build, say) must not re-resolve
        // and re-warn on every tick. Unlike outfit there's nothing to retry -- a montage is a
        // one-shot event, not a persistent visual state -- so this only exists to throttle the
        // warning.
        std::string last_failed_montage;
        uint64_t last_montage_warn_tick{0};

        // Bubble FLASH mirror edge state, 2026-08-15: the last in-bubble value pushed to this ghost,
        // so the game's own `StartBubbleJumpFlash`/`changeBubbleChargedJump` events fire once per
        // transition rather than every tick. These are "start"/"change" verbs -- calling them per
        // frame would retrigger the effect instead of letting it run.
        bool ghost_bubble_flash_on{false};
        // The peer's own bubble charged-jump flag, mirrored straight across the wire. Replaces the
        // two guessed tick windows that both failed for the same reason -- how long the effect lasts
        // is the game's business, not this adapter's.
        bool target_bubble_charged{false};

        // Diagnostic-only, 2026-08-15: CustomPlayMontage fires on the ghost and returns cleanly
        // (called=true, ten times, no warnings) yet the user confirmed live that no throw animation
        // plays -- the same "call fires, nothing visible" shape as the manageRecallIdleFX negative.
        // That entry's own stated weakness was that it couldn't distinguish "never started" from
        // "started and was immediately killed", so this reads the GHOST's own currently-playing
        // montage back for a few ticks after each call, via the same getter used on the local pawn
        // -- an independent read of the world, not an echo of what was written, per CLAUDE.md.
        // Splits the two cases cleanly: nothing at t+0 means CustomPlayMontage bailed internally;
        // present at t+0 then gone means something else stops it (this adapter's own land/jump
        // Montage_Stop pulse being the first suspect).
        uint32_t montage_readback_ticks_left{0};

        // GHOST_SELF_MONTAGE_PROBE state (see that flag's comment). Previous poll of what the
        // GHOST's own anim instance reported playing, so the probe logs one line per real change
        // instead of one per poll -- the same log-on-change shape ANIM_TRACE uses, and the reason
        // its output stays readable across a whole session of ledge grabs.
        bool self_probe_initialized{false};
        std::string self_probe_prev_montage;

        // MONTAGE_CATALOG_PROBE state (see that flag's comment). Index into
        // CATALOG_PROBE_MONTAGES, and the tick the current entry started, so the probe advances on
        // its own interval rather than on anything the peer does.
        size_t catalog_probe_index{0};
        uint64_t catalog_probe_last_tick{0};
        bool catalog_probe_started{false};

        // Diagnostic-only, 2026-08-15: previous-tick snapshot of the state actually WRITTEN to this
        // ghost, so ANIM_TRACE can log the ghost's timeline on change and line it up against the
        // local player's. Exists for the ledge-grab-lingers-after-release question, where the
        // montage explanation was ruled out by evidence and the remaining suspects are all about
        // when the state transition reaches the ghost.
        bool anim_trace_initialized{false};
        int anim_trace_prev_move_state{-1};
        int anim_trace_prev_action_state{-1};
        int anim_trace_prev_movement_mode{-1};
        int anim_trace_prev_anim_jump_type{-1};

        // Landing/jump pulse mirror, redone 2026-08-13 (follow-up session). The first attempt at
        // this (a plain bool, read/written on the PAWN) was a no-op on both ends: a real reflection
        // dump (log_pawn_reflection_once) proved 'landed?'/'jumped?' exist ONLY on animBPref (the
        // AnimBP instance, ABP_PlayerGoat_C), never on BP_PlayerGoatMain_C itself -- the pawn's only
        // landing-related member is 'playerLanded?', a MulticastInlineDelegateProperty (an event,
        // not a flag). Every prior TRACE local: line confirms it: landed=false jumped=false on
        // every sample, including ticks where movementMode=3 (Falling). So the theory that the
        // landing transition is gated on a one-shot AnimBP pulse the ghost never receives (its
        // CharacterMovementComponent can never detect ground contact with collision disabled, so
        // its own LandedDelegate/'landed?' pulse never fires) was never actually tested.
        //
        // This redo reads/writes animBPref->landed?/jumped? directly on both ends. It also switches
        // from a bool to a monotonic counter, because a single-tick bool pulse is the wrong shape
        // for this pipeline: Core.DefaultMinSendInterval (50ms) drops roughly 2 of every 3 frames
        // from a ~60Hz game thread before the relay ever sees them, and remoteBuffer.lerp holds
        // extras from the OLDER bracketing snapshot, so a snapshot renderTime steps over is never
        // returned at all. A counter that only ever increases survives both: the receiver fires the
        // one-shot on any observed increase over target_land_count/target_jump_count.
        double target_land_count{}, target_jump_count{};
        double last_seen_land_count{}, last_seen_jump_count{};
        // Ticks remaining to hold landed?/jumped? true on the ghost's own AnimBP once a rising edge
        // is observed -- the AnimBP's own update graph may re-evaluate and overwrite a single-tick
        // write before its state machine transition gets a chance to see it. See PULSE_HOLD_TICKS.
        uint32_t landed_hold_ticks{0}, jumped_hold_ticks{0};

        // Trail-VFX pulse mirror, 2026-08-15 -- see Plugin's own afterimage_count comment and
        // PLAYER_FIELDS.md's trail-VFX section. Same monotonic-counter edge-fire shape as
        // target_land_count/last_seen_land_count above: any observed increase over
        // last_seen_afterimage_count calls call_spawn_after_image on this ghost once.
        double target_afterimage_count{};
        double last_seen_afterimage_count{};
        // Real burst size from the sender's own game, replacing a hardcoded 6 -- a wrong count left
        // extra afterimages lingering after a slide (user-observed).
        double target_afterimage_spawn_n{};

        // Capsule half-height mirror, 2026-08-15. Fixes the "ghost sinks into the floor during a
        // slide" bug, whose mechanism is now measured rather than guessed: a UE Character's actor
        // location is its CAPSULE CENTRE, and a real slide shrinks the player's capsule from 65 to
        // 22 while dropping its origin 567.2 -> 524.2. Teleporting a still-65-tall ghost to that
        // lowered origin buries it exactly 65-22 = 43 units. Mirroring the half-height makes the
        // ghost's capsule shrink the same way, so the lowered origin is correct for it too.
        // Doubles as the real slide signal -- see target_capsule_half's use in tickRenders.
        double target_capsule_half{};
        double last_applied_capsule_half{};
        bool prev_remote_sliding{false};
        // Ghost's own last-seen health, for the enemy-damage test (see HEALTH_TRACE in Plugin.cpp).
        double last_seen_ghost_health{-1.0};

        // Cling-gem (wall-ride) trigger edge. moveState==4 is the confirmed cling marker
        // (verified.md's wall-ride entry) and moveState is already mirrored, so this only needs to
        // remember the previous value to fire once per cling rather than every tick of one.
        uint8_t last_wallrun_move_state{0};

        // Trail colour mirror (see read_linear_color/write_linear_color in Plugin.cpp). Written to
        // the ghost's own 'afterimageColor' immediately before its trail burst is triggered, so
        // the burst picks up the sender's colour -- including the base game's own dynamic
        // yellow->BLUE change on a perfect-timing "ultra" hop, not just a modded custom colour.
        // Defaults chosen so a peer on an older build (no colour in its extras) leaves the ghost's
        // own inherited colour untouched rather than forcing it to black: afterimage_color_valid
        // stays false until a real value actually arrives.
        float target_afterimage_color[4]{};
        bool afterimage_color_valid{false};

        // Lua's trySpawnRemoteGhost guards spawning with a `remote.spawning` re-entrancy flag
        // because its spawn call is deferred through ExecuteInGameThread -- a gap exists between
        // "decided to spawn" and "the ghost field is actually set" where a re-check could fire
        // twice. game_thread_tick() already runs on the game thread throughout, so
        // ensure_ghost_spawned's SpawnActor call is synchronous and `ghost` is set before it
        // returns -- no such gap exists here, so no equivalent flag is needed.
    };

    class Plugin : public RC::CppUserModBase
    {
      public:
        Plugin();
        ~Plugin() override;

        auto on_unreal_init() -> void override;

        // Phase 7.5-in-C++: step 1 proved real position reflection works natively, step 2 added
        // the real bridge connection, step 3 parses render_remote/despawn_remote and drives
        // ghosts -- redesigned from spawn-based to hijack-based after the world-leak crash
        // investigation found no working actor-destroy mechanism on this build. Fires every
        // engine tick.
        auto on_update() -> void override;

      private:
        auto handle_bridge_line(const std::string& line, RC::Unreal::UObject* local_pawn, RC::Unreal::UObject* local_controller) -> void;

        // Phase 7.6: spawns a clone of the local player's own pawn class (ported field-for-field
        // from the Lua adapter's trySpawnRemoteGhost, probe_ghost/Scripts/main.lua:596-650), then
        // immediately re-possesses the real local player -- the already-confirmed Phase 7.4
        // auto-possess safety fix. Selected via SPAWN_BASED_GHOSTS in Plugin.cpp.
        auto ensure_ghost_spawned(const std::string& player_id, RC::Unreal::UObject* local_pawn, RC::Unreal::UObject* local_controller) -> void;

        // Finds an already-existing, already-registered StaticMeshActor in the local player's
        // current world and repurposes it as the remote's ghost -- never spawns anything, so
        // there is never anything that needs destroying. Kept as the SPAWN_BASED_GHOSTS=false
        // fallback path. See RemoteGhost's own comment for why.
        auto ensure_ghost_hijacked(const std::string& player_id, RC::Unreal::UObject* local_pawn) -> void;

        // Stops tracking a remote's ghost. Does NOT destroy/touch the underlying actor. Under the
        // hijack design this was never ours to destroy; under the spawn design (Phase 7.6), a
        // level transition destroys it out from under us anyway (confirmed live, Lua saga), so by
        // the time this runs there is nothing left to destroy either way -- see the staleness
        // check in game_thread_tick, which is what actually detects and clears a dead ghost.
        // Renders one remote's thrown Dream Breaker -- spawn/park/move of the peer's loose-weapon
        // prop. Split out of the redraw loop rather than inlined because it owns a second actor
        // with its own independent lifetime, staleness and smoothing state; see
        // RemoteGhost::weapon_actor.
        auto tick_remote_weapon(const std::string& player_id, RemoteGhost& remote, RC::Unreal::UWorld* current_world) -> void;

        // Cycles every loaded Niagara system onto one ghost, one at a time -- see VFX_CATALOG_PROBE
        // in Plugin.cpp for why a probe answers this better than hunting triggers.
        auto tick_vfx_catalog_probe(RC::Unreal::AActor* ghost) -> void;

        // Shows/hides a ghost's empty-hand recall glow -- see RemoteGhost::recall_glow_component.
        auto tick_remote_recall_glow(const std::string& player_id, RemoteGhost& remote) -> void;

        // Two-sample capture of the ghost-spawns-mid-throw case -- see GHOST_SPAWN_WEAPON_TRACE.
        auto tick_ghost_spawn_weapon_trace(const std::string& player_id, RemoteGhost& remote) -> void;

        auto release_ghost(const std::string& player_id) -> void;
        auto release_all_ghosts(const wchar_t* reason) -> void;

        // Found live 2026-08-14: closing the core process (meshghost.exe) drops the bridge
        // connection, but neither despawn_remote (the core never gets a chance to send it) nor
        // the LoadMap PRE hook (no area transition happened) fires -- a remote's ghost was left
        // standing frozen and visible indefinitely. Unlike release_all_ghosts's LoadMap case,
        // no level teardown is coming to reclaim the actor here, so this parks every remaining
        // ghost the same way a real despawn_remote does (see release_ghost). Must run on the
        // game thread, same requirement as release_ghost's own actor write -- called from
        // game_thread_tick, armed by on_update noticing the connected->disconnected edge.
        auto release_all_ghosts_parked(const wchar_t* reason) -> void;

        auto log_remote_state(const wchar_t* context) -> void;

        // THE fix for the render-freeze bug, found 2026-08-13: on_update() runs on UE4SS's own
        // internal polling thread (confirmed directly from UE4SS's source, UE4SSProgram.cpp:
        // ProfilerSetThreadName("UE4SS-UpdateThread"), a ~5ms std::this_thread::sleep_for loop) --
        // NOT the real Unreal game thread. Every actor write this mod ever made was happening off
        // the game thread, which explains "position reads back correctly (same-thread readback)
        // but never visually updates (never reaches the renderer's expected sync point)". This
        // method runs all actor-touching work (hijack search/writes, redraws, bHidden toggle) from
        // inside an EngineTick post-hook instead, which genuinely runs on the game thread -- the
        // same mechanism Lua's ExecuteInGameThread(EGameThreadMethod.EngineTick) uses under the
        // hood.
        auto game_thread_tick() -> void;

        // Phase 7.6: re-opens Phase 7.4's camera bug (a StaticMeshActor never stole the camera, so
        // the hijack design never needed this). Two ProcessEvent-hook-based attempts never fired
        // even once, confirmed by a read-only diagnostic run with zero log output -- root cause
        // read directly from UE4SS's own Lua RegisterHook implementation
        // (RE-UE4SS/UE4SS/src/Mod/LuaMod.cpp:3907-3921): SetViewTargetWithBlend is a native
        // function, and native UFunctions are hooked via UFunction::RegisterPreHook/RegisterPostHook
        // directly on the function object, not via a ProcessEvent filter -- a fundamentally
        // different, narrower set of calls. This version uses RegisterPreHook and rewrites the
        // NewViewTarget argument in the engine's own argument buffer (TheStack.Locals(), via
        // UnrealScriptFunctionCallableContext::GetParams<T>()) before the real call proceeds --
        // see its body for the full design and why this needs no second call/deferral at all.
        auto register_camera_fightback_hook() -> void;

        // Bridge networking (on_update, UE4SS's own thread) and actor work (game_thread_tick,
        // the real game thread) now run concurrently -- this guards the state both sides touch.
        std::mutex state_mutex;
        std::vector<std::string> pending_incoming_lines; // filled by on_update, drained by game_thread_tick
        std::string cached_local_state_json;             // built by game_thread_tick, sent by on_update
        // Bridge-disconnect ghost cleanup handoff (see release_all_ghosts_parked's comment):
        // on_update notices the connected->disconnected edge and sets the pending flag;
        // game_thread_tick drains it and does the actual (game-thread-only) parking.
        bool bridge_was_connected{false};
        bool bridge_disconnect_cleanup_pending{false};

        // Local landed?/jumped? edge counters for the redone pulse mirror (see
        // RemoteGhost::target_land_count's comment). Incremented once per rising edge of the real
        // pawn's animBPref->landed?/jumped? (read in game_thread_tick, on the game thread), so
        // prev_landed_raw/prev_jumped_raw track the previous tick's raw value purely to detect that
        // edge -- without them the same landing would count once per tick the flag happens to still
        // read true. Never cleared/reset: a monotonic counter needs no thread-handoff clear-after-
        // send step the way the old bool latch did, since "did land_count increase since I last
        // looked" is well-defined regardless of which snapshots got sent.
        uint32_t landed_count{0}, jumped_count{0};
        bool prev_landed_raw{false}, prev_jumped_raw{false};

        // Local half of the montage mirror (see RemoteGhost::target_montage). montage_count ticks
        // up once per montage START -- prev_local_montage tracks the previous tick's value purely
        // to detect that edge, exactly as prev_landed_raw does for landings. Only a transition to a
        // genuinely different, non-empty montage counts: a montage ending (-> "none") is not an
        // event to replay on the ghost, since the ghost's own copy runs out on its own.
        uint32_t montage_count{0};
        std::string prev_local_montage;

        // Montage STOPS, added 2026-08-15 immediately after the throw fix shipped: mirroring only
        // starts left a real gap, and the user found it the same session -- the ghost held the
        // ledge-grab pose for a noticeable beat after the real player let go. A montage that ends
        // on its own is harmless (the ghost's copy of the same asset ends on its own too), but one
        // the game cuts short -- letting go of a ledge -- left the ghost holding the pose until the
        // land/jump Montage_Stop pulse happened to clear it. Counts local montage ENDS the same
        // monotonic way montage_count counts starts.
        uint32_t montage_stop_count{0};

        // Diagnostic-only, 2026-08-15 trail-VFX investigation: edge-detects the real pawn's
        // 'spawnTrackingParticles?' bool (found by OBJECT_REFLECTION_DUMP) so ABILITY_FIELD_TRACE
        // can log its onset/offset every tick instead of only sampling it at the ~2s trace cadence,
        // which risks missing a slide/ultra-hop shorter than that window entirely.
        bool prev_spawn_tracking_particles{false};

        // Diagnostic-only, 2026-08-15 Dream Breaker THROW-animation investigation (see
        // THROW_ANIM_TRACE in Plugin.cpp for the hypothesis). Previous-tick snapshot of everything
        // the local player's throw could plausibly show up in, so the trace can log one line per
        // real CHANGE instead of 60 lines a second -- and, crucially, catch the throw wind-up that
        // happens BEFORE weaponEquipped? flips, which an edge-triggered burst would miss by
        // construction. throw_trace_montage_getter_ok latches false the first time the montage
        // getter fails to resolve, so a missing name logs once rather than every tick.
        bool throw_trace_initialized{false};
        bool throw_trace_schema_dumped{false};
        bool throw_trace_montage_getter_ok{true};
        bool throw_trace_prev_weapon_equipped{false};
        bool throw_trace_prev_weapon_ref_valid{false};
        int throw_trace_prev_move_state{-1};
        int throw_trace_prev_action_state{-1};
        int throw_trace_prev_anim_jump_type{-1};
        std::string throw_trace_prev_montage;

        // Trail-VFX pulse mirror, 2026-08-15 -- same monotonic-counter edge-fire shape as
        // landed_count/jumped_count above (survives the send-rate/interp-buffer gap the same way).
        // Incremented on the real pawn entering actionState 18 (slide) or 8 (airborne
        // flip-after-slide). This is a known-imperfect heuristic, kept deliberately: a real
        // UFunction hook would be the correct event source, but that was tried and crashed the
        // game (see the DO-NOT-re-add note further down this file). Known open imperfections, both
        // confirmed live: a quick 180-degree turn-around shares actionState 18 with a real slide
        // and so fires a false positive, and Solar Wind's ultra hop doesn't reliably match.
        // prev_trail_action_state tracks the previous tick's raw actionState purely to detect the
        // transition into 18/8, same role as prev_landed_raw/prev_jumped_raw above.
        // **Rearchitected again 2026-08-15, and this time from the game's own signal.** Every
        // actionState-based heuristic failed live in a different way: firing on a quick 180-degree
        // turn-around (which shares actionState 18 with a real slide), and on a plain walking
        // backflip (actionState 8 turns out to mean "backflip" generically, not "slide-launched
        // trick"). Rather than hunt for a fourth discriminator, this now mirrors
        // 'afterImagesToSpawn' -- the int the REAL GAME sets when IT decides to trail, and the same
        // field the ghost side already writes before calling spawnNumAfterimages. Reading the
        // game's own decision cannot false-positive by construction, the same reasoning that made
        // moveState==4 the right cling-gem trigger.
        // afterimage_count is still the monotonic wire counter (it survives the send-rate/interp
        // gap); afterimage_spawn_n carries the real N so the ghost reproduces the true burst size
        // instead of a hardcoded guess.
        uint32_t afterimage_count{0};
        int32_t afterimage_spawn_n{0};
        int32_t prev_local_afterimages_to_spawn{0};
        // Real-slide edge detection (see the trigger block in Plugin.cpp). actionState==18 alone is
        // NOT a slide -- a quick 180-degree turn-around produces the same value. The discriminator,
        // found by segmenting a dense coverage capture into state runs, is animJumpType: real
        // slides run as=18 WITH ajt=13, turn-around skids run as=18 with ajt=0.
        // Real-slide detection, corrected 2026-08-15 by a plain-slide-only capture. A plain slide
        // is actionState==1 with the capsule SHRUNK (65 -> 22), not actionState==18/ajt==13 as an
        // earlier guess had it -- that signature belongs to the skid/turn-around and to the slide
        // that precedes a backflip. Capsule shrink is the reliable marker because it is physical
        // rather than an enum whose meanings overlap between moves.
        bool prev_local_sliding{false};
        // Re-fire throttle for a held slide. Earlier repeat attempts were abandoned because the
        // trigger itself was wrong (actionState alone caught turn-arounds too, so repeating it
        // multiplied the false positives). With as=18 && ajt=13 the signal is specific to a real
        // slide, so repeating is now safe and is what makes the ghost's trail last as long as the
        // real one instead of being a single burst at the start.
        uint64_t last_slide_refire_tick{0};
        // Tick the current slide started, so re-fires can be cut off before the slide ends. A real
        // slide is a consistent 87 ticks (measured across four consecutive slides), and each
        // afterimage lives out its own lifetime after spawning -- so images spawned near the end
        // are exactly the ones that linger past it. Bounding the spawn window to the early part of
        // the slide makes the trail's tail land near the slide's end instead of ~0.5-1s after.
        uint64_t slide_start_tick{0};

        // Bubble post-jump "boost available" trail, 2026-08-15 (trigger C). The user reported the
        // ghost animating correctly through the bubble but never trailing, and a bubble-only
        // coverage capture found why: across 2002 ticks of that state the game sets
        // `afterImagesToSpawn` to **zero every single tick**, so trigger A cannot see it and the
        // capsule never shrinks, so trigger B can't either. It is the documented second spawn path.
        //
        // Unlike the slide there is no end-of-move tick count to bound: the state ends when the
        // player presses jump (which they may do at any time) or lands, measured at 261-793 ticks
        // across repetitions. So this re-fires for as long as the state is HELD, with no window
        // cutoff -- the real player's trail lasts the whole time too.
        // `moveState==7 && movementMode==5` is INSIDE the bubble (originally mislabelled as the
        // post-jump window; corrected by the user's live three-way report, see the trigger's own
        // comment). bubble_enter_tick bounds the in-bubble trail, because sitting in a bubble is
        // player-terminated and can outlast the real trail, which the user watched happen.
        bool prev_local_bubble_in_bubble{false};
        uint64_t last_bubble_refire_tick{0};
        uint64_t bubble_enter_tick{0};
        // Trigger D's latch: the post-jump "boost available" window, which is plain falling in every
        // field captured and so can only be identified by having just left the bubble. Cleared on
        // the boost (animJumpType==2) or on landing -- the two ends the user described.
        bool boost_window_active{false};
        // BUBBLE_FX_DIFF state: previous property snapshot of the LOCAL pawn, kept only while the
        // bubble effect is on screen and cleared on leaving, so the next bubble's first diff isn't
        // taken against a stale baseline. std::wstring keys rather than StringType to keep this
        // header free of the Unreal SDK's string typedef; they are the same type on this build.
        std::map<std::wstring, std::wstring> bubble_fx_prev_snapshot;
        uint64_t bubble_fx_last_sample_tick{0};

        // POLE_ROTATION_TRACE state: previous quantised sample, so the trace logs one line per real
        // change rather than one per tick. Reset on leaving the flying movement mode so each pole
        // or bubble visit starts with a fresh baseline line.
        // BLINK_FX_SEARCH: one-shot latch, so the filtered function/property dump prints once per
        // session rather than every tick.
        bool blink_fx_search_done{false};

        // Bubble charged-jump flag discovery (see its block in tickLocal): resolved once by
        // searching the pawn's bool properties, so the real name lands in the log rather than being
        // assumed. Empty means this build has none and the ghost falls back to the in-bubble state.
        // Previous local value of the bubble charged-jump flag, so its on/off edges log once each
        // and can be timed against the ghost's own edges.
        bool prev_local_bubble_charged{false};
        bool bubble_charge_prop_searched{false};
        std::wstring bubble_charge_prop_name;

        bool pole_trace_initialized{false};
        int pole_trace_prev_yaw{0};
        int pole_trace_prev_vm_yaw{0};
        int pole_trace_prev_x{0};
        int pole_trace_prev_y{0};

        // Health trace (HEALTH_TRACE) for the enemy-damage-vs-ghost test. The melee-death bug is
        // that damaging the ghost also damaged/killed the REAL player, and bCanBeDamaged=false
        // provably did NOT stop it -- so with collision now on as a feature, the open question is
        // whether ENEMY/environmental damage hitting a ghost does the same. A naive live test can't
        // answer that (if enemies are hitting the player too, the cause is ambiguous), so this
        // records local and ghost health independently and only on change.
        double prev_local_health{-1.0};
        bool health_names_logged{false};

        // Diagnostic (TRAIL_TRIGGER_TRACE): previous tick's local afterimageColor, so a real
        // CHANGE can be edge-logged rather than sampled. Answers the one question that splits the
        // "ghost's ultra hop trails yellow instead of blue" bug in two -- either afterimageColor
        // never turns blue on the real player (so blue comes from some other mechanism entirely
        // and this property is the wrong lever), or it does and the sync/timing is dropping it.
        float prev_local_afterimage_color[3]{-1.0f, -1.0f, -1.0f};

        // Diagnostic (TRAIL_TRIGGER_TRACE): previous tick's ultra-state candidates, edge-logged the
        // same way and for the same reason as the colour above -- an ultra hop's window is short
        // enough that a periodic sample could miss it. Question being answered: which field (if
        // any) actually marks a perfect-timing ultra, since afterimageColor was proven NOT to carry
        // the blue (verified.md). animJumpType is included deliberately even though this adapter
        // ALREADY syncs it (target_anim_jump_type) -- an earlier capture showed it reading 13 on one
        // jump vs 11 on normal ones, and if that turns out to be the ultra marker then the ghost is
        // already receiving it and the blue's absence has a different cause again.
        bool prev_ultra_cap{false};
        double prev_full_ultra_modifier{-1.0};
        double prev_capped_ultra_modifier{-1.0};
        int32_t prev_anim_jump_type{-1};

        // Diagnostic (WALLRIDE_TRACE): previous tick's cling-gem/wall-ride state, edge-logged.
        // Purpose is the precondition question, not the trigger question: enabling ghost collision
        // did NOT make the cling-gem VFX appear (expected -- the ghost's wall-run logic never runs
        // without input), so before calling doWallRun on the ghost this needs to establish WHICH
        // state that logic reads and what it looks like during a real wall ride, per the
        // precondition clause in ideas.md that the recall-glow failure established.
        bool prev_wallride_button_held{false};
        bool prev_can_wall_run{false};
        int32_t prev_current_wall_run_clings{-1};
        bool prev_wallride_vfx_valid{false};

        // Diagnostic (WEAPON_ACTOR_TRACE): thrown-Dream-Breaker tracking. See that flag's own
        // comment in Plugin.cpp for what each of these is measuring and why the existing record on
        // `weaponRef` can't be trusted without it.
        //
        // prev_weapon_ref holds the raw pointer purely to compare identity against the next tick's
        // value -- it is never dereferenced after the tick that stored it, so a destroyed thrown
        // weapon (the case this whole capture is about) can't be followed into freed memory. The
        // last-logged transform is kept as plain doubles for the same reason.
        RC::Unreal::UObject* prev_weapon_ref{nullptr};
        bool weapon_ref_value_dumped{false};
        bool prev_weapon_equipped_for_actor_trace{true};
        uint64_t weapon_actor_sweep_due_tick{0}; // 0 = no sweep pending
        double weapon_actor_last_logged_x{0.0}, weapon_actor_last_logged_y{0.0}, weapon_actor_last_logged_z{0.0};
        bool weapon_actor_transform_logged{false};

        // Diagnostic (WEAPON_LANDING_TRACE): previous values on the LOCAL player's own thrown
        // weapon, so a landing edge-logs once instead of sampling. -1/-2 sentinels mean "nothing
        // read yet" and are outside any real byte value, so the first real read always logs.
        // One-shot latch for the same trace's function/property dump of the real thrown weapon --
        // fires once per session, not once per throw.
        // Diagnostic (VFX_WATCH): the set of Niagara effects currently live on the LOCAL player,
        // as "asset | instance" strings, so appearances and disappearances can be edge-logged
        // rather than sampled. A set of strings rather than of pointers deliberately -- a pointer
        // says nothing about which effect it was, and these are short-lived objects whose
        // addresses get recycled.
        std::set<std::string> prev_player_vfx;

        // Whether the real recall glow is currently showing on the local player. Sampled at
        // RECALL_GLOW_SCAN_INTERVAL_TICKS and held between scans, then sent so a ghost mirrors the
        // game's own decision instead of a reimplementation of its rule.
        bool local_recall_glow{false};

        // VFX_CATALOG_PROBE state. The catalog is built once per session and then cycled: index is
        // where the cycle is up to, and the component is the currently-showing effect, destroyed
        // when the next one starts so only one is ever on screen to attribute a look to.
        std::vector<std::string> vfx_probe_catalog;
        bool vfx_probe_catalog_built{false};
        size_t vfx_probe_index{0};
        uint64_t vfx_probe_last_switch_tick{0};
        RC::Unreal::UObject* vfx_probe_component{nullptr};

        bool weapon_landing_reflection_dumped{false};
        // One-shot latch for dumping the real landed sword's idleGlowVFX component.
        bool weapon_glow_dumped{false};
        int32_t prev_local_weapon_state{-1};
        int32_t prev_local_weapon_embedded{-1};
        double prev_local_weapon_mesh_offset[3]{-99999.0, -99999.0, -99999.0};

        bool unreal_ready{false};
        uint64_t tick_count{0};
        uint64_t ticks_since_ready{0};
        // Ticks since the local pawn most recently became valid -- resets to 0 whenever it's not
        // (e.g. at the title screen). Gates SPAWN_DELAY_TICKS in ensure_ghost_spawned, mirroring
        // Lua's original diagnostic setup (main.lua's SPAWN_DELAY_TICKS/followTick,
        // agent_docs/phases/phase7.md's Phase 7.4 saga) that first caught the camera re-pick on
        // camera: let the player's own camera settle on a real target before any ghost exists,
        // so the moment it swaps away is a clean, isolated, observable event.
        uint64_t ticks_since_pawn_valid{0};
        std::unique_ptr<BridgeClient> bridge;
        std::unordered_map<std::string, RemoteGhost> remotes;
        std::unordered_set<RC::Unreal::AActor*> hijacked_actors; // prevents two remotes sharing one prop
        RC::Unreal::UWorld* last_logged_world{nullptr};

        // Camera fight-back state (Phase 7.6), mirrors Lua's lastKnownGoodViewTarget/anyGhostSpawned.
        // No pending/deferred fields needed -- the RegisterPreHook design rewrites the engine's own
        // argument buffer in place, synchronously, before the real call runs.
        RC::Unreal::UFunction* svtwb_function{nullptr}; // cached "SetViewTargetWithBlend", found once
        RC::Unreal::AActor* last_known_good_view_target{nullptr};
        bool any_ghost_ever_spawned{false};

        // DO NOT re-add UFunction hooks on 'Spawn After Image'/'spawnNumAfterimages' -- tried
        // 2026-08-15 and it CRASHED the game (see verified.md's "trail-VFX UFunction hook crash"
        // entry and agent_docs/pitfalls.md). Both hooks registered successfully (real callback IDs
        // logged) but fired ZERO times across ~18s of real play, then the game hit a Fatal error
        // with nothing logged. Root cause: UE4SS's RegisterPre/PostHook works by swapping the
        // UFunction's own function pointer, which is safe for NATIVE functions (what the
        // SetViewTargetWithBlend camera hook below targets -- see register_camera_fightback_hook's
        // comment) but these two are BLUEPRINT functions, whose pointer is the shared
        // ProcessInternal bytecode entry -- swapping it both failed to intercept and corrupted
        // execution. The trail trigger stays on polled actionState instead (afterimage_count).

        // Callback/hook IDs, captured so ~Plugin can unregister them explicitly on mod
        // unload/reload -- found in a review pass: previously discarded, leaving every
        // Register*Callback/RegisterPreHook detour pointing at this (about-to-be-freed) Plugin
        // instance active with no way to remove it. Stored as the underlying primitive types
        // (Hook::GlobalCallbackId is uint64_t, RC::Unreal::CallbackId is int32_t) rather than
        // pulling <Unreal/Hooks.hpp> into this widely-included header, the same reasoning
        // BridgeClient.hpp already applies to storing its SOCKET as a uintptr_t. Hook::ERROR_ID
        // (0) is this file's real sentinel for "never registered"; -1 mirrors that for the
        // UFunction hook, whose own ID counter starts elsewhere and would not plausibly land on
        // a negative value.
        uint64_t load_map_pre_callback_id{0};
        uint64_t engine_tick_post_callback_id{0};
        int32_t svtwb_hook_id{-1};
    };
} // namespace MeshGhostPseudo
