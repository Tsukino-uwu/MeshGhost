#pragma once

// The Pseudoregalia adapter's UE4SS mod: RemoteGhost, one per peer, and the Plugin that drives them. The
// CppUserModBase interface is RE-UE4SS's UE4SS/include/Mod/CppUserModBase.hpp.

#include <atomic>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <tuple>
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
    class CoreLauncher;

    // One entry per remote player_id, driven by render_remote and despawn_remote. Ghosts are spawned clones of the
    // player's pawn class (SPAWN_BASED_GHOSTS); ensure_ghost_hijacked is the older fallback.
    struct RemoteGhost
    {
        // Logged-once latch for the already-hit marking (GHOST_PREHIT_PLAYER), per ghost.
        bool prehit_logged{false};

        // Whether this ghost's light is down; until then the sweep runs every tick, not per LIGHT_SWEEP_INTERVAL_TICKS,
        // since a ghost is born at the Blueprint's default intensity and even a brief flash leaves the room lit.
        bool light_zeroed{false};

        // True while the player's capsule and this chaser's last overlapped, so "kill" fires once per overlap; "hurt"
        // is per tick, as a real enemy's contact damage is, and the game's own i-frames throttle it.
        bool chaser_contact_overlapping{false};

        // No light-component list here: components held between ticks are freed by a same-level save reload without
        // LoadMap PRE firing, so the hold walks this ghost's own attach tree each time instead.

        // How often the game has put this ghost's light back after we turned it down: zero means a birth default,
        // anything large means the pawn re-lights it every frame and the hold is all that keeps it dark.
        uint64_t light_relit_count{0};

        // apply_ghost_distance_tier: 0 full, 1 throttled, 2 far, 3 dormant. Only a change of tier costs engine calls.
        int distance_tier{0};
        // The spawn tick, bounding the short retry window for finding the ghost's ambient particle emitter.
        uint64_t spawned_at_tick{0};
        bool ambient_fx_stripped{false};

        RC::Unreal::AActor* ghost{nullptr};
        RC::Unreal::UWorld* owning_world{nullptr}; // which UWorld `ghost` belongs to (spawned into, or hijacked from)

        // The nametag's component. The name lives in Plugin::nametags, since it can arrive before the ghost does; an
        // empty name draws no tag.
        RC::Unreal::UObject* nametag_component{nullptr};
        // What the component was last set to, so the per-tick update makes no engine call when nothing changed.
        std::string nametag_applied_name;
        std::string nametag_applied_color;
        // The colour plate behind the name: a second text component drawing the string as solid glyph blocks through
        // an EmissiveMeshMaterial MID, coloured by its "Color" parameter (NAMETAG_COLOR_PLATE). The text stays black.
        RC::Unreal::UObject* nametag_plate{nullptr};
        RC::Unreal::UObject* nametag_plate_mid{nullptr};
        std::string nametag_plate_applied_color;
        // Whether the plate holds a valid colour; false blanks it, since an unset "Color" draws a white box.
        bool nametag_plate_has_color{false};
        // Latches a failed creation so it logs once, not per frame per ghost.
        bool nametag_create_failed{false};
        // The rec_indicator.txt tuning generation this tag's size and plate scale were built with; re-applied when
        // the global moves on.
        unsigned nametag_tuning_gen{0};
        double target_x{}, target_y{}, target_z{};
        double target_pitch{}, target_yaw{}, target_roll{};
        // The render-clock time of the newest rendered state: a remote_input edge applies on the first render whose
        // stamp reaches the edge's `at`.
        double target_ts{0.0};
        // The ghost drive dev rig (ghost_drive.txt beside the DLL): this ghost is driven through its own input events
        // instead of mirrored, and mechanisms 1-12 skip it while `driven` is true. Nothing shipped sets it.
        bool driven{false};
        bool drive_prepared{false}; // collision on, Pawn/Camera ignored, overlaps off; once per pawn
        // The drive trace: the pawn's own state as last logged, so a change names its tick.
        int drive_last_action{-1}, drive_last_move{-1}, drive_last_crouched{-1}, drive_last_mode{-1};
        double drive_last_capsule{-1.0};
        // Track mode: the stick as last fed (so a release is sent once), corrections made,
        // the largest drift seen, and the last report.
        bool drive_move_live{false};
        uint32_t drive_corrections{0};
        double drive_max_drift{0.0};
        double drive_report_s{0.0};
        // The cling trace: the ghost's last traced position and time, for its own speed, and the last periodic
        // report while either side is in the wall state.
        double drive_prev_x{0.0}, drive_prev_y{0.0}, drive_prev_z{0.0}, drive_prev_t{-1.0};
        double drive_cling_report_s{0.0};
        // The clip's previous target: a correction restores the recording's velocity along the direction the target
        // moved, not a standstill.
        double drive_prev_target_x{0.0}, drive_prev_target_y{0.0}, drive_prev_target_z{0.0};
        bool drive_prev_target_valid{false};
        uint32_t drive_edges_applied{0};
        double drive_next_s{0.0};
        int drive_node_i{0};
        int drive_fired{0};
        // The driven ghost's private game-instance object, constructed at prepare with the pawn as outer; held only
        // for the log.
        RC::Unreal::UObject* drive_private_gi{nullptr};
        // The ghost pawn's own BP_HpHitable component, stashed by the spawn decouple before it nulls the pawn's
        // reference; a driven ghost gets the reference back at prepare.
        RC::Unreal::UObject* drive_own_hitable{nullptr};

        // Redraw-loop ticks since this ghost was created, so its first several ticks can be logged unconditionally.
        uint32_t ticks_since_spawn{0};

        // The player's animation-driving state, written onto the ghost's pawn each tick for its own anim instance to
        // read; landed?/jumped? are different (target_land_count).
        double target_move_state{}, target_action_state{}, target_h_speed{}, target_v_speed{}, target_anim_jump_type{};

        // The movement component's MovementMode, mirrored like moveState: an AnimBP transition reads it directly,
        // and with collision off the ghost's own component never detects the ground.
        double target_movement_mode{};

        // Dream Breaker visibility: weaponEquipped? and animEquippedWeapon are continuous "has the weapon" flags, and
        // both are written, since which of them drives WeaponMesh's visibility is not established.
        bool target_weapon_equipped{false};

        // Edge state for updateWeaponEquip, which may fire a one-shot montage per call: called only on a real
        // transition. weapon_equip_call_armed syncs the spawn state once without treating it as a fresh equip.
        bool last_synced_weapon_equipped{false};
        bool weapon_equip_call_armed{false};

        // Outfit mirror: an outfit is a different asset in VisualMesh's SkeletalMesh. The target is the object path
        // (not GetFullName()'s "Class Path" form), applied only when it changes.
        std::string target_outfit_mesh;
        std::string last_synced_outfit_mesh;

        // Retries a target that fails to resolve (a mod this machine lacks) once per LOG_INTERVAL_TICKS, while a new
        // target is tried at once.
        std::string last_failed_outfit_mesh;
        uint64_t last_outfit_attempt_tick{0};

        // Weapon model mirror, the outfit fields' twin for the hand WeaponMesh: a weapon mod is only a different
        // SkeletalMesh asset there. An empty target means the peer never said.
        std::string target_weapon_mesh;
        std::string last_synced_weapon_mesh;
        std::string last_failed_weapon_mesh;
        uint64_t last_weapon_mesh_attempt_tick{0};

        // The peer's thrown Dream Breaker. A throw spawns a BP_looseWeapon_C that flies, bounces and rests under its
        // own ProjectileMovementComponent, so its position and rotation alone carry the whole visual.
        // weapon_actor is the spawned copy the flyer below replaced: never set now, only destroyed on release.
        RC::Unreal::AActor* weapon_actor{nullptr};
        RC::Unreal::UWorld* weapon_actor_world{nullptr};
        // The flyer: a mesh component like the ghost's hand WeaponMesh, added to the ghost and driven from the wire.
        // weapon_hand_hidden records that we hid the hand mesh, so the catch never un-hides one someone else hid.
        RC::Unreal::UObject* weapon_fly_component{nullptr};
        bool weapon_hand_hidden{false};

        // The peer's ranged projectile, mirrored as an effect we create rather than the game's actor
        // (MIRROR_PEER_PROJECTILE); the game's projectile is never held.
        RC::Unreal::UObject* projectile_component{nullptr};
        RC::Unreal::UWorld* projectile_component_world{nullptr};
        // Hurt (MIRROR_HURT_REACTION), death fade (MIRROR_DEATH_FADE) and blink (MIRROR_PLAYER_BLINK) counters: a
        // counter crosses the wire however briefly the moment lasted. A pit fall is a hurt, not a death.
        int target_hurt_count{0};
        int last_seen_hurt_count{0};
        int target_death_count{0};
        int last_seen_death_count{0};
        int target_blink_count{0};
        int last_seen_blink_count{0};
        bool target_projectile_active{false};
        std::string target_projectile_vfx{};
        double target_projectile_x{0.0}, target_projectile_y{0.0}, target_projectile_z{0.0};
        double target_projectile_pitch{0.0}, target_projectile_yaw{0.0}, target_projectile_roll{0.0};
        // Retry throttle for a class path that does not resolve on this machine.
        std::string last_failed_projectile_vfx{};
        uint64_t last_projectile_spawn_attempt_tick{0};
        bool target_weapon_thrown{false};
        std::string target_weapon_class;
        double target_weapon_x{}, target_weapon_y{}, target_weapon_z{};
        double target_weapon_pitch{}, target_weapon_yaw{}, target_weapon_roll{};

        // The peer's weaponState (0 in flight, 3 landed): mirroring it is what makes a landed sword read as resting,
        // since a teleported copy with collision off never lands itself. Applied only on a change: a transition
        // function called every tick sees nothing to change when a real change comes.
        double target_weapon_state{};
        double last_synced_weapon_state{-1.0}; // -1 = nothing synced yet, outside any real state
        // The peer's cumulative wall-bounce counter; -1 baselines on next sight, so a mid-session join replays nothing.
        double target_weapon_bounce{};
        double last_seen_weapon_bounce{-1.0};
        // The peer's blob-shadow visibility, mirrored on change (the game hides it while sitting); -1 = not applied.
        bool target_shadow_visible{true};
        int last_applied_shadow_visible{-1};

        // The landed sword's glow ring, sent as the peer's own NiagaraSystem asset path so a build or mod with another
        // effect still resolves; our copy is spawned on landing and destroyed on the catch.
        std::string target_weapon_glow;
        RC::Unreal::UObject* weapon_glow_component{nullptr};

        // The empty-hand recall glow, spawned directly like the landed ring: manageRecallIdleFX's guards want state an
        // unpossessed ghost lacks.
        RC::Unreal::UObject* recall_glow_component{nullptr};
        bool recall_glow_shown{false};
        // The peer's observed answer, not a recomputation of the game's rule (RECALL_GLOW_ENABLED).
        bool target_recall_glow{false};

        // One-shot sweep for a recall glow the ghost built itself: a clone reading the local save can spawn glowing,
        // which would show the local player's state on someone else's ghost.
        bool recall_glow_swept{false};

        // GHOST_SPAWN_WEAPON_TRACE bookkeeping: the spawn tick (0 = not spawned) and which samples are taken.
        uint64_t spawn_weapon_trace_tick{0};
        bool spawn_weapon_traced_at_spawn{false};
        bool spawn_weapon_traced_after{false};

        // The sword's smoothed render position. The core interpolates position only and holds extras from the older
        // snapshot, so these targets step at the send rate while the redraw runs far faster. One segment: when the
        // target steps, glide from where the sword is drawn to the new target over the observed step interval; an
        // exponential chase lurches at every step.
        double render_weapon_x{}, render_weapon_y{}, render_weapon_z{};
        // The segment being glided: from -> to over [start_ms, start_ms + dur_ms].
        double weapon_seg_from_x{}, weapon_seg_from_y{}, weapon_seg_from_z{};
        double weapon_seg_to_x{}, weapon_seg_to_y{}, weapon_seg_to_z{};
        // No rotation fields: the sword's rotation is written straight through, since the turn direction cannot be
        // reconstructed from these samples.
        int64_t weapon_seg_start_ms{0};
        int64_t weapon_seg_dur_ms{0};
        // When the previous target step arrived, for measuring the inter-step interval.
        int64_t weapon_target_seen_ms{0};
        bool weapon_render_primed{false};

        // What we wrote last frame, so the next frame reads the location before writing and sees whether anything
        // moved it between: a readback right after our own write cannot see drift.
        double last_written_weapon_x{}, last_written_weapon_y{}, last_written_weapon_z{};
        bool weapon_write_recorded{false};

        // last_weapon_spawn_attempt_tick throttles creating the flyer to once per LOG_INTERVAL_TICKS.
        std::string last_failed_weapon_class;
        uint64_t last_weapon_spawn_attempt_tick{0};

        // The MIRRORED_EFFECTS keys active on the peer, comma-joined and resolved against the local table, so no asset
        // path crosses the wire. The full set comes every update, and empty retires whatever is playing.
        std::string target_vfx;

        // Live components this ghost plays, by wire key: created on a rising edge, deactivated on a falling one. A
        // level transition destroys them with the ghost, and the staleness check rebuilds it.
        std::unordered_map<std::string, RC::Unreal::UObject*> vfx_components;

        // One-shot rows (world_spawned) latch to a counter, not to their key's presence: rapid hops overlap their
        // bursts, so the key never leaves the set and a level would deliver one burst for the whole spree. A dropped
        // datagram still costs at most one burst. A pulse-with-hold on the sender fails exactly when hops are fastest.
        std::unordered_map<std::string, double> vfx_counts;

        // The one-shot bursts recently spawned on this ghost, newest last. Local detection excludes our own components
        // by identity, so a burst held nowhere would echo back onto the ghost. A ring, since rapid hops keep several
        // alive; bounded, since they destroy themselves unannounced (a stale entry at worst masks one reused address).
        std::vector<RC::Unreal::UObject*> recent_one_shot_components;

        // False until this peer's first update: the first sample baselines every counter without firing anything.
        bool vfx_counts_baselined{false};

        // Montage mirror: whatever montage plays (the throw among them) is sent, since state values do not change
        // during one; the count works like target_land_count, so a montage between two sends is not lost.
        std::string target_montage;
        double target_montage_count{0};
        double last_seen_montage_count{0};

        // The stop half of the montage mirror (see montage_stop_count), same counter and baselining.
        double target_montage_stop_count{0};
        double last_seen_montage_stop_count{0};

        // Throttles the warning for a montage path that does not resolve here; a one-shot has nothing to retry.
        std::string last_failed_montage;
        uint64_t last_montage_warn_tick{0};

        // The last in-bubble value pushed to this ghost, so StartBubbleJumpFlash and changeBubbleChargedJump fire once
        // per transition: called per frame they would restart the effect.
        bool ghost_bubble_flash_on{false};
        // The peer's bubble charged-jump flag: how long the effect lasts is the game's business.
        bool target_bubble_charged{false};

        // Diagnostic: ticks left to read the ghost's own playing montage back after a CustomPlayMontage call, telling
        // "never started" (nothing at t+0) from "started and stopped" (present, then gone).
        uint32_t montage_readback_ticks_left{0};

        // GHOST_SELF_MONTAGE_PROBE: the montage the ghost's anim instance last reported, so it logs on change.
        bool self_probe_initialized{false};
        std::string self_probe_prev_montage;

        // MONTAGE_CATALOG_PROBE: the index into CATALOG_PROBE_MONTAGES and when the current entry started, so the
        // probe advances on its own interval.
        size_t catalog_probe_index{0};
        uint64_t catalog_probe_last_tick{0};
        bool catalog_probe_started{false};

        // ANIM_TRACE: the state last written to this ghost, so its timeline logs on change beside the player's.
        bool anim_trace_initialized{false};
        int anim_trace_prev_move_state{-1};
        int anim_trace_prev_action_state{-1};
        int anim_trace_prev_movement_mode{-1};
        int anim_trace_prev_anim_jump_type{-1};

        // Landing/jump pulses through animBPref's landed?/jumped? (the anim instance's, not the pawn's), as counters:
        // a single-tick pulse is lost between sends, and the receiver fires on any increase.
        double target_land_count{}, target_jump_count{};
        double last_seen_land_count{}, last_seen_jump_count{};
        // Ticks left to hold landed?/jumped? true on the ghost's AnimBP after a rising edge, so its update graph cannot
        // overwrite a single-tick write before the state machine sees it (PULSE_HOLD_TICKS).
        uint32_t landed_hold_ticks{0}, jumped_hold_ticks{0};

        // Trail pulses, the same counter shape: any increase calls call_spawn_after_image on this ghost once.
        double target_afterimage_count{};
        double last_seen_afterimage_count{};
        // The burst size from the sender's own game; a wrong count leaves extra afterimages lingering after a slide.
        double target_afterimage_spawn_n{};

        // The peer's capsule half-height. A Character's location is its capsule centre, and a slide or crouch
        // shrinks the capsule and drops the centre with feet planted, so a full-height ghost there sinks into the
        // floor. It drives the ghost's mesh offset and doubles as the slide signal.
        double target_capsule_half{};
        // Monotonic-clock time this peer was last seen shrunk, for the slide-seam hold where target_capsule_half is
        // assigned. 0 means never seen shrunk, not shrunk long ago.
        uint64_t last_shrunk_ms{};
        // The peer's point on the slide Timeline's curve (1.0 standing, toward 0 mid-slide), driven onto the ghost
        // with the Blueprint's own Timeline update (SLIDE_TIMELINE_TRACK).
        double target_slide_t{1.0};

        // POSE_WINDOW_TRACE: ticks left to log after a pose transition, the only view of which value moves late and
        // by how many frames.
        uint32_t pose_window_ticks_left{0};
        bool pose_window_prev_shrunk{false};

        // Edge state for GHOST_CROUCH_EVENT_CALL: K2_OnStartCrouch and K2_OnEndCrouch fire once per pose change.
        // Reset with the other per-ghost latches, since a replacement pawn starts standing.
        bool crouch_event_shrunk{false};
        // Latched when the crouch starts, so K2_OnEndCrouch gets the same magnitude; computed on stand-up it is 0.
        float crouch_half_height_adjust{0.0f};
        // Same edge, for GHOST_CROUCH_INPUT_CALL.
        bool crouch_input_shrunk{false};
        // Rotates the release candidate per stand-up so one session tests all three.
        uint32_t release_candidate_index{0};

        // Last values GHOST_MESH_Z_TRACE printed, so it logs on change: what we asked for and what the property reads
        // back, which can change independently.
        double last_traced_mesh_z{-999999.0};
        double last_traced_desired_z{-999999.0};
        // The ghost's own last-seen health, for HEALTH_TRACE.
        double last_seen_ghost_health{-1.0};

        // Cling-gem trigger edge: moveState 4 marks a cling and is already mirrored, so this fires once per cling.
        uint8_t last_wallrun_move_state{0};

        // Trail colour, written to the ghost's afterimageColor just before its burst, so the burst takes the sender's
        // colour. afterimage_color_valid stays false until a real value arrives, leaving the ghost's own colour alone.
        float target_afterimage_color[4]{};
        bool afterimage_color_valid{false};

        // No re-entrancy flag: game_thread_tick runs on the game thread, so SpawnActor is synchronous and `ghost` is
        // set before ensure_ghost_spawned returns.
    };

    class Plugin : public RC::CppUserModBase
    {
      public:
        Plugin();
        ~Plugin() override;

        auto on_unreal_init() -> void override;

        // Runs on UE4SS's own update thread, not the game thread: the bridge and the queue for game_thread_tick.
        auto on_update() -> void override;

      private:
        auto handle_bridge_line(const std::string& line, RC::Unreal::UObject* local_pawn, RC::Unreal::UObject* local_controller) -> void;

        // Creates, updates and positions one ghost's nametag every tick, with no engine call when the name and colour
        // are unchanged. viewer_override is the camera's location; null falls back to the local pawn, which leans the
        // tag whenever the camera is not level with the player.
        auto update_ghost_nametag(RemoteGhost& entry, RC::Unreal::UObject* local_pawn, const std::string& player_id,
                                  const RC::Unreal::FVector* viewer_override) -> void;

        // Spawns a clone of the local player's pawn class (SPAWN_BASED_GHOSTS), then re-possesses the real player,
        // since the clone auto-possesses.
        auto ensure_ghost_spawned(const std::string& player_id, RC::Unreal::UObject* local_pawn, RC::Unreal::UObject* local_controller) -> void;

        // The SPAWN_BASED_GHOSTS=false fallback: repurposes a StaticMeshActor already in the player's world as the
        // ghost, spawning nothing.
        auto ensure_ghost_hijacked(const std::string& player_id, RC::Unreal::UObject* local_pawn) -> void;

        // Renders one remote's thrown Dream Breaker through the flyer component; its own lifetime and smoothing state
        // keep it out of the redraw loop.
        auto tick_remote_weapon(const std::string& player_id, RemoteGhost& remote, RC::Unreal::UWorld* current_world) -> void;

        // Cycles every loaded Niagara system onto one ghost, one at a time (VFX_CATALOG_PROBE).
        auto tick_vfx_catalog_probe(RC::Unreal::AActor* ghost) -> void;

        // Plays the peer's own effects on its ghost, keyed by the wire's `vfx` list (MIRRORED_EFFECTS).
        auto tick_remote_mirrored_vfx(const std::string& player_id, RemoteGhost& remote) -> void;

        // Shows or hides a ghost's empty-hand recall glow.
        auto tick_remote_recall_glow(const std::string& player_id, RemoteGhost& remote) -> void;

        // Two-sample capture of a ghost spawning mid-throw (GHOST_SPAWN_WEAPON_TRACE).
        auto tick_ghost_spawn_weapon_trace(const std::string& player_id, RemoteGhost& remote) -> void;

        // Diffs the world around a deliberate Spawn After Image call on a ghost (AFTERIMAGE_DISCOVERY).
        auto tick_afterimage_discovery(RC::Unreal::AActor* ghost) -> void;

        // Destroys a remote's ghost (GHOST_DESTROY_ON_DESPAWN; parked at DESPAWN_PARK_Z if the call is not reflected)
        // and everything spawned for it, and stops tracking it.
        auto release_ghost(const std::string& player_id) -> void;

        // Resolves and hooks the pause menu's Reset button, retried cheaply until it lands, since the widget class
        // need not exist at boot.
        auto try_hook_pause_reset() -> void;

        // Logs every array property length on the game's singletons and what changed since the last capture
        // (dump_arrays.txt).
        auto census_singleton_arrays(const wchar_t* label) -> void;

        // Counts live objects per class around a spawn/destroy pair, so an object the ghost leaves behind shows as a
        // count that never comes back down.
        auto census_object_counts(const wchar_t* label) -> void;
        std::map<std::string, int> last_object_census;
        std::map<std::string, std::string> last_object_refs;
        std::map<std::string, int> last_array_census;
        auto release_all_ghosts(const wchar_t* reason) -> void;

        // Releases every ghost when the bridge drops: neither despawn_remote nor LoadMap PRE comes when the core
        // closes, and a ghost would stand frozen. Game thread only; on_update arms it on the disconnect edge.
        auto release_all_ghosts_parked(const wchar_t* reason) -> void;

        auto log_remote_state(const wchar_t* context) -> void;

        // All actor work, from an EngineTick post-hook, which runs on the game thread: on_update does not, and a
        // write from there reads back fine and never reaches the screen.
        auto game_thread_tick() -> void;

        // The input track: what the player pressed, as edges of an action bitmask plus the sticks, sent to the core as
        // input_sample batches. Sampled on the game thread each engine frame, drained and sent on UE4SS's thread; the
        // queue and drop counter are the shared state, under state_mutex.
        auto input_track_sample(RC::Unreal::UObject* controller, RC::Unreal::UObject* pawn) -> void;
        auto input_track_drain_and_send() -> void;

        // Keeps the camera off a spawned ghost: SetViewTargetWithBlend is native, so a RegisterPreHook on the function
        // itself (a ProcessEvent filter never sees it) rewrites NewViewTarget in the engine's own argument buffer.
        auto register_camera_fightback_hook() -> void;

        // Neutralises damage whose causer is one of our ghosts, at the engine's entry points (GHOST_DAMAGE_GUARD).
        auto register_damage_guard_hooks() -> void;

        // Neutralises a camera fade raised by a ghost's own spawn (GHOST_FADE_GUARD).
        auto register_fade_guard_hook() -> void;

        // Refuses the outline at its source: a pre-hook on the native SetRenderCustomDepth rewrites bValue to false
        // for a BP_AfterImage_C copied from one of our ghosts. A per-tick strip is a frame late by construction, so it
        // stays only as the backstop for an image whose copyActor is not yet set.
        auto register_afterimage_outline_guard() -> void;
        auto register_object_registry_feed() -> void;
        auto register_playerlocation_guard() -> void;
        auto register_bound_stick_hook() -> void; // the driven ghost's IA_Move bound value
        auto register_audio_listener_guard() -> void;

        // Spawns, drives and destroys the effect that stands in for a peer's ranged projectile.
        auto tick_remote_projectile(const std::string& player_id, RemoteGhost& remote, RC::Unreal::UWorld* current_world) -> void;

        // Guards the state the bridge thread (on_update) and the game thread (game_thread_tick) both touch.
        std::mutex state_mutex;
        std::vector<std::string> pending_incoming_lines; // filled by on_update, drained by game_thread_tick
        size_t pending_collapse_at = 2048; // on_update collapses the queue past this (PENDING_LINES_COLLAPSE_AT)
        std::string cached_local_state_json;             // built by game_thread_tick, sent by on_update
        // The disconnect handoff: on_update sets the flag on the connected->disconnected edge, and game_thread_tick
        // releases the ghosts.
        bool bridge_was_connected{false};
        bool bridge_disconnect_cleanup_pending{false};

        // Local landed?/jumped? counters, one per rising edge of animBPref's flags (prev_*_raw detect the edge). Never
        // reset: a counter needs no clear-after-send handoff between threads.
        uint32_t landed_count{0}, jumped_count{0};
        bool prev_landed_raw{false}, prev_jumped_raw{false};

        // The local half of the montage mirror: one count per start of a different, non-empty montage. An ending is
        // not replayed, since the ghost's copy runs out on its own.
        uint32_t montage_count{0};
        std::string prev_local_montage;

        // Montage ends, counted the same way: a montage the game cuts short (letting go of a ledge) would otherwise
        // leave the ghost holding the pose.
        uint32_t montage_stop_count{0};

        // Diagnostic: edge state of the pawn's spawnTrackingParticles? for ABILITY_FIELD_TRACE, which logs its onset
        // and offset each tick rather than at the trace cadence.
        bool prev_spawn_tracking_particles{false};

        // Diagnostic throw trace: the last values the player's throw could show up in, so it logs per change and
        // catches the wind-up before weaponEquipped? flips. throw_trace_montage_getter_ok latches a missing getter.
        bool throw_trace_initialized{false};
        bool throw_trace_schema_dumped{false};
        bool throw_trace_montage_getter_ok{true};
        bool throw_trace_prev_weapon_equipped{false};
        bool throw_trace_prev_weapon_ref_valid{false};
        int throw_trace_prev_move_state{-1};
        int throw_trace_prev_action_state{-1};
        int throw_trace_prev_anim_jump_type{-1};
        std::string throw_trace_prev_montage;

        // The local trail trigger: afterImagesToSpawn, the int the game itself sets when it decides to trail, so it
        // cannot false-positive the way actionState heuristics did. afterimage_count is the wire counter;
        // afterimage_spawn_n carries the real burst size.
        uint32_t afterimage_count{0};
        int32_t afterimage_spawn_n{0};
        int32_t prev_local_afterimages_to_spawn{0};
        // Real-slide edge: a plain slide is actionState 1 with the capsule shrunk, a physical marker, where the
        // actionState and animJumpType pairs overlap between moves.
        bool prev_local_sliding{false};
        // Re-fire throttle for a held slide, so the ghost's trail lasts as long as the real one.
        uint64_t last_slide_refire_tick{0};
        // The tick the current slide started: re-fires stop early, since a slide's length is fixed and each image
        // outlives its spawn, so late images would linger past the slide's end.
        uint64_t slide_start_tick{0};

        // The in-bubble trail (moveState 7 with movementMode 5), where afterImagesToSpawn stays 0 and the capsule never
        // shrinks, so neither trigger above sees it. It re-fires while the state is held; bubble_enter_tick bounds it,
        // since sitting in a bubble can outlast the real trail.
        bool prev_local_bubble_in_bubble{false};
        uint64_t last_bubble_refire_tick{0};
        uint64_t bubble_enter_tick{0};
        // The post-jump "boost available" window: plain falling in every field, so known only by having just left the
        // bubble. Cleared on the boost (animJumpType 2) or on landing.
        bool boost_window_active{false};
        // BUBBLE_FX_DIFF: the local pawn's last property snapshot, kept only while the bubble effect shows. The
        // std::wstring keys keep this header free of the SDK's string typedef; they are the same type on this build.
        std::map<std::wstring, std::wstring> bubble_fx_prev_snapshot;
        uint64_t bubble_fx_last_sample_tick{0};

        // SLIDE_PROPERTY_DIFF: a snapshot of the standing pawn, diffed against one a few ticks into a slide or crouch;
        // whatever the game flips to shrink her is in that diff.
        std::map<std::wstring, std::wstring> slide_diff_standing_snapshot;
        // 0 = nothing pending; otherwise the tick to take the shrunk sample, a few past the edge so the pose settles.
        uint64_t slide_diff_capture_at{0};
        bool slide_diff_pending_is_crouch{false};
        bool slide_diff_prev_shrunk{false};
        // Three of each, so a long session cannot fill the log.
        int slide_diff_slides_left{3};
        int slide_diff_crouches_left{3};

        // GHOST_SLIDE_DIFF: the same diff on a ghost while its peer slides. What changes on the player but not the
        // ghost is state the ghost is missing.
        std::map<std::wstring, std::wstring> ghost_diff_standing_snapshot;
        uint64_t ghost_diff_capture_at{0};
        bool ghost_diff_prev_shrunk{false};
        int ghost_diff_left{3};

        // One-shot latch for the pose-function name dump (GHOST_SLIDE_CALL).
        bool ghost_pose_fns_dumped{false};

        // BLINK_FX_SEARCH: one-shot latch, so the filtered dump prints once per session.
        bool blink_fx_search_done{false};

        // The bubble charged-jump flag: the local value's last state, so its edges log once each, and the property's
        // name, found once by searching the pawn's bools (empty: this build has none, and the ghost falls back to the
        // in-bubble state).
        bool prev_local_bubble_charged{false};
        bool bubble_charge_prop_searched{false};
        std::wstring bubble_charge_prop_name;

        // POLE_ROTATION_TRACE: the last quantised sample, so it logs per change; reset on leaving the flying mode.
        bool pole_trace_initialized{false};
        int pole_trace_prev_yaw{0};
        int pole_trace_prev_vm_yaw{0};
        int pole_trace_prev_x{0};
        int pole_trace_prev_y{0};

        // HEALTH_TRACE: local and ghost health recorded independently and on change, so damage that reaches a ghost
        // can be told from damage that reaches the player.
        double prev_local_health{-1.0};
        bool health_names_logged{false};

        // TRAIL_TRIGGER_TRACE: the last local afterimageColor, so a change is edge-logged rather than sampled.
        float prev_local_afterimage_color[3]{-1.0f, -1.0f, -1.0f};

        // TRAIL_TRIGGER_TRACE: the last ultra-state candidates, edge-logged, since an ultra hop's window is short
        // enough for a periodic sample to miss.
        bool prev_ultra_cap{false};
        double prev_full_ultra_modifier{-1.0};
        double prev_capped_ultra_modifier{-1.0};
        int32_t prev_anim_jump_type{-1};

        // WALLRIDE_TRACE: the last cling and wall-ride state, edge-logged, to learn what the game's wall-run logic
        // reads during a real wall ride.
        bool prev_wallride_button_held{false};
        bool prev_can_wall_run{false};
        int32_t prev_current_wall_run_clings{-1};
        bool prev_wallride_vfx_valid{false};

        // WEAPON_ACTOR_TRACE: prev_weapon_ref is only compared for identity, never dereferenced after its tick, so a
        // destroyed thrown weapon cannot be followed into freed memory; the logged transform is kept as doubles.
        RC::Unreal::UObject* prev_weapon_ref{nullptr};
        bool weapon_ref_value_dumped{false};
        bool prev_weapon_equipped_for_actor_trace{true};
        uint64_t weapon_actor_sweep_due_tick{0}; // 0 = no sweep pending
        double weapon_actor_last_logged_x{0.0}, weapon_actor_last_logged_y{0.0}, weapon_actor_last_logged_z{0.0};
        bool weapon_actor_transform_logged{false};

        // VFX_WATCH: the Niagara effects live on the local player as "asset | instance" strings, so appearances and
        // disappearances edge-log. Strings, not pointers: these short-lived objects' addresses get recycled.
        std::set<std::string> prev_player_vfx;

        // Whether the real recall glow shows on the local player, sampled every RECALL_GLOW_SCAN_INTERVAL_TICKS and
        // sent, so a ghost mirrors the game's decision rather than a reimplementation of its rule.
        bool local_recall_glow{false};

        // AFTERIMAGE_DISCOVERY: the "before" set, by full object name, since a recycled address would make a reused
        // object look new.
        std::set<std::string> afterimage_before;
        // The previous probe's post-call snapshot, so an object created later than the sample delay is still
        // attributed rather than only inflating the totals.
        std::set<std::string> afterimage_prev_after;
        bool afterimage_dumped{false};
        // Afterimages already logged, by full name, so each is reported once.
        std::set<std::string> afterimage_colors_logged;

        // Afterimages alive on the local player, by full name, rebuilt each scan so reclaimed images drop out. Drives
        // the trail trigger and its colour.
        std::set<std::string> local_afterimages_seen;
        // TRAIL_COLOR_TRACE: every afterimage reported, local or ghost, so each logs once; local_afterimages_seen is
        // pruned, and a pruned name reappearing would log twice.
        std::set<std::string> local_afterimages_traced;
        // TRAIL_COLOR_TRACE: full name -> (tick first seen, local or not), erased and reported when an image
        // disappears, which yields each side's afterimage lifetime.
        std::map<std::string, std::pair<uint64_t, bool>> afterimage_lifetimes;
        // Last known position per pooled afterimage: the pool re-uses actors and never destroys them, so a move is the
        // real spawn signal. Bounded by the pool, which is small and fixed per level.
        std::map<std::string, std::tuple<double, double, double>> afterimage_last_pos;
        // Whether a real afterimage colour has been observed yet: until then the pawn's afterimageColor is the
        // fallback; afterwards the latched per-burst colour stands, and no per-tick read may overwrite it.
        bool afterimage_have_observed_color{false};
        // The latched per-burst colour, written only together with afterimage_count, since the two describe one burst.
        float latched_afterimage_color[3]{};

        // AFTERIMAGE_OBSERVE_COLOR: a burst has fired and waits a few ticks for the game to spawn its images, so the
        // wire event carries the colour the game used.
        bool afterimage_color_burst_pending{false};
        uint64_t afterimage_color_burst_tick{0};
        uint64_t afterimage_color_burst_next_scan_tick{0};
        int32_t afterimage_color_burst_n{0};
        // Accumulated over the burst's observation window and reset when a burst starts: a burst spawns over many
        // ticks, and any part left over would be credited to the next one.
        float afterimage_color_burst_color[3]{};
        bool afterimage_color_burst_have{false};
        bool afterimage_color_burst_special{false};
        int afterimage_color_burst_new_total{0};
        int afterimage_color_burst_rejected_far{0};
        int afterimage_color_burst_scans{0};
        // Last known position per pooled afterimage, keyed by pointer so a scan builds no name string per object. Keys
        // are only compared, never dereferenced, and the map is cleared on a level transition.
        std::map<RC::Unreal::UObject*, std::tuple<double, double, double>> afterimage_pos_by_ptr;
        // Separate logging budgets, since a shared one is spent by routine sliding before the rare event arrives.
        int afterimage_color_observe_logged{0};
        int afterimage_color_burst_logged{0};
        int afterimage_color_special_logged{0};
        int afterimage_color_idle_logged{0};

        // The idle scan (AFTERIMAGE_OBSERVE_SPECIAL_TRIGGER): the ultra hop never sets afterImagesToSpawn, so no burst
        // window opens for it. `primed` stops the first scan reading the whole unseen pool as one spawn.
        uint64_t afterimage_idle_next_scan_tick{0};
        uint64_t afterimage_idle_last_emit_tick{0};
        bool afterimage_pos_primed{false};

        // The pawn's ordinary trail colour at the last read: the trigger's emit runs before the pawn read, and a burst
        // that observed nothing must fall back to this, not inherit the previous burst's colour.
        float last_pawn_baseline_color[3]{};
        bool last_pawn_baseline_color_valid{false};
        uint64_t afterimage_probe_tick{0};
        bool afterimage_probe_pending{false};

        // VFX_CATALOG_PROBE: the catalog, built once and cycled, and the effect showing now, destroyed when the next
        // starts so only one is on screen at a time.
        std::vector<std::string> vfx_probe_catalog;
        bool vfx_probe_catalog_built{false};
        size_t vfx_probe_index{0};
        uint64_t vfx_probe_last_switch_tick{0};
        RC::Unreal::UObject* vfx_probe_component{nullptr};

        // WEAPON_LANDING_TRACE: a one-shot dump of the thrown weapon, and the last values on the local player's thrown
        // weapon, so a landing logs once; the negative sentinels are outside any real value.
        bool weapon_landing_reflection_dumped{false};
        // One-shot latch for dumping the real landed sword's idleGlowVFX component.
        bool weapon_glow_dumped{false};
        int32_t prev_local_weapon_state{-1};
        int32_t prev_local_weapon_embedded{-1};
        double prev_local_weapon_mesh_offset[3]{-99999.0, -99999.0, -99999.0};

        bool unreal_ready{false};
        // Atomic, because both threads advance it. Not a frame counter: in normal play only on_update, UE4SS's
        // polling thread, advances it, regardless of frame rate; game_thread_tick's early returns add to it while
        // paused or quiet. Every window and throttle that reads it was judged at that rate.
        std::atomic<uint64_t> tick_count{0};

        // Dev diagnostic: what changed on the local player when a ghost spawned. Scalar properties are snapshotted
        // before the spawn and a moment after, and only what moved is printed; scalars only, since following an
        // object-valued property can crash the game.
        std::map<std::string, std::string> pre_spawn_player_state;
        std::map<std::string, std::string> pre_spawn_shared_state;

        // The level's own post-process, struct fields included, where a scene-wide brightness change would live.
        std::map<std::string, std::string> pre_spawn_scene_state;

        // The local player's own PlayerLight, LightMesh and PointLight (snapshot_local_light_state).
        std::map<std::string, std::string> pre_spawn_light_state;
        uint64_t state_diff_due_tick{0};
        bool state_diff_pending{false};
        uint64_t ticks_since_ready{0};
        // Ticks since the local pawn last became valid (0 while it is not, as at the title screen); gates
        // SPAWN_DELAY_TICKS in ensure_ghost_spawned, so the player's camera settles before any ghost exists.
        uint64_t ticks_since_pawn_valid{0};
        // POSSESS_TRACE: keep reporting who holds the controller until this tick, so an
        // auto-possess that fires a frame or two after a ghost spawn is still caught.
        uint64_t possess_watch_until_tick{0};
        // The last camera target the game chose that was not a ghost's rig, used only to undo a ghost-owned switch;
        // a "last known good" cache applied to every change becomes the bug it guards against.
        RC::Unreal::AActor* last_non_ghost_view_target{nullptr};
        // The tick a ghost last spawned, arming a short camera guard (GHOST_SPAWN_CAMERA_GUARD_TICKS).
        uint64_t ghost_spawn_camera_guard_tick{0};
        bool camera_rig_dumped{false};
        std::unique_ptr<BridgeClient> bridge;
        // Starts meshghost.exe when none answers. Declared after bridge so it is destroyed first, stopping the core
        // before its socket goes.
        std::unique_ptr<CoreLauncher> core_launcher;
        std::unordered_map<std::string, RemoteGhost> remotes;

        // A replay ghost's streamed input track (remote_input), by player id, outside `remotes` because a window can
        // arrive before the ghost's first render. Game thread only. Cleared by a `reset` line, by despawn_remote and
        // by releasing every ghost: the pawn the edges were for is gone in all three.
        struct GhostInputEdge
        {
            uint64_t f;
            int64_t t;
            uint32_t m;
            double ax[8];
            int ax_n;
            double at; // render-clock ms, the core's `at`
        };
        struct GhostInputTrack
        {
            std::vector<std::string> labels;
            std::vector<std::string> axes;
            std::string source;
            std::deque<GhostInputEdge> edges; // in order; applied from the front
            uint32_t mask{0};                 // the state after the last applied edge
            double ax[8]{};
            int ax_n{0};                      // how many axes the track's edges carry
            bool have_state{false};
            uint32_t dropped{0};              // edges refused by the cap since the last reset
            bool drop_logged{false};
            uint64_t applied_at_tick{0};      // the tick the last edge applied on (trace)
        };
        static constexpr size_t GHOST_INPUT_EDGE_CAP = 4096; // per ghost; a 500 ms window is a few hundred
        std::unordered_map<std::string, GhostInputTrack> ghost_inputs;

        // A peer's chosen nametag, by player id, outside `remotes`: it arrives once, often before the peer's first
        // position, and creating the ghost entry early breaks is_new_remote. Erased on despawn_remote, so the next
        // holder of that player id inherits no name.
        struct Nametag
        {
            std::string name;
            std::string color; // "#RRGGBB", or empty for the component's own default
        };
        std::unordered_map<std::string, Nametag> nametags;
        std::unordered_set<RC::Unreal::AActor*> hijacked_actors; // prevents two remotes sharing one prop
        RC::Unreal::UWorld* last_logged_world{nullptr};

        // Local halves of the hurt and death counters (MIRROR_HURT_REACTION, MIRROR_DEATH_FADE). Members, so LoadMap
        // PRE can reset the baselines: CurrentHp is a GameInstance singleton a save swap rewrites, and a stale baseline
        // reads as damage. The counters are never reset, since a receiver that saw a higher value would swallow hurts.
        int local_hurt_count{0};
        int local_death_count{0};
        double local_last_seen_hp{-1.0}; // -1 = no baseline; first read only primes, never compares
        bool local_was_dead{false};
        // The death count a chaser_reset was last sent for, so one death sends one.
        int chaser_reset_death_count{0};

        // The camera guard rewrites the engine's own argument buffer in place, so it needs no deferred state.
        RC::Unreal::UFunction* svtwb_function{nullptr}; // cached "SetViewTargetWithBlend", found once

        // Never hook 'Spawn After Image' or 'spawnNumAfterimages': they are Blueprint functions, and RegisterPreHook
        // swaps the pointer they share with every Blueprint function, which crashed the game. The trail trigger
        // polls instead (afterimage_count).

        // Callback and hook ids, so ~Plugin can unregister every detour that captures this Plugin. Stored as the
        // primitive types (Hook::GlobalCallbackId is uint64_t, RC::Unreal::CallbackId int32_t) to keep
        // <Unreal/Hooks.hpp> out of this header. Hook::ERROR_ID (0) means never registered; -1 does for a UFunction
        // hook.
        uint64_t load_map_pre_callback_id{0};

        // The same-level reload signal: reloading a save into the current level fires InitGameState, which builds a new
        // game state, but not LoadMap PRE, so the teardown LoadMap PRE does gets a second chance here.
        uint64_t init_game_state_pre_callback_id{0};

        // RESET_FN_PROBE. Off unless `log_reset_fns.txt` is present.
        uint64_t reset_fn_probe_callback_id{0};
        // The damage-vocabulary probe (log_damage_fns.txt), unregistered beside the reset one: a ProcessEvent callback
        // outliving the mod is a call into freed code.
        uint64_t damage_fn_probe_callback_id{0};

        // The pause menu's Reset button, the only signal that precedes a reset (found with RESET_FN_PROBE). Hooked only
        // with guard_hook.txt present, and observe-only unless guard_destroy.txt is too.
        uint64_t pause_reset_hook_id{0};

        // A hook on the pause menu opening; never registered.
        uint64_t pause_open_hook_id{0};

        // No ghost spawns until this tick: set by the guarded Reset click, LoadMap PRE and InitGameState PRE.
        uint64_t suppress_ghost_spawn_until_tick{0};

        // The mod does nothing at all until this tick, set with the spawn hold: the tick calls game functions on
        // actors a teardown destroys underneath it.
        uint64_t quiet_until_tick{0};

        // Edge latch for the pause-menu ghost clear; see the tick.
        bool pause_ghosts_cleared{false};
        // The last player_frozen value sent to the core; reset at every hello, so a core that attaches mid-pause is
        // told on the next tick.
        bool player_frozen_sent{false};
        // The input track's state: one edge per change of the mask or (throttled) the axes; `button` marks a mask
        // change, which the queue never drops for an axis-only edge. f counts engine frames, t is monotonic
        // milliseconds; the core keeps both beside its own receipt stamp.
        struct InputEdgeRec
        {
            uint64_t f;
            int64_t t;
            uint32_t m;
            double ax[6]; // INPUT_TRACK_AXIS_COUNT: move_x, move_y, look_x, look_y, cam_yaw, cam_pitch
            bool button;
        };
        std::deque<InputEdgeRec> input_edges; // under state_mutex
        uint32_t input_drops{0};              // under state_mutex: edges the queue refused since the last batch
        uint64_t input_frame{0};              // game thread only
        uint32_t input_prev_mask{0};          // game thread only
        double input_prev_ax[6]{};            // game thread only
        int64_t input_last_axis_ms{0};        // game thread only
        bool input_cam_resolved{false};       // game thread only: the camera manager answered at least once
        bool input_cam_refused{false};        // game thread only: it never did in 600 samples -> cam axes stay 0
        uint32_t input_cam_misses{0};         // game thread only: samples with no camera before the first answer
        bool input_have_prev{false};          // game thread only; false again whenever the core is not ready
        bool input_labels_sent{false};        // on_update thread only; false again at every hello
        uint64_t input_edges_sent{0};         // on_update thread only
        uint64_t input_batches_sent{0};       // on_update thread only
        uint64_t input_jump_agree{0};         // game thread only: the live check of the value read
        uint64_t input_jump_disagree{0};      // game thread only
        uint64_t engine_tick_post_callback_id{0};
        int32_t svtwb_hook_id{-1};
        int32_t fade_hook_id{-1};
        // The UFunction each RegisterPreHook went on, so ~Plugin can take it off: UnregisterHook is a method on the
        // function, and every hook lambda captures `this`, so one left installed calls through a dangling Plugin.
        RC::Unreal::UFunction* fade_function{nullptr};
        RC::Unreal::UFunction* pause_reset_function{nullptr};
        RC::Unreal::UFunction* srcd_function{nullptr}; // cached "SetRenderCustomDepth", found once
        int32_t afterimage_outline_hook_id{-1};
        // UE4SS's StaticConstructObject post-callback, which feeds the object registries (ObjectRegistry). Not a hook
        // on the Niagara spawn functions, which hangs the game thread when a Blueprint ubergraph calls one.
        uint64_t registry_construct_callback_id{0};

        // MPC PlayerLocation guard: a SetVectorParameterValue pre-hook and the objects it needs. guard_local_* is the
        // player's position, cached each tick; hook and tick share the game thread, so no lock.
        RC::Unreal::UFunction* svpv_function{nullptr}; // cached "SetVectorParameterValue", found once
        int32_t svpv_hook_id{-1};
        RC::Unreal::UFunction* bsv_function{nullptr}; // cached "EnhancedInputLibrary:GetBoundActionValue", found once
        int32_t bsv_hook_id{-1};
        RC::Unreal::UObject* mpc_player_related{nullptr}; // cached MPC asset, found lazily
        double guard_local_x{0.0};
        double guard_local_y{0.0};
        double guard_local_z{0.0};
        bool guard_local_valid{false};

        // Audio listener guard: a SetAudioListenerAttenuationOverride pre-hook, since every ghost, a clone of the
        // player's pawn, pins the listener to its own capsule on BeginPlay. The counter logs the first few corrections.
        RC::Unreal::UFunction* salao_function{nullptr}; // "SetAudioListenerAttenuationOverride"
        int32_t audio_listener_hook_id{-1};
        int32_t audio_listener_corrections{0};

        // Afterimage attribution, shared by the SetRenderCustomDepth pre-hook and the per-tick sweep (both on the game
        // thread). By actor pointer, since the pool re-uses actors; one that moves was re-used and is re-attributed.
        // owner_ghost is the ghost the image was copied from, or nullptr for the player's own.
        struct AfterimageOwner
        {
            RC::Unreal::UObject* owner_ghost{nullptr};
            double x{0.0}, y{0.0}, z{0.0};
        };
        std::map<RC::Unreal::UObject*, AfterimageOwner> afterimage_owners;

        // Images whose custom-depth enable was refused before they could be attributed (copyActor still null at the
        // call). The sweep attributes them a tick later and re-enables any that are the player's own, so the failure is
        // one outline-less frame on a player image rather than one outlined frame on a ghost's.
        std::map<RC::Unreal::UObject*, std::set<RC::Unreal::UObject*>> afterimage_pending_reenable;

        // The tick a ghost last spawned, so a camera fade raised right after is attributed to it. 0 = never.
        uint64_t last_ghost_spawn_tick{0};

        // Every damage entry point hooked, with its hook id, so the guard reports once at startup and tears down.
        std::vector<std::pair<RC::Unreal::UFunction*, int32_t>> damage_hook_ids{};
    };
} // namespace MeshGhostPseudo
