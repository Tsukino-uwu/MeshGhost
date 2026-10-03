using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // Programs that read the game every frame and choose the next frame's input, for what a model turn is too slow to
    // steer: each a Func<JToken> ticked once a frame like a running request, its input through Keep and Tap.
    public static class Reflexes
    {
        private const float UnreachableDy = 180f;
        // Build C's swing locks; `root_frames` 22 and `combo_root_frames` 40 cover the locks measured every frame.
        private const int RootFrames = 18;
        private const float MeleeReach = 139.5f, MeleeHalfHeight = 34f; // her swing: reach ahead, half height
        private const int ComboRootFrames = 32;
        private const int ComboKeepAfter = 75; // frames since the combo last rose, before its timer runs out
        private const int BackflipWindow = 12; // frames, inside the dodge state a Backflip holds
        private const int DirLead = 2; // frames a Spiral or Upper Slash's direction is held, its Attack frame included
        private const int ChargeTravel = 5; // frames a charge box took from its birth to reach her beside him

        // One enemy, the nearest living one in view (of `type` when given), kept by reference and attacked until
        // beaten: faced and closed on until her swing reaches it, then Attack tapped (ranged: Ranged within
        // `range`); a jump when it is above or she is stuck; Ranged when it stays out of reach. Every move goes through
        // the dodge unless `dodge` is false. `push_orbs` hits a blastorb between her and the target toward it:
        // `orb_mode` passive only one already in her swing or under her, active any.
        public static Func<JToken> Fight(JObject args, int frameLimit, Func<CharacterBase> player, Func<string> mode, Func<bool, JObject> observe)
        {
            string wantType = (string)args["type"];
            float range = (float?)args["range"] ?? 110f;
            // Closer than this she backs off: a boss's shots spawn at its gun, on top of anyone standing close.
            float minRange = (float?)args["min_range"] ?? 0f;
            // `attack`: auto swings whenever her swing reaches the target, on the ground while standing is safe and
            // else from a jump, and shoots while closing in; ranged keeps to `range` and shoots; melee shoots only for
            // `recover_ranged`, `combo_keep` or `orb_shots`.
            string attackMode = (string)args["attack"] ?? "auto";
            if (attackMode != "auto" && attackMode != "melee" && attackMode != "ranged") throw new Exception("attack is auto, melee or ranged");
            string inRangeTap = attackMode == "ranged" ? "Ranged" : "Attack";
            string askedMode = attackMode;
            int stopHp = (int?)args["stop_hp"] ?? 0;
            bool dodge = (bool?)args["dodge"] ?? true;
            // a boss the dodge keeps her away from needs far more
            int noProgressFrames = (int?)args["no_progress_frames"] ?? 300;
            bool pushOrbs = (bool?)args["push_orbs"] ?? true;
            // no combo chaining once the target could attack before the combo ends
            bool chainGuard = (bool?)args["chain_guard"] ?? true;
            // with orb_mode active: Orbitar shots at an orb, from outside its blast or while closing in
            bool orbShots = (bool?)args["orb_shots"] ?? false;
            // Every rule below is a switch defaulting to build C, so a trial changes it per call with no rebuild.
            string orbMode = (string)args["orb_mode"] ?? "passive";
            if (orbMode != "passive" && orbMode != "active") throw new Exception("orb_mode is passive or active");
            int rootFrames = (int?)args["root_frames"] ?? RootFrames, comboRootFrames = (int?)args["combo_root_frames"] ?? ComboRootFrames;
            // `prefer_drop`: when falling turns into a quickdrop. near_target (C: except within 60 of her swing's reach
            // of the target), swing (except while swinging or with the target in her swing), always, or off.
            string preferDrop = (string)args["prefer_drop"] ?? "near_target";
            if (preferDrop != "near_target" && preferDrop != "swing" && preferDrop != "always" && preferDrop != "off") throw new Exception("prefer_drop is near_target, swing, always or off");
            // `beam_gate`: wide (C), narrow or off; see BeamNear.
            string beamGate = (string)args["beam_gate"] ?? "wide";
            if (beamGate != "wide" && beamGate != "narrow" && beamGate != "off") throw new Exception("beam_gate is wide, narrow or off");
            // no tap while an orb flies at her within 500
            bool incomingOrbGate = (bool?)args["incoming_orb_gate"] ?? false;
            // in the red outline, melee only when standing is safe for the whole horizon
            bool armorGate = (bool?)args["armor_gate"] ?? true;
            bool airSwing = (bool?)args["air_swing"] ?? true; // in reach but standing unsafe: swing from a jump
            bool unknownRanged = (bool?)args["unknown_ranged"] ?? true; // a kind with no learned tell fought from range
            float hug = (float?)args["hug"] ?? Dodge.DefaultHug; // how much the dodge prefers ending near the target
            // `tell_filter` (not in C): predict only from states an attack followed at least half the time.
            bool tellFilter = (bool?)args["tell_filter"] ?? false;
            // with tell_filter: thrown-explosive tells kept (Tells.KeepSpawns)
            bool keepSpawnTells = (bool?)args["keep_spawn_tells"] ?? false;
            // `spiral_slash` (Down + Attack in the air, target in her swing and not above) and `upper_slash` (Up +
            // Attack on the ground, target in reach but above her), moves the fight teaches; off by default.
            bool spiralSlash = (bool?)args["spiral_slash"] ?? false;
            bool upperSlash = (bool?)args["upper_slash"] ?? false;
            // `break_launch`: while the target's armor refills (the red outline) and it is in her swing on the ground,
            // the swing is Upper Slash, whatever the height.
            bool breakLaunch = (bool?)args["break_launch"] ?? false;
            // `bar_punish`: while the target plays DAMAGE with no hitstun (as a boss's health bar empties), the swing
            // gates stand aside and a ground swing is Upper Slash; the dodge still vetoes a hit.
            bool barPunish = (bool?)args["bar_punish"] ?? false;
            // `recover_ranged`: while the target's armor refills, a swing becomes an Orbitar shot.
            bool recoverRanged = (bool?)args["recover_ranged"] ?? false;
            // `backflip_dodge`: Backflip when the dodge's chosen plan is still hit within BackflipWindow frames and the
            // dodge meter is full (HaveDodge() at 1 or more).
            bool backflipDodge = (bool?)args["backflip_dodge"] ?? false;
            // The combo counter, reported as max_combo and combo_drops; `combo_keep`: once ComboKeepAfter frames have
            // passed since it last rose and no swing is going out, an Orbitar shot at the target renews it.
            bool comboKeep = (bool?)args["combo_keep"] ?? false;
            int maxCombo = 0, comboDrops = 0, lastCombo = 0, comboRoseAt = Time.frameCount, keepShots = 0;
            int backflips = 0;
            int punishFrames = 0;
            int spirals = 0, uppers = 0, dirFrames = 0, launches = 0;
            string dirHeld = null;
            int pushes = 0, orbFrames = 0;
            var orbLog = new JArray(); // a sample of the orb decisions, every OrbLogEvery frames spent on an orb
            JObject orbNote = null;
            CharacterBase lastOrb = null; // the orb last used, watched for the frame it is sent flying and by what
            float lastOrbSpeed = 0f;

            CharacterBase me = player();
            if (me == null || me.t == null) throw new Exception("no player to fight with");
            if (mode() != "play") throw new Exception("a fight starts in play, not in " + mode());
            CharacterBase target = Nearest(me, wantType);
            if (target == null) throw new Exception("no living enemy in view" + (wantType != null ? " of type " + wantType : ""));

            int start = Time.frameCount, hpStart = me.health, targetHpStart = target.health;
            int attacks = 0, jumps = 0, ranged = 0, hitsTaken = 0, lastHp = me.health;
            float lastX = me.t.position.x;
            int stuckFrames = 0, outOfReachFrames = 0, blockedFrames = 0;
            // where she last stood: reach is measured from there, so a jump does not reset it
            float groundY = me.t.position.y;
            bool landed = false;
            int targetHpSeen = target.health, lastProgress = Time.frameCount;
            string targetType = target.type.ToString();
            var guard = new Guard(me) { Hug = hug };
            int targetId = target.ID;
            Tells.FilterUnreliable = tellFilter;
            Tells.KeepSpawns = keepSpawnTells;

            JObject Done(string outcome)
            {
                Tells.FilterUnreliable = true;
                Tells.KeepSpawns = false;
                CharacterBase p = player();
                return new JObject
                {
                    ["outcome"] = outcome,
                    ["frames"] = Time.frameCount - start,
                    ["target"] = new JObject
                    {
                        ["type"] = targetType,
                        ["id"] = targetId,
                        ["hp_start"] = targetHpStart,
                        ["hp_end"] = target != null ? (JToken)target.health : null,
                    },
                    ["hp_start"] = hpStart,
                    ["hp_end"] = p != null ? (JToken)p.health : null,
                    ["hits_taken"] = hitsTaken,
                    ["attacks"] = attacks,
                    ["ranged"] = ranged,
                    ["jumps"] = jumps,
                    ["dodges"] = guard.Dodges,
                    ["orb_pushes"] = pushes,
                    ["spiral_slashes"] = spirals,
                    ["upper_slashes"] = uppers,
                    ["break_launches"] = launches,
                    ["punish_frames"] = punishFrames,
                    ["backflips"] = backflips,
                    ["max_combo"] = maxCombo,
                    ["combo_drops"] = comboDrops,
                    ["combo_keep_shots"] = keepShots,
                    ["orb_frames"] = orbFrames,
                    ["orb_log"] = orbLog,
                    ["last_dodge"] = guard.LastDodge,
                    ["after"] = observe(false),
                };
            }

            return () =>
            {
                CharacterBase p = player();
                if (p == null || p.t == null) return Done("lost");
                if (p.health < lastHp) hitsTaken++;
                lastHp = p.health;
                if (target == null || target.t == null || !target.gameObject.activeInHierarchy || target.health <= 0)
                {
                    return Done(target != null && target.health <= 0 || landed ? "defeated" : "lost");
                }
                if (target.health < targetHpStart) landed = true;
                if (target.health != targetHpSeen)
                {
                    targetHpSeen = target.health;
                    lastProgress = Time.frameCount;
                }
                if (Time.frameCount - lastProgress >= noProgressFrames) return Done("no_progress");
                if (stopHp > 0 && p.health <= stopHp) return Done("low_hp");
                if (mode() != "play") return Done("mode_changed");
                if (Time.frameCount - start >= frameLimit) return Done("timeout");
                if (Utility.isOutsideCamera(target.t.position, 64f)) return Done("lost");

                Vector3 me3 = p.t.position, it = target.t.position;
                float dx = it.x - me3.x, dy = it.y - me3.y;
                // A kind whose attacks have not been seen yet is fought from range until one has: up close its first
                // attack lands before the dodge knows it.
                if (askedMode == "auto" && unknownRanged)
                {
                    bool known = Tells.Known(target.type.ToString());
                    attackMode = known ? "auto" : "ranged";
                    inRangeTap = known ? "Attack" : "Ranged";
                    if (!known)
                    {
                        range = Math.Max(range, 400f);
                        minRange = Math.Max(minRange, 250f);
                    }
                    else if (range >= 400f)
                    {
                        range = (float?)args["range"] ?? 110f;
                        minRange = (float?)args["min_range"] ?? 0f;
                    }
                }
                int combo = ComboSystem.Instance != null ? ComboSystem.Instance.GetCombo() : 0;
                if (combo > lastCombo) comboRoseAt = Time.frameCount;
                else if (combo < lastCombo && lastCombo >= 2) comboDrops++;
                lastCombo = combo;
                if (combo > maxCombo) maxCombo = combo;
                bool punish = barPunish && target.aniStatus.ToString() == "DAMAGE" && target.GetHitStun() <= 0f;
                if (punish) punishFrames++;
                Dodge.Move towardMove = dx >= 0 ? Dodge.Move.Right : Dodge.Move.Left;
                bool onGround = p.onGround();
                if (onGround) groundY = me3.y;
                float reachDy = it.y - groundY;
                if (dodge) guard.Look(p, groundY);
                guard.StickX = attackMode == "ranged" ? (float?)null : it.x;

                // What the fight means to do this frame, as a move (for the dodge) and the tap that goes with it.
                Dodge.Move want = Dodge.Move.Stay;
                string tap = null;
                bool turn = false;
                string dirHold = null; // a direction held with the swing: it makes it Spiral Slash or Upper Slash
                bool facingIt = (dx >= 0) == (p.direction.ToString() == "RIGHT");
                bool inMelee = attackMode != "ranged" && Mathf.Abs(dx) <= MeleeReach + target.GetHitboxW() / 2f && Mathf.Abs(dy) <= MeleeHalfHeight + target.GetHitboxH() / 2f;
                // Falling turns into a quickdrop per `prefer_drop`, never to attack; the dodge still takes one if safe.
                bool swinging = p.logicStatus.ToString().Contains("TEVI_WEAK");
                guard.PreferDrop = preferDrop == "always" || (preferDrop == "swing" && !onGround && !swinging && !inMelee)
                    || (preferDrop == "near_target" && !InMeleeReach(p, target, attackMode, 60f));
                if (Mathf.Abs(dx) < minRange && onGround)
                {
                    want = dx >= 0 ? Dodge.Move.Left : Dodge.Move.Right;
                }
                else if (attackMode != "ranged" ? inMelee : Mathf.Abs(dx) <= range)
                {
                    stuckFrames = 0;
                    // Face it first with a one-frame hold; turning barely moves her, so the dodge sees it as standing.
                    if (!facingIt) turn = true;
                    else if (attackMode == "ranged" && Mathf.Abs(dy) > 90f) tap = null;
                    else
                    {
                        tap = inRangeTap;
                        if (tap == "Attack" && spiralSlash && !onGround && dy <= 20f) dirHold = "YAxis-";
                        else if (tap == "Attack" && upperSlash && onGround && dy > 60f) dirHold = "YAxis+";
                        else if (tap == "Attack" && breakLaunch && onGround && ArmorRecovering(target)) dirHold = "YAxis+";
                        else if (tap == "Attack" && punish && onGround) dirHold = "YAxis+";
                        if (tap == "Attack" && recoverRanged && ArmorRecovering(target))
                        {
                            tap = "Ranged";
                            dirHold = null;
                        }
                        // Standing to swing is not safe but a jump is: swing from the air instead of doing nothing.
                        if (airSwing && onGround && dodge && !guard.StandingSafe(rootFrames) && guard.Safe(Dodge.Move.Jump)) want = Dodge.Move.Jump;
                    }
                }
                else
                {
                    want = towardMove;
                    bool notMoving = Mathf.Abs(me3.x - lastX) < 0.5f;
                    stuckFrames = notMoving ? stuckFrames + 1 : 0;
                    // Out of a jump's reach and not getting closer: say so, never flail.
                    blockedFrames = notMoving && reachDy > UnreachableDy ? blockedFrames + 1 : 0;
                    if (blockedFrames >= 45) return Done("unreachable");
                    if (onGround && (stuckFrames >= 12 || dy > 90f))
                    {
                        want = dx >= 0 ? Dodge.Move.JumpRight : Dodge.Move.JumpLeft;
                        stuckFrames = 0;
                    }
                    outOfReachFrames = Mathf.Abs(reachDy) > 90f ? outOfReachFrames + 1 : 0;
                    if (facingIt && Mathf.Abs(dx) < 500f && Mathf.Abs(dy) <= 90f && attackMode == "auto") tap = "Ranged";
                    else if (outOfReachFrames > 90 && Mathf.Abs(dx) < 500f && attackMode != "melee") tap = "Ranged";
                }

                // An orb between her and the target is hit toward it, never one behind her: going round one puts her in
                // its blast. Each kick of the orb last used logs what she was doing.
                if (lastOrb != null && lastOrb.t != null && lastOrb.phy_perfer != null)
                {
                    Vector2 ov = lastOrb.phy_perfer._velocity;
                    if (ov.magnitude > OrbKicked && lastOrbSpeed <= OrbKicked && orbLog.Count < 60)
                    {
                        orbLog.Add(new JObject { ["frame"] = Time.frameCount, ["kicked"] = true, ["vx"] = Math.Round(ov.x), ["vy"] = Math.Round(ov.y), ["her_logic"] = p.logicStatus.ToString(), ["her_input"] = InputInjection.HeldNow(), ["ox"] = Math.Round(lastOrb.t.position.x - me3.x), ["oy"] = Math.Round(lastOrb.t.position.y - me3.y), ["boss_dx"] = Math.Round(dx) });
                    }
                    lastOrbSpeed = ov.magnitude;
                    if (!lastOrb.gameObject.activeInHierarchy) lastOrb = null;
                }
                CharacterBase orb = pushOrbs ? OrbToUse(p, target, orbMode == "passive") : null;
                orbNote = null;
                // An orb by the target but beyond her swing, with her inside its blast: her swing cannot set it off, so
                // the fight goes on as if it were not there.
                if (orb != null && orbMode == "active" && Mathf.Abs(orb.t.position.x - target.t.position.x) < OrbBlastClear && Mathf.Abs(orb.t.position.x - me3.x) < OrbBlastClear + 10f
                    && Mathf.Abs(orb.t.position.x - me3.x) > MeleeReach + OrbHalf + 10f) orb = null;
                if (orb != null)
                {
                    Vector3 o3 = orb.t.position;
                    int s = dx >= 0 ? 1 : -1; // the way the orb has to go: toward the target, beyond it
                    float ox = o3.x - me3.x, oy = o3.y - me3.y, ax = Mathf.Abs(ox);
                    bool facingS = (s > 0) == (p.direction.ToString() == "RIGHT");
                    Dodge.Move awayS = s > 0 ? Dodge.Move.Left : Dodge.Move.Right, toS = s > 0 ? Dodge.Move.Right : Dodge.Move.Left;
                    bool inSwing = ax <= MeleeReach + OrbHalf && Mathf.Abs(oy) <= MeleeHalfHeight + OrbHalf;
                    tap = null;
                    turn = false;
                    if (orb != lastOrb)
                    {
                        lastOrb = orb;
                        lastOrbSpeed = orb.phy_perfer != null ? orb.phy_perfer._velocity.magnitude : 0f;
                    }
                    // An orb by the target goes off there, its blast reaching her within about 200: one there is shot
                    // from beyond the blast (`orb_shots`); one away from it is hit any way and goes off on the target.
                    bool byTarget = Mathf.Abs(o3.x - target.t.position.x) < OrbBlastClear;
                    if (orbMode == "passive")
                    {
                        if (!onGround && ax < OrbHalf + 20f && oy < 0f && oy > -200f) want = Dodge.Move.Drop;
                        else if (!facingS) turn = true;
                        else if (ax < OrbTooClose) want = awayS;
                        else tap = "Attack";
                    }
                    else if (byTarget)
                    {
                        if (!facingS) turn = true;
                        else if (ax < OrbBlastClear + 10f) want = awayS; // back to shot distance
                        else if (orbShots && Mathf.Abs(oy) <= 40f)
                        {
                            want = Dodge.Move.Stay;
                            tap = "Ranged";
                        }
                    }
                    // In the air over it: quickdrop onto it, which pushes it too.
                    else if (!onGround && ax < OrbHalf + 20f && oy < 0f && oy > -200f) want = Dodge.Move.Drop;
                    else if (!facingS) turn = true;
                    else if (ax < OrbTooClose) want = awayS;
                    else if (inSwing)
                    {
                        want = Dodge.Move.Stay;
                        tap = "Attack";
                    }
                    else
                    {
                        want = toS;
                        if (orbShots && Mathf.Abs(oy) <= 40f) tap = "Ranged";
                        if (onGround && oy > 60f && oy < 200f && ax < MeleeReach + OrbHalf + 60f) want = s > 0 ? Dodge.Move.JumpRight : Dodge.Move.JumpLeft;
                    }
                    orbFrames++;
                    if (orbFrames % OrbLogEvery == 1 && orbLog.Count < 40)
                        orbNote = new JObject { ["frame"] = Time.frameCount, ["ox"] = Math.Round(ox), ["oy"] = Math.Round(oy), ["boss_dx"] = Math.Round(dx), ["ground"] = onGround, ["want"] = want.ToString(), ["tap"] = tap };
                }

                Dodge.Move move = dodge ? guard.Check(p, want, groundY) : want;
                if (backflipDodge && dodge && guard.ChosenHitIn <= BackflipWindow && p.playerc_perfer != null && p.playerc_perfer.HaveDodge() >= 1f
                    && InputInjection.Tap("Backflip", 4))
                {
                    backflips++;
                }
                if (orbNote != null)
                {
                    orbNote["took"] = move.ToString();
                    if (move != want && guard.LastDodge != null) orbNote["by"] = guard.LastDodge["by"];
                    orbLog.Add(orbNote);
                }
                if (move == want && Dodge.IsDrop(move))
                {
                    if (guard.Execute(move, onGround)) jumps++;
                }
                else if (move == want)
                {
                    if (turn) InputInjection.Keep(dx >= 0 ? "XAxis+" : "XAxis-");
                    if (Dodge.IsJump(move) && onGround && InputInjection.Tap("Jump", 16)) jumps++;
                    int dir = Dodge.Dir(move);
                    if (dir != 0) InputInjection.Keep(dir > 0 ? "XAxis+" : "XAxis-");
                    if (comboKeep && tap == null && combo >= 2 && Time.frameCount - comboRoseAt >= ComboKeepAfter && facingIt && Mathf.Abs(dy) <= 90f)
                    {
                        tap = "Ranged";
                        keepShots++;
                    }
                    string tapUngated = tap;
                    // A swing or shot roots her (in the air she cannot steer): it waits until the Stay plan is safe for
                    // `root_frames`, or `combo_root_frames` for a combo's later hits.
                    int root = tap == "Attack" && (p.logicStatus.ToString().Contains("NORMAL1") || p.logicStatus.ToString().Contains("NORMAL2")) ? comboRootFrames : rootFrames;
                    if (tap != null && dodge && !guard.StandingSafe(root)) tap = null;
                    // A swing slides her: none beside a beam that hurts, or will before the swing ends.
                    if (tap == "Attack" && dodge && beamGate != "off" && BeamNear(p, root + 6, beamGate == "wide")) tap = null;
                    // No chaining while the combo's lock outlasts the target's hitstun plus its fastest learned tell:
                    // it starts nothing in hitstun, and each hit renews it. A fresh swing stays allowed.
                    if (tap == "Attack" && dodge && chainGuard && root == comboRootFrames && Tells.FastestLead(target.type.ToString()) is int lead
                        && Mathf.Max(0f, target.GetHitStun()) * 60f + lead + ChargeTravel < comboRootFrames) tap = null;
                    // In the red outline a hit does little and does not stop it, and it attacks freely.
                    if (armorGate && tap == "Attack" && orb == null && dodge && ArmorRecovering(target) && !guard.StandingSafe(Dodge.Horizon)) tap = null;
                    // A bar break lifts the gates above, not the incoming-orb gate below.
                    if (punish && tapUngated != null) tap = tapUngated;
                    if (incomingOrbGate && tap != null && IncomingOrb(p, IncomingOrbReach)) tap = null;
                    // The direction is held first (DirLead); Down alone never quickdrops, which needs Jump.
                    bool directed = tap == "Attack" && dirHold != null && orb == null;
                    if (directed)
                    {
                        InputInjection.Keep(dirHold);
                        dirFrames = dirHeld == dirHold ? dirFrames + 1 : 1;
                        dirHeld = dirHold;
                        if (dirFrames < DirLead) tap = null;
                    }
                    else
                    {
                        dirHeld = null;
                        dirFrames = 0;
                    }
                    if (tap != null && InputInjection.Tap(tap, 4))
                    {
                        if (directed && dirHold == "YAxis-") spirals++;
                        else if (directed) uppers++;
                        if (directed && dirHold == "YAxis+" && ArmorRecovering(target)) launches++;
                        if (tap == "Attack") attacks++;
                        else ranged++;
                        if (orb != null) pushes++;
                    }
                }
                else if (guard.Execute(move, onGround))
                {
                    jumps++;
                }
                lastX = me3.x;
                return null;
            };
        }

        // {stop_hp?, stop_on_hit?, home_x?}: the dodge alone for `frames`, drifting back to home_x when safe. Ends
        // `timeout` (passed with `hits_taken` 0), `hit`, `low_hp`, `mode_changed` or `lost`.
        public static Func<JToken> Evade(JObject args, int frameLimit, Func<CharacterBase> player, Func<string> mode, Func<bool, JObject> observe)
        {
            int stopHp = (int?)args["stop_hp"] ?? 0;
            bool stopOnHit = (bool?)args["stop_on_hit"] ?? false;
            CharacterBase me = player();
            if (me == null || me.t == null) throw new Exception("no player");
            if (mode() != "play") throw new Exception("evade starts in play, not in " + mode());
            int start = Time.frameCount, hpStart = me.health, hitsTaken = 0, lastHp = me.health;
            float homeX = (float?)args["home_x"] ?? me.t.position.x, groundY = me.t.position.y;
            var guard = new Guard(me);
            var hits = new JArray();

            JObject Done(string outcome)
            {
                CharacterBase p = player();
                return new JObject
                {
                    ["outcome"] = outcome,
                    ["frames"] = Time.frameCount - start,
                    ["hp_start"] = hpStart,
                    ["hp_end"] = p != null ? (JToken)p.health : null,
                    ["hits_taken"] = hitsTaken,
                    ["hits"] = hits,
                    ["dodges"] = guard.Dodges,
                    ["jumps"] = guard.Jumps,
                    ["last_dodge"] = guard.LastDodge,
                    ["after"] = observe(false),
                };
            }

            return () =>
            {
                CharacterBase p = player();
                if (p == null || p.t == null) return Done("lost");
                if (p.health < lastHp)
                {
                    hitsTaken++;
                    if (hits.Count < 20) hits.Add(new JObject { ["frame"] = Time.frameCount, ["hp"] = p.health, ["last_dodge"] = guard.LastDodge?.DeepClone() });
                }
                lastHp = p.health;
                if (stopOnHit && hitsTaken > 0) return Done("hit");
                if (stopHp > 0 && p.health <= stopHp) return Done("low_hp");
                if (mode() != "play") return Done("mode_changed");
                if (Time.frameCount - start >= frameLimit) return Done("timeout");
                bool onGround = p.onGround();
                if (onGround) groundY = p.t.position.y;
                float off = homeX - p.t.position.x;
                Dodge.Move want = Mathf.Abs(off) > 40f ? (off > 0 ? Dodge.Move.Right : Dodge.Move.Left) : Dodge.Move.Stay;
                Dodge.Move move = guard.Check(p, want, groundY);
                if (move == want)
                {
                    int dir = Dodge.Dir(move);
                    if (dir != 0) InputInjection.Keep(dir > 0 ? "XAxis+" : "XAxis-");
                }
                else
                {
                    guard.Execute(move, onGround);
                }
                return null;
            };
        }

        // The dodge's state for one reflex: the player's last height, for her vertical speed, and what it did.
        internal sealed class Guard
        {
            public int Dodges, Jumps;
            public JObject LastDodge;

            // A move the dodge took is kept CommitFrames frames while as good as any: near-equal plans never alternate.
            private const int CommitFrames = 10;
            private Dodge.Move committed;
            private int committedUntil = -1;
            private float lastY;
            private int lastFrame = -1;

            public Guard(CharacterBase p)
            {
                lastY = p.t.position.y;
            }

            private List<Dodge.Plan> lastPlans;
            private int lastPlansFrame = -1;

            // Whether standing meets nothing for `frames` frames, by this frame's plans (true when nothing threatens).
            public bool StandingSafe(int frames)
            {
                if (lastPlansFrame != Time.frameCount || lastPlans == null) return true;
                int i = lastPlans.FindIndex(x => x.Move == Dodge.Move.Stay);
                return i < 0 || lastPlans[i].FirstHit > frames;
            }

            // Whether a plan meets nothing all horizon by this frame's plans (false when it cannot be taken from here).
            public bool Safe(Dodge.Move m)
            {
                if (lastPlansFrame != Time.frameCount || lastPlans == null) return true;
                int i = lastPlans.FindIndex(x => x.Move == m);
                return i >= 0 && lastPlans[i].FirstHit > Dodge.Horizon;
            }

            // This frame's plans, worked out once; the fight reads them before it decides, and Check uses them after.
            public void Look(CharacterBase p, float groundY)
            {
                if (lastPlansFrame == Time.frameCount) return;
                lastPlansFrame = Time.frameCount;
                lastPlans = null;
                Vector3 pos = p.t.position;
                vyNow = lastFrame == Time.frameCount - 1 ? pos.y - lastY : 0f;
                lastY = pos.y;
                lastFrame = Time.frameCount;
                if (!Threats.PlayerHurtbox(p, out Rect hurt)) return;
                List<Threats.Threat> threats = Threats.Read(p, 200f);
                List<Threats.Laser> lasers = Threats.ReadLasers(p);
                if (threats.Count == 0 && lasers.Count == 0) return;
                bool onGround = p.onGround();
                start = new Dodge.Start
                {
                    Pos = new Vector2(pos.x, pos.y),
                    OnGround = onGround,
                    Vy = onGround ? 0f : vyNow,
                    HoldLeft = InputInjection.FramesLeft("Jump"),
                    GroundY = groundY,
                    Hurt = hurt,
                    Quickdropping = p.logicStatus.ToString() == "QUICKDROP",
                };
                Dodge.WallLimits(pos, 14f, out start.MinX, out start.MaxX);
                start.Floor = groundY + (hurt.yMin - pos.y);
                lastPlans = Dodge.Evaluate(start, threats, lasers);
            }

            private float vyNow;
            private Dodge.Start start;

            public float? StickX; // a fight's target x, set each frame: the dodge prefers plans that keep her near it
            public bool PreferDrop = true; // falling, want a quickdrop: a fight sets it per `prefer_drop`, goto off
            public int? Imminent; // movement: step in only for a hit this close (Dodge.Choose)
            public float Hug = Dodge.DefaultHug; // a fight's `hug`
            // the plan Check took this frame: its first hit, or MaxValue when none is near
            public int ChosenHitIn = int.MaxValue;

            public Dodge.Move Check(CharacterBase p, Dodge.Move want, float groundY)
            {
                Look(p, groundY);
                ChosenHitIn = int.MaxValue;
                bool onGround = p.onGround();
                // Falling, a quickdrop is wanted; the dodge keeps the plain fall when the drop would meet something.
                if (PreferDrop && !onGround && vyNow < 0f && p.logicStatus.ToString() != "QUICKDROP" && !Dodge.IsDrop(want))
                {
                    int d = Dodge.Dir(want);
                    want = d < 0 ? Dodge.Move.DropLeft : d > 0 ? Dodge.Move.DropRight : Dodge.Move.Drop;
                }
                if (lastPlans == null) return want;
                // A jump cannot begin in the air: what is wanted there is its direction.
                if (!onGround && Dodge.IsJump(want))
                {
                    int d = Dodge.Dir(want);
                    want = d < 0 ? Dodge.Move.Left : d > 0 ? Dodge.Move.Right : Dodge.Move.Stay;
                }
                List<Dodge.Plan> plans = lastPlans;
                Dodge.Start st = start;
                Dodge.Plan chosen = Dodge.Choose(plans, want, StickX, Imminent, Hug);
                // Inside the window the committed move beats the wanted one too while as safe, or a want flipping back
                // once the danger passes would stutter.
                if (Imminent == null && Time.frameCount <= committedUntil && chosen.Move != committed)
                {
                    int i = plans.FindIndex(x => x.Move == committed);
                    if (i >= 0 && (plans[i].FirstHit > Dodge.Horizon || plans[i].FirstHit >= chosen.FirstHit)) chosen = plans[i];
                }
                ChosenHitIn = chosen.FirstHit > Dodge.Horizon ? int.MaxValue : chosen.FirstHit;
                if (chosen.Move != want && chosen.Move != committed)
                {
                    committed = chosen.Move;
                    committedUntil = Time.frameCount + CommitFrames;
                }
                if (chosen.Move != want)
                {
                    Dodges++;
                    Dodge.Plan w = plans.Find(x => x.Move == want);
                    LastDodge = new JObject
                    {
                        ["frame"] = Time.frameCount,
                        ["wanted"] = want.ToString(),
                        ["wanted_hit_in"] = w.FirstHit,
                        ["by"] = w.HitBy,
                        ["took"] = chosen.Move.ToString(),
                        ["took_hit_in"] = chosen.FirstHit > Dodge.Horizon ? null : (JToken)chosen.FirstHit,
                        ["wanted_clearance"] = Math.Round(w.Clearance, 1),
                        ["took_clearance"] = Math.Round(chosen.Clearance, 1),
                        ["walls"] = new JArray(st.MinX < -1e30f ? null : (JToken)Math.Round(st.MinX, 1), st.MaxX > 1e30f ? null : (JToken)Math.Round(st.MaxX, 1)),
                        ["plans"] = PlanTable(plans),
                    };
                }
                return chosen.Move;
            }

            private static JArray PlanTable(List<Dodge.Plan> plans)
            {
                var arr = new JArray();
                foreach (Dodge.Plan pl in plans) arr.Add(new JArray(pl.Move.ToString(), pl.FirstHit, pl.HitFrames, Math.Round(pl.Clearance), Math.Round(pl.Room), pl.HitBy));
                return arr;
            }

            // Carries out a plan the dodge chose for this frame. Returns true when it began a jump.
            public bool Execute(Dodge.Move m, bool onGround)
            {
                int dir = Dodge.Dir(m);
                if (dir != 0) InputInjection.Keep(dir > 0 ? "XAxis+" : "XAxis-");
                if (!onGround && Dodge.IsDrop(m))
                {
                    InputInjection.Quickdrop();
                    return false;
                }
                if (!onGround || !Dodge.IsJump(m)) return false;
                bool hop = m == Dodge.Move.Hop || m == Dodge.Move.HopLeft || m == Dodge.Move.HopRight || Dodge.IsHopDrop(m);
                if (!InputInjection.Tap("Jump", hop ? Dodge.HopHold : Dodge.JumpHold)) return false;
                Jumps++;
                return true;
            }
        }

        private const int OrbLogEvery = 20;
        private const float OrbKicked = 150f; // physics speed: a knocked orb read 400-600, a resting one about 0
        // OrbTooClose keeps her outside an orb's touch distance; OrbHalf is half its body.
        private const float OrbTooClose = 56f, OrbHalf = 25f, OrbKnocked = 300f;

        // The nearest orb between her and the target (or right beside it) not already flying; passive (C): only one in
        // her swing or under her in the air.
        private static CharacterBase OrbToUse(CharacterBase me, CharacterBase target, bool passive)
        {
            CharacterManager cm = CharacterManager.Instance;
            if (cm == null || cm.characters == null || target == null || target.t == null) return null;
            Vector3 at = me.t.position;
            float toTarget = target.t.position.x - at.x;
            CharacterBase best = null;
            float bestD = float.MaxValue;
            foreach (CharacterBase c in cm.characters)
            {
                if (c == null || c == me || c == target || c.t == null || !c.gameObject.activeInHierarchy || c.maxhealth < 99999) continue;
                if (c.type.ToString() != "EnergyBall" || Utility.isOutsideCamera(c.t.position, 0f)) continue;
                float dx = c.t.position.x - at.x;
                if (Math.Sign(dx) != Math.Sign(toTarget) || Mathf.Abs(dx) > Mathf.Abs(toTarget) + 30f) continue;
                if (Mathf.Abs(c.t.position.y - at.y) > 220f) continue; // well above or below her level: not hers to hit
                if (passive)
                {
                    float dy = c.t.position.y - at.y;
                    bool inSwing = Mathf.Abs(dx) <= MeleeReach + OrbHalf && Mathf.Abs(dy) <= MeleeHalfHeight + OrbHalf;
                    bool under = !me.onGround() && Mathf.Abs(dx) < OrbHalf + 20f && dy < 0f && dy > -200f;
                    if (!inSwing && !under) continue;
                }
                if (c.phy_perfer != null && c.phy_perfer._velocity.magnitude > OrbKnocked) continue;
                if (Mathf.Abs(dx) < bestD)
                {
                    bestD = Mathf.Abs(dx);
                    best = c;
                }
            }
            return best;
        }

        // `narrow` refuses a swing only when where she stands or its slide ends comes within her half-width and
        // BeamMargin of a beam, keeping the curtain's gaps; `wide` (C): within BeamWide of any.
        private const float BeamSlide = 16f, BeamMargin = 18f, BeamWide = 40f;

        private static bool BeamNear(CharacterBase p, int withinFrames, bool wide)
        {
            // her hurtbox centre (observe: dy_from_position -17)
            var c = new Vector2(p.t.position.x, p.t.position.y - 17f);
            float half = p.GetHitboxW() / 2f + BeamMargin;
            foreach (Threats.Laser l in Threats.ReadLasers(p))
            {
                if (l.AppearIn > withinFrames) continue;
                if (wide)
                {
                    if (Threats.DistanceToSegment(c, l.From, l.To) - l.Radius < BeamWide) return true;
                    continue;
                }
                for (int k = -1; k <= 1; k++)
                {
                    var at = new Vector2(c.x + k * BeamSlide, c.y);
                    if (Threats.DistanceToSegment(at, l.From, l.To) - l.Radius < half) return true;
                }
            }
            return false;
        }

        private const float IncomingOrbReach = 500f, OrbBlastClear = 215f; // half the blast's 405 and half her width

        // An orb within `reach` moving toward her faster than a resting one sways.
        private static bool IncomingOrb(CharacterBase me, float reach)
        {
            CharacterManager cm = CharacterManager.Instance;
            if (cm == null || cm.characters == null) return false;
            Vector3 at = me.t.position;
            foreach (CharacterBase c in cm.characters)
            {
                if (c == null || c == me || c.t == null || !c.gameObject.activeInHierarchy || c.type.ToString() != "EnergyBall" || c.phy_perfer == null) continue;
                float dx = c.t.position.x - at.x;
                if (Mathf.Abs(dx) > reach || Mathf.Abs(c.t.position.y - at.y) > 250f) continue;
                if (c.phy_perfer._velocity.x * Math.Sign(dx) < -OrbKicked) return true;
            }
            return false;
        }

        // Whether the target is within her swing's reach and `margin` more; false when ranged.
        private static bool InMeleeReach(CharacterBase p, CharacterBase target, string attackMode, float margin)
        {
            if (attackMode == "ranged" || p == null || target == null || p.t == null || target.t == null) return false;
            float dx = target.t.position.x - p.t.position.x, dy = target.t.position.y - p.t.position.y;
            return Mathf.Abs(dx) <= MeleeReach + target.GetHitboxW() / 2f + margin && Mathf.Abs(dy) <= MeleeHalfHeight + target.GetHitboxH() / 2f + margin;
        }

        private static bool ArmorRecovering(CharacterBase c)
        {
            return c != null && c.enemy_perfer != null && c.enemy_perfer.inQuickArmorRecover;
        }

        private static CharacterBase Nearest(CharacterBase me, string type)
        {
            CharacterManager cm = CharacterManager.Instance;
            if (cm == null || cm.characters == null) return null;
            CharacterBase best = null;
            float bestD = float.MaxValue;
            foreach (CharacterBase c in cm.characters)
            {
                if (c == null || c == me || c.t == null || !c.gameObject.activeInHierarchy || c.health <= 0) continue;
                if (!IsEnemy(c) || Utility.isOutsideCamera(c.t.position, 0f)) continue;
                // Not something to fight: a blastorb reads as an enemy with 99999 HP.
                if (c.maxhealth >= 99999) continue;
                if (type != null && c.type.ToString() != type) continue;
                float d = (c.t.position - me.t.position).sqrMagnitude;
                if (d < bestD)
                {
                    bestD = d;
                    best = c;
                }
            }
            return best;
        }

        private static bool IsEnemy(CharacterBase c)
        {
            try
            {
                return c.isCharacterEnemy();
            }
            catch (Exception)
            {
                return false;
            }
        }
    }
}
