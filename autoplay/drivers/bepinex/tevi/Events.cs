using System;
using System.Collections.Generic;
using HarmonyLib;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // EVENTS past mode, area and room (Plugin.SendEvents): what happens to the player, reported the frame it happens.
    //
    // - damage_taken: a hit. Every hit on a character goes through CharacterBase.BulletHurtPlayer, the player's and an
    //   enemy's alike (names read from the Steam build's assemblies, 2026-09-17); a prefix keeps the player's HP before
    //   and a postfix reports the hit when the HP it had then went down, with what the game passed: the owner (a
    //   character, as observe's nearby names one), the bullet's type, blocked, and the damage it computed.
    // - enemy_defeated: a hit through the same method taking another character's HP from above 0 to 0 (its type, as
    //   nearby names it, and whether the hit's owner was the player).
    // - hp_changed: the player's HP differs from the last frame's, by any cause -- a hit, and also what never passes
    //   through a hit (buffs over time, a fall, a heal, a script). A hit reports both.
    // - game_over: GameSystem.isGameOver() rising above 0.
    // - dialogue_changed: a conversation opening, moving to another line or section, or closing.
    // - menu_changed: the menu observe reads (the save list, the title's menus) opening, changing or closing.
    // - tip_shown: a short instruction banner (observe's tip) coming up, with its keyword and text.
    // - interact_changed: the bubble saying Up does something here (observe's interact) appearing, changing kind or going.
    // - popup_shown: the message sliding in at the bottom left (observe's popup: a new ability and how to use it).
    // - item_obtained: the box naming an item just picked up (observe's obtained) coming up.
    //
    // Reading only: nothing here changes what the game does. The patch goes with the plugin (removed in OnDestroy) as
    // InputInjection's do.
    public static class Events
    {
        public const string HarmonyId = "dev.meshghost.autoplay.events";

        private static Harmony harmony;
        private static readonly Queue<JObject> Pending = new Queue<JObject>();
        private const int MaxPending = 256;

        private static int lastHp = int.MinValue;
        private static bool lastGameOver;
        private static string lastDialogue, lastMenu, lastTip, lastItem, lastInteract, lastPopup;
        private static bool primed;

        public static void Install()
        {
            if (harmony != null) return;
            harmony = new Harmony(HarmonyId);
            var hurt = AccessTools.Method(typeof(CharacterBase), nameof(CharacterBase.BulletHurtPlayer));
            harmony.Patch(hurt, prefix: new HarmonyMethod(typeof(Events), nameof(HurtPrefix)), postfix: new HarmonyMethod(typeof(Events), nameof(HurtPostfix)));
        }

        public static void Uninstall()
        {
            harmony?.UnpatchSelf();
            harmony = null;
            lock (Pending) Pending.Clear();
            primed = false;
        }

        private static bool IsPlayer(CharacterBase c)
        {
            try
            {
                return c != null && c.isPlayer();
            }
            catch (Exception)
            {
                return false;
            }
        }

        private static void HurtPrefix(CharacterBase __instance, out int __state)
        {
            __state = __instance != null ? __instance.health : int.MinValue;
        }

        private static void HurtPostfix(CharacterBase __instance, int __state, bool __result, CharacterBase owner, float damage, Bullet.BulletType type, bool blocked, ref float finaldamage)
        {
            if (__state == int.MinValue) return;
            int now = __instance.health;
            if (!IsPlayer(__instance))
            {
                if (__state > 0 && now <= 0)
                {
                    var d = new JObject
                    {
                        ["kind"] = "enemy_defeated",
                        ["frame"] = Time.frameCount,
                        ["type"] = __instance.type.ToString(),
                        ["role"] = __instance.isBoss.ToString(),
                        ["id"] = __instance.ID,
                        ["max_hp"] = __instance.maxhealth,
                        ["bullet_type"] = type.ToString(),
                        ["by_player_raw"] = IsPlayer(owner),
                    };
                    if (__instance.t != null)
                    {
                        d["x"] = Math.Round(__instance.t.position.x, 1);
                        d["y"] = Math.Round(__instance.t.position.y, 1);
                    }
                    Enqueue(d);
                }
                return;
            }
            if (now >= __state) return;
            var e = new JObject
            {
                ["kind"] = "damage_taken",
                ["frame"] = Time.frameCount,
                ["hp_from"] = __state,
                ["hp_to"] = now,
                ["damage"] = __state - now,
                ["max_hp"] = __instance.maxhealth,
                ["bullet_type"] = type.ToString(),
                ["damage_passed_raw"] = Math.Round(damage, 2),
                ["final_damage_raw"] = Math.Round(finaldamage, 2),
                ["blocked_raw"] = blocked,
                ["result_raw"] = __result,
                ["logic"] = __instance.logicStatus.ToString(),
            };
            if (__instance.t != null)
            {
                e["x"] = Math.Round(__instance.t.position.x, 1);
                e["y"] = Math.Round(__instance.t.position.y, 1);
            }
            if (owner != null && owner != __instance)
            {
                var src = new JObject { ["type"] = owner.type.ToString(), ["role"] = owner.isBoss.ToString(), ["id"] = owner.ID };
                if (owner.t != null && __instance.t != null)
                {
                    src["dx"] = Math.Round(owner.t.position.x - __instance.t.position.x, 1);
                    src["dy"] = Math.Round(owner.t.position.y - __instance.t.position.y, 1);
                }
                e["source"] = src;
            }
            Enqueue(e);
        }

        private static void Enqueue(JObject e)
        {
            lock (Pending)
            {
                if (Pending.Count >= MaxPending) Pending.Dequeue();
                Pending.Enqueue(e);
            }
        }

        // Once a frame, from Plugin.Update: the watched values compared with the last frame's. The first frame after a
        // load only records them, so a reload never reports the whole state as changed.
        public static void Poll(CharacterBase player, JObject dialogue, JObject menu, JObject tip, JObject obtained, JObject interact, JObject popup)
        {
            int hp = player != null ? player.health : int.MinValue;
            bool over = GameSystem.Instance != null && GameSystem.Instance.isGameOver() > 0f;
            string dlg = dialogue == null ? null : (string)dialogue["section"] + "#" + (int?)dialogue["line"];
            string mnu = menu == null ? null : menu.ToString(Newtonsoft.Json.Formatting.None);
            string tipKey = tip == null || !(bool)tip["shown"] ? null : (string)tip["keyword"];
            string item = obtained == null ? null : (string)obtained["item"];
            string near = interact == null ? null : (string)interact["kind"];
            string pop = popup == null ? null : (string)popup["title"] + "|" + (string)popup["text"];
            if (primed)
            {
                if (hp != lastHp && hp != int.MinValue && lastHp != int.MinValue)
                {
                    Enqueue(new JObject { ["kind"] = "hp_changed", ["frame"] = Time.frameCount, ["from"] = lastHp, ["to"] = hp, ["max_hp"] = player.maxhealth });
                }
                if (over && !lastGameOver) Enqueue(new JObject { ["kind"] = "game_over", ["frame"] = Time.frameCount, ["hp"] = hp == int.MinValue ? null : (JToken)hp });
                if (dlg != lastDialogue)
                {
                    var e = new JObject { ["kind"] = "dialogue_changed", ["frame"] = Time.frameCount, ["open"] = dialogue != null };
                    if (dialogue != null)
                    {
                        foreach (string k in new[] { "section", "line", "lines", "speaker", "text" }) e[k] = dialogue[k];
                    }
                    Enqueue(e);
                }
                if (tipKey != null && tipKey != lastTip)
                {
                    var e = new JObject { ["kind"] = "tip_shown", ["frame"] = Time.frameCount };
                    e.Merge(tip);
                    Enqueue(e);
                }
                if (pop != null && pop != lastPopup)
                {
                    Enqueue(new JObject { ["kind"] = "popup_shown", ["frame"] = Time.frameCount, ["title"] = popup["title"], ["text"] = popup["text"] });
                }
                if (near != lastInteract)
                {
                    Enqueue(new JObject { ["kind"] = "interact_changed", ["frame"] = Time.frameCount, ["available"] = near != null, ["interact"] = near });
                }
                if (item != null && item != lastItem)
                {
                    var e = new JObject { ["kind"] = "item_obtained", ["frame"] = Time.frameCount };
                    e.Merge(obtained);
                    Enqueue(e);
                }
                if (mnu != lastMenu)
                {
                    var e = new JObject { ["kind"] = "menu_changed", ["frame"] = Time.frameCount, ["open"] = menu != null };
                    if (menu != null) e["menu"] = menu;
                    Enqueue(e);
                }
            }
            primed = true;
            lastHp = hp;
            lastGameOver = over;
            lastDialogue = dlg;
            lastMenu = mnu;
            if (tipKey != null || tip == null) lastTip = tipKey; // a banner still fading in is neither new nor gone
            lastItem = item;
            lastInteract = near;
            lastPopup = pop;
        }

        // No core connected: the next Poll only records, so a reconnect reports nothing that happened meanwhile.
        public static void Unprime()
        {
            primed = false;
        }

        public static List<JObject> Drain()
        {
            var out_ = new List<JObject>();
            lock (Pending)
            {
                while (Pending.Count > 0) out_.Add(Pending.Dequeue());
            }
            return out_;
        }
    }
}
