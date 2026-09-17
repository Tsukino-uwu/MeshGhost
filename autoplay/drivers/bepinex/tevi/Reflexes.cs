using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // REFLEXES (the plan's layer 2; agent_docs/phases/phase13.md, "how an agent sees a game"): programs that read the game
    // every frame and choose the next frame's input, for what a model turn is too slow to steer. The user, 2026-09-17: "need a
    // better way to keep track of/be aware of moving enemies. they will move around/go towards the player/use ranged attackes
    // etc. you can't just always stop in place and attack hopping that they will walk towards you".
    //
    // A reflex is a Func<JToken> ticked once a frame by the plugin, like any running request: null while it runs, its answer
    // when it ends. Its input goes through InputInjection.Keep and Tap, so the game reads it as its own.
    public static class Reflexes
    {
        // FIGHT {type?, range?, min_range?, stop_hp?, dodge?, push_orbs?, no_progress_frames?}: one enemy, followed and attacked until
        // it is beaten.
        //  - the target: the nearest living enemy in view (of `type` when given), kept by reference so a second of the same
        //    kind never takes its place;
        //  - each frame: face it; outside melee `range` (default 110 world units) hold toward it; inside it and roughly level
        //    tap Attack; well above and on the ground, jump toward it; stuck against something while closing in, jump; level
        //    but out of reach for long (a gap, a ledge), tap Ranged;
        //  - ends `defeated` (its HP 0 or it is gone after a hit landed), `lost` (gone from view or inactive otherwise),
        //    `unreachable` (45 frames not moving with it higher than a jump reaches from where she stands), `no_progress`
        //    (its HP unchanged for `no_progress_frames`, default 300),
        //    `low_hp` (the player's HP at or below `stop_hp`), `mode_changed` (not in play any more: a scene, a menu), or
        //    `timeout` at the frame limit. Reports hits taken, attacks tapped, jumps and the target's HP at start and end.
        //  - `push_orbs` (default true): a blastorb not already flying between her and the target, already within her swing or under her
        //    in the air, is hit toward the target (melee, or a quickdrop onto it); she never goes to one; `orb_frames`
        //    counts the frames spent on it, `orb_log` samples the decisions and each time the orb was sent flying. The user, 2026-09-17: "the player can also
        //    attack them to push them towards/into the boss"; and a blastorb went off on Ribauld for most of his HP while she only dodged.
        //  - with `dodge` (default true), each frame's intended move is checked against every box that can hurt the player
        //    (Dodge.cs) and replaced by the nearest safe plan when it would be hit; `dodges` counts the frames it was.
        private const float UnreachableDy = 180f;
        private const int RootFrames = 18; // one swing locks her about 18 frames (TEVI_WEAK_GROUND_NORMAL1 in the flight recorder, 2026-09-17)
        private const float MeleeReach = 139.5f, MeleeHalfHeight = 34f;
        private const int ComboRootFrames = 32;

        public static Func<JToken> Fight(JObject args, int frameLimit, Func<CharacterBase> player, Func<string> mode, Func<bool, JObject> observe)
        {
            string wantType = (string)args["type"];
            float range = (float?)args["range"] ?? 110f;
            // Closer than this she backs off: a boss's shots spawn at its gun, on top of anyone standing close (Ribauld's speeddown, fired
            // at 35 units a frame from his gun, hit her at 83 units with no frame to see it, 2026-09-17). Her ground swing reaches 139.5
            // ahead of her (a box 189 wide centred 45 ahead, MEASURED.md), so a big target can be hit from well outside 100.
            float minRange = (float?)args["min_range"] ?? 0f;
            // `attack`: auto (default), melee or ranged. The user, 2026-09-17: "prefer melee attacks over orbitars, as melee always do more
            // damage. but orbitars are nice when you can't reach with melee", "ground is prefered over air, but air is better than
            // standing around and doing nothing", and above all never getting hit. So auto swings whenever her swing reaches the
            // target, on the ground while standing is safe and else from a jump; out of reach it closes in and shoots on the way. ranged
            // keeps to `range` and shoots (a melee combo locks her for its swings: Ribauld's charge from a standstill pushed her into a
            // blastorb, 2026-09-17); melee never shoots.
            string attackMode = (string)args["attack"] ?? "auto";
            if (attackMode != "auto" && attackMode != "melee" && attackMode != "ranged") throw new Exception("attack is auto, melee or ranged");
            string inRangeTap = attackMode == "ranged" ? "Ranged" : "Attack";
            string askedMode = attackMode;
            int stopHp = (int?)args["stop_hp"] ?? 0;
            bool dodge = (bool?)args["dodge"] ?? true;
            int noProgressFrames = (int?)args["no_progress_frames"] ?? 300; // a boss the dodge keeps her away from needs far more
            bool pushOrbs = (bool?)args["push_orbs"] ?? true;
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
            float groundY = me.t.position.y; // where she last stood: reach is measured from there, so a jump does not reset it
            bool landed = false;
            int targetHpSeen = target.health, lastProgress = Time.frameCount;
            string targetType = target.type.ToString();
            var guard = new Guard(me);
            int targetId = target.ID;

            JObject Done(string outcome)
            {
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
                // 900 frames of shots at a dog 232 units below, through a floor, never hurt it (2026-09-17): whatever the reason,
                // a fight that stops hurting its target says so.
                if (Time.frameCount - lastProgress >= noProgressFrames) return Done("no_progress");
                if (stopHp > 0 && p.health <= stopHp) return Done("low_hp");
                if (mode() != "play") return Done("mode_changed");
                if (Time.frameCount - start >= frameLimit) return Done("timeout");
                if (Utility.isOutsideCamera(target.t.position, 64f)) return Done("lost");

                Vector3 me3 = p.t.position, it = target.t.position;
                float dx = it.x - me3.x, dy = it.y - me3.y;
                // A kind whose attacks have not been seen yet is fought from range until one has: up close its first attack lands before
                // the dodge knows it (a mouse and a cat on Infernal BBQ, 26 to 35 HP a hit, 2026-09-17).
                if (askedMode == "auto")
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
                Dodge.Move towardMove = dx >= 0 ? Dodge.Move.Right : Dodge.Move.Left;
                bool onGround = p.onGround();
                if (onGround) groundY = me3.y;
                float reachDy = it.y - groundY;
                if (dodge) guard.Look(p, groundY);
                guard.StickX = attackMode == "ranged" ? (float?)null : it.x;
                guard.PreferDrop = !inMeleeReach(p, target, attackMode); // falling beside a target, an air swing beats a quickdrop

                // What the fight means to do this frame, as a move (for the dodge) and the tap that goes with it.
                Dodge.Move want = Dodge.Move.Stay;
                string tap = null;
                bool turn = false;
                bool facingIt = (dx >= 0) == (p.direction.ToString() == "RIGHT");
                // Her ground swing reaches 139.5 ahead and 34 above and below her (a box 189 by 67.5 centred 45 ahead, MEASURED.md); it
                // lands when that box meets the target's own.
                bool inMelee = attackMode != "ranged" && Mathf.Abs(dx) <= MeleeReach + target.GetHitboxW() / 2f && Mathf.Abs(dy) <= MeleeHalfHeight + target.GetHitboxH() / 2f;
                // No quickdrop as an attack: the user, 2026-09-17, "quickdrops do low damage and are slow, they should only be used for
                // their iframes if other better damage options are available". The dodge still takes one to avoid a hit.
                if (Mathf.Abs(dx) < minRange && onGround)
                {
                    want = dx >= 0 ? Dodge.Move.Left : Dodge.Move.Right;
                }
                else if (attackMode != "ranged" ? inMelee : Mathf.Abs(dx) <= range)
                {
                    stuckFrames = 0;
                    // Turn to face it first: a one-frame hold toward it. Turning barely moves her, so the dodge sees it as standing (it
                    // refused a turn toward a boss for want of room, and she stood 90 frames never facing it, 2026-09-17).
                    if (!facingIt) turn = true;
                    else if (attackMode == "ranged" && Mathf.Abs(dy) > 90f) tap = null;
                    else
                    {
                        tap = inRangeTap;
                        // Standing to swing is not safe but a jump is: swing from the air instead of doing nothing.
                        if (onGround && dodge && !guard.StandingSafe(RootFrames) && guard.Safe(Dodge.Move.Jump)) want = Dodge.Move.Jump;
                    }
                }
                else
                {
                    want = towardMove;
                    bool notMoving = Mathf.Abs(me3.x - lastX) < 0.5f;
                    stuckFrames = notMoving ? stuckFrames + 1 : 0;
                    // Out of a jump's reach (a full jump rose 175 units, MEASURED.md) and not getting closer: say so, never flail.
                    blockedFrames = notMoving && reachDy > UnreachableDy ? blockedFrames + 1 : 0;
                    if (blockedFrames >= 45) return Done("unreachable");
                    if (onGround && (stuckFrames >= 12 || dy > 90f))
                    {
                        want = dx >= 0 ? Dodge.Move.JumpRight : Dodge.Move.JumpLeft;
                        stuckFrames = 0;
                    }
                    // Out of melee reach: shoot on the way in (auto), or after closing in has not worked for a while (melee never).
                    outOfReachFrames = Mathf.Abs(reachDy) > 90f ? outOfReachFrames + 1 : 0;
                    if (facingIt && Mathf.Abs(dx) < 500f && Mathf.Abs(dy) <= 90f && attackMode == "auto") tap = "Ranged";
                    else if (outOfReachFrames > 90 && Mathf.Abs(dx) < 500f && attackMode != "melee") tap = "Ranged";
                }

                // Orbs when they cost nothing: the user, 2026-09-17, "just abuse the orbs to deal a lot of damage to the boss fast", then
                // "Priority 1 is to not get hit, but priority 2 is to always hugg/stick to the boss as much as possible to constantly deal
                // damage, everything else is a 3rd priority". So only an orb between her and the target and already within her swing, or
                // under her in the air, is hit, and she never goes to one: walking to orbs cost Ribauld's fight 365 frames for 20 HP, and
                // going round one to its far side put her beside it as it went off (73 HP on Infernal BBQ, 2026-09-17). Orbitar shots at the
                // target carry any orb in their path anyway. Every time the orb last used is sent flying, what she was doing is logged as `kicked`.
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
                CharacterBase orb = pushOrbs ? OrbToUse(p, target) : null;
                orbNote = null;
                if (orb != null)
                {
                    Vector3 o3 = orb.t.position;
                    int s = dx >= 0 ? 1 : -1; // the way the orb has to go: toward the target, beyond it
                    float ox = o3.x - me3.x, oy = o3.y - me3.y, ax = Mathf.Abs(ox);
                    bool facingS = (s > 0) == (p.direction.ToString() == "RIGHT");
                    Dodge.Move awayS = s > 0 ? Dodge.Move.Left : Dodge.Move.Right;
                    tap = null;
                    turn = false;
                    if (orb != lastOrb)
                    {
                        lastOrb = orb;
                        lastOrbSpeed = orb.phy_perfer != null ? orb.phy_perfer._velocity.magnitude : 0f;
                    }
                    // In the air over it: quickdrop onto it (the user, 2026-09-17: "its also possible to quickdrop onto bombs to push them").
                    if (!onGround && ax < OrbHalf + 20f && oy < 0f && oy > -200f) want = Dodge.Move.Drop;
                    else if (!facingS) turn = true;
                    else if (ax < OrbTooClose) want = awayS;
                    else tap = "Attack";
                    orbFrames++;
                    if (orbFrames % OrbLogEvery == 1 && orbLog.Count < 40)
                        orbNote = new JObject { ["frame"] = Time.frameCount, ["ox"] = Math.Round(ox), ["oy"] = Math.Round(oy), ["boss_dx"] = Math.Round(dx), ["ground"] = onGround, ["want"] = want.ToString(), ["tap"] = tap };
                }

                Dodge.Move move = dodge ? guard.Check(p, want, groundY) : want;
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
                    // A swing or a shot roots her for its animation: on the ground she stands, in the air she keeps her arc but cannot steer
                    // (she hung at one x mid-air while a charge came under her and the dodge's steering did nothing, 2026-09-17). So it is
                    // taken, ground or air, whenever not moving -- the Stay plan -- stays safe for RootFrames. The user: "should be able to
                    // mix both ground/air to attack as much as possible whenever possible. while prioritizing never getting hit".
                    // A swing that carries a combo on to its second and third hits holds her longer: after the third her Jump was not taken
                    // for 22 frames while bombs fell on her (2026-09-17).
                    int root = tap == "Attack" && (p.logicStatus.ToString().Contains("NORMAL1") || p.logicStatus.ToString().Contains("NORMAL2")) ? ComboRootFrames : RootFrames;
                    if (tap != null && dodge && !guard.StandingSafe(root)) tap = null;
                    // Its armor broken and refilling (the red outline): a hit does little and does not stop it, and it attacks freely (the
                    // user, 2026-09-17; the meter measured in MEASURED.md). A melee swing then only when standing stays safe for the whole
                    // horizon.
                    if (tap == "Attack" && orb == null && dodge && ArmorRecovering(target) && !guard.StandingSafe(Dodge.Horizon)) tap = null;
                    if (tap != null && InputInjection.Tap(tap, 4))
                    {
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

        // EVADE {stop_hp?, stop_on_hit?, home_x?}: stay where the player is and let nothing hit her for `frames`: every box that can hurt her is read each
        // frame and dodged (Dodge.cs), drifting back toward the starting x when that is safe. Ends `timeout` at the frame limit (the
        // try passed when `hits_taken` is 0), `hit` (with stop_on_hit, the frame after the first), `low_hp`, or `mode_changed`. The dodge on its own, and a way to wait out a pattern.
        public static Func<JToken> Evade(JObject args, int frameLimit, Func<CharacterBase> player, Func<string> mode, Func<bool, JObject> observe)
        {
            int stopHp = (int?)args["stop_hp"] ?? 0;
            bool stopOnHit = (bool?)args["stop_on_hit"] ?? false;
            CharacterBase me = player();
            if (me == null || me.t == null) throw new Exception("no player");
            if (mode() != "play") throw new Exception("evade starts in play, not in " + mode());
            int start = Time.frameCount, hpStart = me.health, hitsTaken = 0, lastHp = me.health;
            float homeX = (float?)args["home_x"] ?? me.t.position.x, groundY = me.t.position.y; // where it drifts back to: home_x, else where it began
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

            // Commitment: a move the dodge took is kept CommitFrames frames while it stays as good as any, so two near-equal plans never
            // alternate frame by frame (she flipped left and right every 2 to 4 frames, 15 units back and forth, 2026-09-17).
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

            // Whether standing where she is meets nothing for `frames` frames, by this frame's plans (true when nothing threatens).
            public bool StandingSafe(int frames)
            {
                if (lastPlansFrame != Time.frameCount || lastPlans == null) return true;
                int i = lastPlans.FindIndex(x => x.Move == Dodge.Move.Stay);
                return i < 0 || lastPlans[i].FirstHit > frames;
            }

            // Whether a plan meets nothing over the whole horizon, by this frame's plans (false when it cannot be taken from here).
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
            public bool PreferDrop = true; // falling, want a quickdrop (movement); a fight turns it off beside its target
            public int? Imminent; // movement: step in only for a hit this close (Dodge.Choose)

            public Dodge.Move Check(CharacterBase p, Dodge.Move want, float groundY)
            {
                Look(p, groundY);
                bool onGround = p.onGround();
                // Falling, a quickdrop is wanted instead: the user, 2026-09-17, "prefer always using quickdrop instead of normally falling
                // down. as its faster/makes it easier to react to attacks from enemies". The dodge still takes the plain fall when the drop
                // would meet something.
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
                Dodge.Plan chosen = Dodge.Choose(plans, want, StickX, Imminent);
                // Inside the window the committed move wins over the wanted one too while it is as safe: a want that flips back the
                // moment the danger is behind her is the same stutter.
                if (Imminent == null && Time.frameCount <= committedUntil && chosen.Move != committed)
                {
                    int i = plans.FindIndex(x => x.Move == committed);
                    if (i >= 0 && (plans[i].FirstHit > Dodge.Horizon || plans[i].FirstHit >= chosen.FirstHit)) chosen = plans[i];
                }
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
                    InputInjection.Keep("YAxis-");
                    InputInjection.Tap("Jump", 4);
                    return false;
                }
                if (!onGround || !Dodge.IsJump(m)) return false;
                bool hop = m == Dodge.Move.Hop || m == Dodge.Move.HopLeft || m == Dodge.Move.HopRight || Dodge.IsHopDrop(m);
                if (!InputInjection.Tap("Jump", hop ? Dodge.HopHold : Dodge.JumpHold)) return false;
                Jumps++;
                return true;
            }
        }

        // Using a blastorb: never closer than its touch distance (it goes off within about 42 units, EnergyBall read as a map; its body
        // box 50 by 50, the flight recorder).
        private const int OrbLogEvery = 20;
        private const float OrbKicked = 150f; // physics speed: a knocked orb read 400-600, a resting one about 0
        private const float OrbTooClose = 56f, OrbHalf = 25f, OrbKnocked = 300f;

        // The nearest orb between her and the target, within her swing (or under her in the air), that is not already flying (a
        // knocked one moves 20-30 units a frame, 400-600 as the physics reads speed).
        private static CharacterBase OrbToUse(CharacterBase me, CharacterBase target)
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
                if (Math.Sign(dx) != Math.Sign(toTarget) || Mathf.Abs(dx) > Mathf.Abs(toTarget)) continue;
                float dy = c.t.position.y - at.y;
                bool inSwing = Mathf.Abs(dx) <= MeleeReach + OrbHalf && Mathf.Abs(dy) <= MeleeHalfHeight + OrbHalf;
                bool under = !me.onGround() && Mathf.Abs(dx) < OrbHalf + 20f && dy < 0f && dy > -200f;
                if (!inSwing && !under) continue;
                if (c.phy_perfer != null && c.phy_perfer._velocity.magnitude > OrbKnocked) continue;
                if (Mathf.Abs(dx) < bestD)
                {
                    bestD = Mathf.Abs(dx);
                    best = c;
                }
            }
            return best;
        }

        private static bool inMeleeReach(CharacterBase p, CharacterBase target, string attackMode)
        {
            if (attackMode == "ranged" || p == null || target == null || p.t == null || target.t == null) return false;
            float dx = target.t.position.x - p.t.position.x, dy = target.t.position.y - p.t.position.y;
            return Mathf.Abs(dx) <= MeleeReach + target.GetHitboxW() / 2f + 60f && Mathf.Abs(dy) <= MeleeHalfHeight + target.GetHitboxH() / 2f + 60f;
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
                // Not something to fight: EnergyBall reads enemy with 99999 HP, and the user, 2026-09-17: "these things are bombs
                // you can attack/push towards things to break them, not enemies".
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
