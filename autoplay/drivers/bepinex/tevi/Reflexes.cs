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
        // FIGHT {type?, range?, stop_hp?}: one enemy, followed and attacked until it is beaten.
        //  - the target: the nearest living enemy in view (of `type` when given), kept by reference so a second of the same
        //    kind never takes its place;
        //  - each frame: face it; outside melee `range` (default 110 world units) hold toward it; inside it and roughly level
        //    tap Attack; well above and on the ground, jump toward it; stuck against something while closing in, jump; level
        //    but out of reach for long (a gap, a ledge), tap Ranged;
        //  - ends `defeated` (its HP 0 or it is gone after a hit landed), `lost` (gone from view or inactive otherwise),
        //    `unreachable` (45 frames not moving with it higher than a jump reaches from where she stands), `no_progress`
        //    (its HP unchanged for 300 frames),
        //    `low_hp` (the player's HP at or below `stop_hp`), `mode_changed` (not in play any more: a scene, a menu), or
        //    `timeout` at the frame limit. Reports hits taken, attacks tapped, jumps and the target's HP at start and end.
        private const float UnreachableDy = 180f;
        private const int NoProgressFrames = 300;

        public static Func<JToken> Fight(JObject args, int frameLimit, Func<CharacterBase> player, Func<string> mode, Func<bool, JObject> observe)
        {
            string wantType = (string)args["type"];
            float range = (float?)args["range"] ?? 110f;
            int stopHp = (int?)args["stop_hp"] ?? 0;

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
                if (Time.frameCount - lastProgress >= NoProgressFrames) return Done("no_progress");
                if (stopHp > 0 && p.health <= stopHp) return Done("low_hp");
                if (mode() != "play") return Done("mode_changed");
                if (Time.frameCount - start >= frameLimit) return Done("timeout");
                if (Utility.isOutsideCamera(target.t.position, 64f)) return Done("lost");

                Vector3 me3 = p.t.position, it = target.t.position;
                float dx = it.x - me3.x, dy = it.y - me3.y;
                string toward = dx >= 0 ? "XAxis+" : "XAxis-";
                bool onGround = p.onGround();
                if (onGround) groundY = me3.y;
                float reachDy = it.y - groundY;

                if (Mathf.Abs(dx) > range)
                {
                    InputInjection.Keep(toward);
                    bool notMoving = Mathf.Abs(me3.x - lastX) < 0.5f;
                    stuckFrames = notMoving ? stuckFrames + 1 : 0;
                    // Out of a jump's reach (a full jump rose 175 units, MEASURED.md) and not getting closer: say so, never flail.
                    blockedFrames = notMoving && reachDy > UnreachableDy ? blockedFrames + 1 : 0;
                    if (blockedFrames >= 45) return Done("unreachable");
                    if (onGround && (stuckFrames >= 12 || dy > 90f))
                    {
                        if (InputInjection.Tap("Jump", 16)) jumps++;
                        stuckFrames = 0;
                    }
                    outOfReachFrames = Mathf.Abs(reachDy) > 90f ? outOfReachFrames + 1 : 0;
                    if (outOfReachFrames > 90 && Mathf.Abs(dx) < 500f)
                    {
                        if (InputInjection.Tap("Ranged", 4)) ranged++;
                    }
                }
                else
                {
                    stuckFrames = 0;
                    // Turn to face it first: a one-frame hold toward it, then the attack.
                    bool facingIt = (dx >= 0) == (p.direction.ToString() == "RIGHT");
                    if (!facingIt)
                    {
                        InputInjection.Keep(toward);
                    }
                    else if (dy > 90f && onGround)
                    {
                        if (InputInjection.Tap("Jump", 16)) jumps++;
                    }
                    else if (Mathf.Abs(dy) <= 90f)
                    {
                        if (InputInjection.Tap("Attack", 4)) attacks++;
                    }
                    else if (InputInjection.Tap("Ranged", 4))
                    {
                        ranged++;
                    }
                }
                lastX = me3.x;
                return null;
            };
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
