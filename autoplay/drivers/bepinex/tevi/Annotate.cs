using System;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // ANNOTATED PICTURES (the plan's layer 5; agent_docs/phases/phase13.md, "how an agent sees a game"): the game's frame with
    // what the driver reads drawn onto it, so a picture and the numbers are the same moment and say which thing is which.
    //
    // - The game's own hitbox drawing: BulletManager.showHitBox, the switch its debug console's `showHitBox` command calls (names
    //   read from the Steam build's assemblies, 2026-09-17), draws every live bullet's box -- the characters' body and hurt boxes
    //   are bullets too -- as world-space lines, so the frame capture has them. It is on only from the request until the
    //   captured frame, and off again after unless it was on before. Read as a map: while it is on, a slide starting or ending
    //   re-creates that character's body box (CharacterBase.ToggleSlide), so the switch is not only drawing; kept to those frames.
    // - Numbered tags drawn into the captured picture over each character, item and element a player meets in view (as observe's
    //   nearby, items and elements list them), and the same numbers listed in the answer with what each one is and its pixel.
    //   The world-to-pixel mapping is the camera's edges over the picture's size (a pixel was a world unit, MEASURED.md).
    public static class Annotate
    {
        private static readonly FieldInfo UpdatedCount = typeof(BulletManager).GetField("updatedCount", BindingFlags.Instance | BindingFlags.NonPublic);

        // How many frames to wait for the game's debug update to draw once the switch is on, before capturing without it.
        private const int DrawWaitFrames = 10;

        public static IEnumerator Capture(string path, bool annotate, Func<CharacterBase> player, Action<JObject, string> done)
        {
            BulletManager bm = BulletManager.Instance;
            bool switched = false, drawn = false;
            int waited = 0;
            if (annotate && bm != null && WorldManager.Instance != null && WorldManager.Instance.MapInited)
            {
                if (!bm.isShowHitBox)
                {
                    bm.showHitBox(true);
                    switched = true;
                }
                // Wait for a frame whose debug update has run with the switch on: `yield return null` resumes after this
                // frame's Updates, so a count that has moved means the lines for this frame are set.
                int before = UpdatedCount != null ? (int)UpdatedCount.GetValue(bm) : -1;
                while (waited < DrawWaitFrames)
                {
                    yield return null;
                    waited++;
                    if (UpdatedCount == null || (int)UpdatedCount.GetValue(bm) != before)
                    {
                        drawn = UpdatedCount != null;
                        break;
                    }
                }
            }
            yield return new WaitForEndOfFrame();
            JObject answer = null;
            string error = null;
            try
            {
                Texture2D tex = ScreenCapture.CaptureScreenshotAsTexture();
                int w = tex.width, h = tex.height;
                answer = new JObject { ["path"] = path, ["width"] = w, ["height"] = h, ["frame"] = Time.frameCount };
                if (annotate)
                {
                    JArray labels = DrawLabels(tex, player());
                    tex.Apply();
                    answer["annotated"] = new JObject
                    {
                        ["hitboxes"] = drawn,
                        ["hitbox_switch"] = switched ? "on for this frame" : bm != null && bm.isShowHitBox ? "already on" : "unavailable",
                        ["frames_waited"] = waited,
                        ["labels"] = labels,
                    };
                }
                byte[] png = tex.EncodeToPNG();
                UnityEngine.Object.Destroy(tex);
                System.IO.File.WriteAllBytes(path, png);
                answer["bytes"] = png.Length;
            }
            catch (Exception e)
            {
                error = "screenshot: " + e.Message;
            }
            finally
            {
                if (switched && BulletManager.Instance != null) BulletManager.Instance.showHitBox(false);
            }
            done(answer, error);
        }

        private static JArray DrawLabels(Texture2D tex, CharacterBase p)
        {
            var labels = new JArray();
            JObject view = Surroundings.View();
            if (p == null || p.t == null || view == null) return labels;
            float left = (float)view["left"], right = (float)view["right"], top = (float)view["top"], bottom = (float)view["bottom"];
            if (right <= left || top == bottom) return labels;
            Vector3 from = p.t.position;

            var things = new List<KeyValuePair<Vector3, JObject>>();
            CharacterManager cm = CharacterManager.Instance;
            if (cm != null && cm.characters != null)
            {
                foreach (CharacterBase c in cm.characters)
                {
                    if (c == null || c == p || c.t == null || !c.gameObject.activeInHierarchy) continue;
                    things.Add(new KeyValuePair<Vector3, JObject>(c.t.position, new JObject
                    {
                        ["kind"] = c.isBoss.ToString() == "NONE" ? "enemy" : c.isBoss.ToString().ToLowerInvariant(),
                        ["what"] = c.type.ToString(),
                        ["hp"] = c.health,
                        ["max_hp"] = c.maxhealth,
                    }));
                }
            }
            AreaMapData area = WorldManager.Instance != null ? WorldManager.Instance.areadata : null;
            if (area != null && area.itemlist != null)
            {
                foreach (ItemTile it in area.itemlist)
                {
                    if (it == null || !it.gameObject.activeInHierarchy) continue;
                    things.Add(new KeyValuePair<Vector3, JObject>(it.transform.position, new JObject { ["kind"] = "item", ["what"] = it.itemid.ToString() }));
                }
            }
            if (area != null && area.elementlist != null)
            {
                foreach (ElementTile e in area.elementlist)
                {
                    if (e == null) continue;
                    string type = e.elementtype.ToString();
                    if (Surroundings.IsMarker(type)) continue;
                    things.Add(new KeyValuePair<Vector3, JObject>(e.transform.position, new JObject { ["kind"] = "element", ["what"] = type, ["active_raw"] = e.gameObject.activeInHierarchy }));
                }
            }

            int n = 0;
            foreach (var kv in things)
            {
                Vector3 pos = kv.Key;
                if (pos.x < left || pos.x > right || pos.y < Math.Min(top, bottom) || pos.y > Math.Max(top, bottom)) continue;
                // Texture rows count up from the bottom; the answer's py counts down from the top, as an image viewer does.
                int px = (int)((pos.x - left) / (right - left) * tex.width);
                int row = (int)((pos.y - Math.Min(top, bottom)) / Math.Abs(top - bottom) * tex.height);
                n++;
                JObject o = kv.Value;
                var label = new JObject { ["n"] = n };
                label.Merge(o);
                label["x"] = Math.Round(pos.x, 1);
                label["y"] = Math.Round(pos.y, 1);
                label["dx"] = Math.Round(pos.x - from.x, 1);
                label["dy"] = Math.Round(pos.y - from.y, 1);
                label["px"] = px;
                label["py"] = tex.height - 1 - row;
                labels.Add(label);
                Color frame = (string)o["kind"] == "item" ? Color.white : (string)o["kind"] == "element" ? new Color(0.4f, 1f, 0.4f) : new Color(1f, 0.55f, 0f);
                Tag(tex, px, row, n, frame);
                if (n >= 60) break;
            }
            return labels;
        }

        // A 3-by-5 pixel digit, row 0 at the top, drawn at Scale: one bit per pixel, left to right.
        private static readonly string[] Digits =
        {
            "111101101101111", "010110010010111", "111001111100111", "111001111001111", "101101111001001",
            "111100111001111", "111100111101111", "111001001001001", "111101111101111", "111101111001111",
        };
        private const int Scale = 3;

        // A cross on the point, and above it a dark box with the number, framed in the kind's colour.
        private static void Tag(Texture2D tex, int px, int row, int number, Color frame)
        {
            for (int i = -4; i <= 4; i++)
            {
                Set(tex, px + i, row, frame);
                Set(tex, px, row + i, frame);
            }
            string s = number.ToString();
            int w = s.Length * 4 * Scale + Scale + 2, h = 5 * Scale + 2 * Scale + 2;
            int x0 = px - w / 2, y0 = row + 8; // bottom edge of the box, above the cross
            for (int x = 0; x < w; x++)
            {
                for (int y = 0; y < h; y++)
                {
                    bool edge = x == 0 || y == 0 || x == w - 1 || y == h - 1;
                    Set(tex, x0 + x, y0 + y, edge ? frame : new Color(0f, 0f, 0f, 1f));
                }
            }
            for (int d = 0; d < s.Length; d++)
            {
                string bits = Digits[s[d] - '0'];
                int dx0 = x0 + 1 + Scale + d * 4 * Scale;
                for (int r = 0; r < 5; r++)
                {
                    for (int c = 0; c < 3; c++)
                    {
                        if (bits[r * 3 + c] != '1') continue;
                        for (int a = 0; a < Scale; a++)
                        {
                            for (int b = 0; b < Scale; b++)
                            {
                                // r counts from the top; texture rows from the bottom.
                                Set(tex, dx0 + c * Scale + a, y0 + h - 1 - Scale - (r + 1) * Scale + b, Color.white);
                            }
                        }
                    }
                }
            }
        }

        private static void Set(Texture2D tex, int x, int y, Color c)
        {
            if (x < 0 || y < 0 || x >= tex.width || y >= tex.height) return;
            tex.SetPixel(x, y, c);
        }
    }
}
