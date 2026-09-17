using System;
using System.Collections.Generic;
using System.Text;
using Bullet;
using Character;
using EventMode;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // What is around the player, read from the game's own state rather than from a picture (the approved plan, layer 1;
    // agent_docs/phases/autoplay/tevi.md). Names from the Steam build's assemblies (2026-09-17): the character list
    // (CharacterManager.characters), the tile grid the game tests walls against (WorldManager.areadata.hitbox, TILESIZE
    // wide tiles, indexed x + y * MaxTileX), the camera's edges, the map's elements and items (areadata.elementlist and
    // itemlist), and the bullet pool (BulletManager). What each field MEANS is measured before it is relied on: until an
    // entry in adapters/tevi/MEASURED.md says so, a raw value keeps its _raw name.
    public static class Surroundings
    {
        // The text map's size in tiles around the player: a little more than the 1280x720 screen at 56 per tile.
        public const int MapHalfWidth = 13, MapHalfHeight = 8;

        // How far past the camera's edges a thing is still listed, in world units.
        private const float Margin = 280f;

        public static JObject Player(CharacterBase p)
        {
            var o = new JObject
            {
                ["on_ground"] = p.onGround(),
                ["logic"] = p.logicStatus.ToString(),
                ["at_wall_raw"] = p.atWall,
            };
            if (p.phy_perfer != null)
            {
                Vector3 v = p.phy_perfer._velocity;
                o["velocity"] = new JObject { ["x"] = Math.Round(v.x, 2), ["y"] = Math.Round(v.y, 2) };
            }
            return o;
        }

        public static JObject View()
        {
            CameraScript cam = CameraScript.Instance;
            if (cam == null) return null;
            return new JObject
            {
                ["left"] = Math.Round(cam.GetEdgeLeft(), 1),
                ["right"] = Math.Round(cam.GetEdgeRight(), 1),
                ["top"] = Math.Round(cam.GetEdgeTop(), 1),
                ["bottom"] = Math.Round(cam.GetEdgeBottom(), 1),
            };
        }

        private static bool InView(Vector3 pos, JObject view)
        {
            if (view == null) return true;
            float l = (float)view["left"] - Margin, r = (float)view["right"] + Margin;
            float top = (float)view["top"], bottom = (float)view["bottom"];
            float lo = Math.Min(top, bottom) - Margin, hi = Math.Max(top, bottom) + Margin;
            return pos.x >= l && pos.x <= r && pos.y >= lo && pos.y <= hi;
        }

        // The tile a world position is in, as the game's own wall test computes it.
        public static void Tile(Vector3 pos, out int tx, out int ty)
        {
            float size = MainVar.instance.TILESIZE;
            tx = (int)(pos.x / size);
            ty = (int)(-pos.y / size) + 1;
        }

        private static JObject Offset(Vector3 pos, Vector3 from)
        {
            Tile(pos, out int tx, out int ty);
            return new JObject
            {
                ["x"] = Math.Round(pos.x, 1),
                ["y"] = Math.Round(pos.y, 1),
                ["dx"] = Math.Round(pos.x - from.x, 1),
                ["dy"] = Math.Round(pos.y - from.y, 1),
                ["tile_x"] = tx,
                ["tile_y"] = ty,
            };
        }

        public static JArray Characters(CharacterBase player, JObject view)
        {
            var arr = new JArray();
            CharacterManager cm = CharacterManager.Instance;
            if (cm == null || cm.characters == null) return arr;
            Vector3 from = player.t.position;
            foreach (CharacterBase c in cm.characters)
            {
                if (c == null || c == player || c.t == null || !InView(c.t.position, view)) continue;
                JObject o = Offset(c.t.position, from);
                o["type"] = c.type.ToString();
                o["role"] = c.isBoss.ToString();
                o["id"] = c.ID;
                o["hp"] = c.health;
                o["max_hp"] = c.maxhealth;
                o["logic"] = c.logicStatus.ToString();
                o["enemy_raw"] = SafeBool(c.isCharacterEnemy);
                o["on_screen_raw"] = !Utility.isOutsideCamera(c.t.position, 0f);
                arr.Add(o);
            }
            return arr;
        }

        public static JArray Elements(Vector3 from, JObject view)
        {
            var arr = new JArray();
            AreaMapData area = WorldManager.Instance != null ? WorldManager.Instance.areadata : null;
            if (area == null || area.elementlist == null) return arr;
            foreach (ElementTile e in area.elementlist)
            {
                if (e == null) continue;
                Vector3 pos = e.transform.position;
                if (!InView(pos, view)) continue;
                JObject o = Offset(pos, from);
                o["type"] = e.elementtype.ToString();
                o["active_raw"] = e.gameObject.activeInHierarchy;
                arr.Add(o);
            }
            return arr;
        }

        // The whole area's elements, not only those in view: per type, how many and the nearest few, so a teleport can aim at
        // something off screen (an enemy's spawn, a spike, a door marker). Kept small: the link caps a line at 64 KB.
        public static JObject AreaElements(Vector3 from, int nearest)
        {
            var o = new JObject();
            AreaMapData area = WorldManager.Instance != null ? WorldManager.Instance.areadata : null;
            if (area == null || area.elementlist == null) return o;
            var byType = new Dictionary<string, List<KeyValuePair<float, ElementTile>>>();
            foreach (ElementTile e in area.elementlist)
            {
                if (e == null) continue;
                string type = e.elementtype.ToString();
                if (!byType.TryGetValue(type, out var list)) byType[type] = list = new List<KeyValuePair<float, ElementTile>>();
                list.Add(new KeyValuePair<float, ElementTile>((e.transform.position - from).sqrMagnitude, e));
            }
            var keys = new List<string>(byType.Keys);
            keys.Sort(StringComparer.Ordinal);
            foreach (string type in keys)
            {
                var list = byType[type];
                list.Sort((a, b) => a.Key.CompareTo(b.Key));
                var near = new JArray();
                for (int i = 0; i < list.Count && i < nearest; i++)
                {
                    JObject at = Offset(list[i].Value.transform.position, from);
                    at["active_raw"] = list[i].Value.gameObject.activeInHierarchy;
                    near.Add(at);
                }
                o[type] = new JObject { ["count"] = list.Count, ["nearest"] = near };
            }
            return o;
        }

        public static JArray Items(Vector3 from, JObject view)
        {
            var arr = new JArray();
            AreaMapData area = WorldManager.Instance != null ? WorldManager.Instance.areadata : null;
            if (area == null || area.itemlist == null) return arr;
            foreach (ItemTile it in area.itemlist)
            {
                if (it == null || !it.gameObject.activeInHierarchy) continue;
                Vector3 pos = it.transform.position;
                if (!InView(pos, view)) continue;
                JObject o = Offset(pos, from);
                o["item"] = it.itemid.ToString();
                arr.Add(o);
            }
            return arr;
        }

        public static JObject Projectiles(CharacterBase player, JObject view, int nearest)
        {
            BulletManager bm = BulletManager.Instance;
            if (bm == null || bm.bullets_enable == null) return null;
            Vector3 from = player.t.position;
            var found = new List<KeyValuePair<float, JObject>>();
            int active = 0;
            for (int i = 0; i < bm.bullets_enable.Length; i++)
            {
                if (!bm.bullets_enable[i] || (bm.bullets_delay != null && i < bm.bullets_delay.Length && bm.bullets_delay[i] > 0)) continue;
                bulletScript b = bm.GetBullet(i);
                if (b == null || b.t == null) continue;
                active++;
                if (!InView(b.t.position, view)) continue;
                JObject o = Offset(b.t.position, from);
                o["slot"] = i;
                o["type"] = b.type.ToString();
                o["owner"] = b.owner == null ? "none" : b.owner == player ? "player" : b.owner.type.ToString();
                found.Add(new KeyValuePair<float, JObject>((b.t.position - from).sqrMagnitude, o));
            }
            found.Sort((a, c) => a.Key.CompareTo(c.Key));
            var list = new JArray();
            for (int i = 0; i < found.Count && i < nearest; i++) list.Add(found[i].Value);
            return new JObject { ["active"] = active, ["in_view"] = found.Count, ["nearest"] = list };
        }

        // A text map of the game's collision grid around the player, one row per tile, top row first. Symbols: '@' the
        // player's tile, '.' 0, '#' 1, '/' 2-99, '\' 100-254, '=' 255 (byte meanings from the game's wall test, read as a
        // map: to be confirmed against a picture), ':' outside the grid; a character, element or item drawn over its tile
        // by its first letter as the legend lists.
        public static JObject LocalMap(CharacterBase player, JArray characters, JArray elements, JArray items)
        {
            WorldManager wm = WorldManager.Instance;
            if (wm == null || wm.areadata == null || wm.areadata.hitbox == null) return null;
            int maxX = MainVar.instance.MaxTileX, maxY = MainVar.instance.MaxTileY;
            byte[] grid = wm.areadata.hitbox;
            bool[,] destroyed = wm.tileDestroyed;
            Tile(player.t.position, out int px, out int py);

            var overlay = new Dictionary<long, char>();
            var legend = new JObject();
            void Put(JArray list, Func<JObject, string> name)
            {
                foreach (JObject o in list)
                {
                    string n = name(o) ?? "?";
                    char sym = char.ToUpperInvariant(n.Length > 0 ? n[0] : '?');
                    if (sym == '#' || sym == '.' || sym == '@') sym = '?';
                    long key = ((long)(int)o["tile_x"] << 32) | (uint)(int)o["tile_y"];
                    if (!overlay.ContainsKey(key)) overlay[key] = sym;
                    string entry = legend[sym.ToString()]?.ToString();
                    if (entry == null) legend[sym.ToString()] = n;
                    else if (!entry.Contains(n)) legend[sym.ToString()] = entry + ", " + n;
                }
            }
            Put(characters, o => (string)o["role"] == "NONE" ? "enemy:" + (string)o["type"] : ((string)o["role"]).ToLowerInvariant() + ":" + (string)o["type"]);
            // Only elements a player meets are drawn: map decoration and markers (MAPOBJECT*, Fade*, ID<n>, MapPoint) hid the
            // tile under them (measured 2026-09-17: ID1 over a bookshelf's first platform tile). `elements` lists them all.
            var drawn = new JArray();
            foreach (JObject e in elements)
            {
                string t = (string)e["type"] ?? "";
                bool marker = t.StartsWith("MAPOBJECT") || t.StartsWith("Fade") || t == "MapPoint"
                    || (t.StartsWith("ID") && t.Length > 2 && char.IsDigit(t[2]));
                if (!marker) drawn.Add(e);
            }
            Put(drawn, o => (string)o["type"]);
            Put(items, o => "item:" + (string)o["item"]);

            var rows = new JArray();
            var sb = new StringBuilder();
            for (int y = py - MapHalfHeight; y <= py + MapHalfHeight; y++)
            {
                sb.Length = 0;
                for (int x = px - MapHalfWidth; x <= px + MapHalfWidth; x++)
                {
                    if (x == px && y == py) { sb.Append('@'); continue; }
                    if (overlay.TryGetValue(((long)x << 32) | (uint)y, out char o)) { sb.Append(o); continue; }
                    if (x < 0 || y < 0 || x >= maxX || y >= maxY) { sb.Append(':'); continue; }
                    byte v = destroyed != null && destroyed[x, y] ? (byte)0 : grid[x + y * maxX];
                    sb.Append(v == 0 ? '.' : v == 1 ? '#' : v == 255 ? '=' : v < 100 ? '/' : '\\');
                }
                rows.Add(sb.ToString());
            }
            legend["@"] = "you";
            legend["."] = "tile byte 0";
            legend["#"] = "tile byte 1";
            legend["/"] = "tile byte 2-99";
            legend["\\"] = "tile byte 100-254";
            legend["="] = "tile byte 255";
            return new JObject
            {
                ["rows"] = rows,
                ["origin_tile_x"] = px - MapHalfWidth,
                ["origin_tile_y"] = py - MapHalfHeight,
                ["player_tile"] = new JObject { ["x"] = px, ["y"] = py },
                ["legend"] = legend,
            };
        }

        private static JToken SafeBool(Func<bool> f)
        {
            try
            {
                return f();
            }
            catch (Exception)
            {
                return null;
            }
        }
    }
}
