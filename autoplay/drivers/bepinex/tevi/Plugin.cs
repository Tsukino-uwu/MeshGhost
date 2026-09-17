using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using BepInEx;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // autoplay's TEVI driver (DEV TOOL, WRITES INPUT AND GAME STATE, never shipped; agent_docs/phases/phase13.md,
    // agent_docs/phases/autoplay/tevi.md, ADR 0071). A BepInEx plugin of its own, the way the dev cheats are: loaded by
    // ScriptEngine from a developer install's BepInEx\scripts\, never from plugins\, and never inside MeshGhostTevi.dll.
    // It carries out the autoplay core's commands over autoplay/driver/driver.go's protocol 1 (Link.cs).
    //
    // CONFIG: `meshghost-autoplay.txt` in BepInEx\scripts\, one `key=value` per line -- `port` (the core's; with no
    // file the driver connects nowhere) and `repo` (this repository's root, for screenshots, the exec token and the
    // driver's log under autoplay/runs/). Machine paths live there, in the install, never here.
    //
    // Names of the game's types and members are read from the Steam build's assemblies (agent_docs/licensing.md's
    // facts-not-code posture; the adapter's own measurements in adapters/tevi/documentation.md), and what each one
    // does is measured into agent_docs/phases/autoplay/tevi.md before anything here relies on it.
    [BepInPlugin("dev.meshghost.autoplay.tevi", "MeshGhost Autoplay TEVI driver", "0.1.0")]
    public class Plugin : BaseUnityPlugin
    {
        private const string GameName = "tevi";

        // The one in-game slot this driver plays and saves in (the user, 2026-09-17: vanilla 36-39 and Randomizer 36-80
        // are autoplay's). Its file is the save guard's shadow copy; every other slot is listed as protected in the hello.
        private const byte WorkingSlot = 39;
        private const int LastSlot = 100;

        private static readonly PropertyInfo MainCharacterProperty = typeof(EventManager).GetProperty("mainCharacter");

        private Link link;
        private int port; // 0: no config names one, so the driver connects nowhere
        private string repo;
        private string build = "unknown";
        private string logPath;
        private bool welcomedOnce;

        private Link.Request current;
        private Func<JToken> currentTick; // returns the answer when done, null while running; throws to fail
        private readonly Queue<Link.Request> waiting = new Queue<Link.Request>();

        private string lastMode, lastArea, lastRoom;

        private void Awake()
        {
            ReadConfig();
            build = BuildStamp();
            Log("loaded: port " + port + ", repo " + (repo ?? "(none: screenshots and exec are off)") + ", build " + build);
            Log(SaveGuard.Install(Application.persistentDataPath, repo == null ? null : repo + "/autoplay/states/" + GameName + "/shadow"));
            InputInjection.Install();
            Events.Install();
            Clock.Install();
            Threats.Install();
            if (port == 0) return;
            if (repo == null)
            {
                // No shadow folder without a repo, and a guard that only refuses breaks a new game (SaveGuard.cs).
                Log("no repo in meshghost-autoplay.txt: the driver connects nowhere without one");
                return;
            }
            link = new Link("127.0.0.1", port);
            link.SetHello(Hello());
        }

        private void OnDestroy()
        {
            link?.Dispose();
            InputInjection.Uninstall();
            Events.Uninstall();
            Clock.Uninstall();
            Threats.Uninstall();
            Log("unloaded (the save guard stays as it was: " + (SaveGuard.Armed ? "armed" : "not armed") + ")");
        }

        // Where this plugin's files sit. Not Info.Location: ScriptEngine loads a plugin from its bytes, and Location
        // reads empty, so a path built from it lands in the game's working folder (measured 2026-09-17: the first
        // load looked for .\meshghost-autoplay.txt, found none, and connected to the default port).
        private static string ScriptsDir => Path.Combine(Paths.BepInExRootPath, "scripts");

        private void ReadConfig()
        {
            string path = Path.Combine(ScriptsDir, "meshghost-autoplay.txt");
            if (!File.Exists(path))
            {
                // No port is guessed: another instance's core may own the default one.
                port = 0;
                Logger.LogWarning("autoplay: no " + path + "; the driver connects nowhere until it exists and the plugin reloads");
                return;
            }
            foreach (string raw in File.ReadAllLines(path))
            {
                string line = raw.Trim();
                int eq = line.IndexOf('=');
                if (line.StartsWith("#") || eq <= 0) continue;
                string key = line.Substring(0, eq).Trim().ToLowerInvariant();
                string value = line.Substring(eq + 1).Trim();
                if (key == "port" && int.TryParse(value, out int p) && p > 0 && p < 65536) port = p;
                else if (key == "repo" && Directory.Exists(Path.Combine(value, "autoplay"))) repo = value.Replace('\\', '/').TrimEnd('/');
                else Logger.LogWarning("autoplay: ignoring config line \"" + line + "\"");
            }
            if (repo != null)
            {
                Directory.CreateDirectory(repo + "/autoplay/runs");
                logPath = repo + "/autoplay/runs/driver_bepinex_" + GameName + "_" + port + ".log";
            }
        }

        private void Log(string msg)
        {
            Logger.LogInfo("autoplay: " + msg);
            if (logPath == null) return;
            try
            {
                File.AppendAllText(logPath, "[" + DateTime.Now.ToString("HH:mm:ss") + " f" + Time.frameCount + "] " + msg + "\n");
            }
            catch (Exception e)
            {
                Logger.LogWarning("autoplay: log file: " + e.Message);
                logPath = null;
            }
        }

        // The game's own assembly, hashed: facts measured on one build are facts about that build.
        private static string BuildStamp()
        {
            try
            {
                string dll = Path.Combine(Path.Combine(Application.dataPath, "Managed"), "Assembly-CSharp.dll");
                using (var sha = SHA256.Create())
                using (var f = File.OpenRead(dll))
                {
                    return "Assembly-CSharp sha256 " + BitConverter.ToString(sha.ComputeHash(f)).Replace("-", "").Substring(0, 16).ToLowerInvariant();
                }
            }
            catch (Exception e)
            {
                return "unknown (" + e.Message + ")";
            }
        }

        // ---- what the driver says about itself ------------------------------------------------------------------

        private static readonly string[] Capabilities = { "observe", "wait", "press", "sequence", "advance_text", "screenshot", "screenshot:annotate", "snapshot", "restore", "cheat:teleport", "reflex:fight", "reflex:evade", "clock", "recent" };

        private JObject Hello()
        {
            var slots = new JArray();
            for (int i = 0; i <= LastSlot; i++)
            {
                if (i != WorkingSlot) slots.Add(i);
            }
            var hello = new JObject
            {
                ["protocol"] = Link.Protocol,
                ["host"] = "bepinex",
                ["game"] = GameName,
                ["variant"] = RandomizerEnabled() == true ? "randomizer" : "vanilla",
                ["build"] = build,
                ["capabilities"] = new JArray(Capabilities),
                ["protected_slots"] = slots,
            };
            JArray persisting = Persisting();
            if (persisting.Count > 0) hello["persisting"] = persisting;
            return hello;
        }

        // The Randomizer's own switch (TeviRandomizer.RandomizerPlugin.randomizerEnabled), when it is loaded: while on,
        // every slot's file is its randomizer/rando.tevisave<N>.sav. Null without the mod.
        private static FieldInfo randomizerField;
        private static bool randomizerLooked;

        private static bool? RandomizerEnabled()
        {
            if (!randomizerLooked)
            {
                randomizerLooked = true;
                foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies())
                {
                    Type t = a.GetType("TeviRandomizer.RandomizerPlugin", false);
                    if (t == null) continue;
                    randomizerField = t.GetField("randomizerEnabled", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
                    break;
                }
            }
            return randomizerField != null ? (bool?)(bool)randomizerField.GetValue(null) : null;
        }

        // The dev cheats (adapters/tevi/devtools/MeshGhostTeviDevCheats) hold HP, MP, charge and crystals every frame
        // while loaded, each unless its toggle file says =0: a run segment with any of them on is not walked.
        private JArray Persisting()
        {
            var out_ = new JArray();
            foreach (BaseUnityPlugin plugin in FindObjectsOfType<BaseUnityPlugin>())
            {
                if (plugin == null || plugin.GetType().FullName != "MeshGhostTeviDevCheats.Plugin") continue;
                var on = new Dictionary<string, bool> { ["hp"] = true, ["mp"] = true, ["charge"] = true, ["crystal"] = true, ["swap"] = true };
                // Where the dev cheats read it: they build the path from their own location, which is empty under
                // ScriptEngine, so it is the game's root folder, not scripts\ (their load line named
                // .\meshghost-devcheats.txt and a file in the root switched them off, 2026-09-17).
                string toggles = Path.Combine(Paths.GameRootPath, "meshghost-devcheats.txt");
                try
                {
                    if (File.Exists(toggles))
                    {
                        foreach (string raw in File.ReadAllLines(toggles))
                        {
                            int eq = raw.IndexOf('=');
                            if (eq <= 0) continue;
                            string key = raw.Substring(0, eq).Trim().ToLowerInvariant();
                            if (on.ContainsKey(key)) on[key] = raw.Substring(eq + 1).Trim() != "0";
                        }
                    }
                }
                catch (Exception)
                {
                    // Unreadable: the cheats keep their last values, which this cannot know; say all on.
                }
                foreach (var kv in on)
                {
                    if (kv.Value) out_.Add("devcheats_" + kv.Key);
                }
                break;
            }
            return out_;
        }

        // ---- reading the game ------------------------------------------------------------------------------------

        private static CharacterBase Player()
        {
            EventManager em = EventManager.Instance;
            if (em == null || MainCharacterProperty == null) return null;
            return MainCharacterProperty.GetValue(em, null) as CharacterBase;
        }

        private static string Mode()
        {
            WorldManager wm = WorldManager.Instance;
            if (wm == null) return GemaTitleScreenManager.Instance != null ? "title" : "no_world";
            CharacterBase p = Player();
            EventManager em = EventManager.Instance;
            if (p == null || p.t == null || em == null) return "no_player";
            if (!wm.MapInited || em.IsChangingMap()) return "loading";
            if (GameSystem.Instance != null && GameSystem.Instance.isAnyPause()) return "paused";
            if (em.getMode() != EventMode.Mode.OFF) return "event";
            return "play";
        }

        private JObject Observe(bool full)
        {
            var o = new JObject
            {
                ["frame"] = Time.frameCount,
                ["mode"] = Mode(),
            };
            WorldManager wm = WorldManager.Instance;
            CharacterBase p = Player();
            if (wm != null)
            {
                var loc = new JObject
                {
                    ["area"] = wm.CurrentRoomArea.ToString(),
                    ["area_id"] = (int)wm.Area,
                    ["room_x"] = (int)wm.CurrentRoomX,
                    ["room_y"] = (int)wm.CurrentRoomY,
                };
                if (p != null && p.t != null)
                {
                    Vector3 pos = p.t.position;
                    loc["x"] = Math.Round(pos.x, 3);
                    loc["y"] = Math.Round(pos.y, 3);
                    loc["facing"] = p.direction.ToString();
                }
                o["location"] = loc;
            }
            JObject menu = SaveMenu() ?? TitleMenu();
            if (menu != null) o["menu"] = menu;
            JObject dialogue = Dialogue();
            if (dialogue != null) o["dialogue"] = dialogue;
            JObject tip = Tip();
            if (tip != null) o["tip"] = tip;
            JObject obtained = Obtained();
            if (obtained != null) o["obtained"] = obtained;
            JObject interact = Interact();
            if (interact != null) o["interact"] = interact;
            JObject popup = Popup();
            if (popup != null) o["popup"] = popup;
            if (p != null && p.t != null)
            {
                o["player"] = new JObject
                {
                    ["hp"] = p.health,
                    ["max_hp"] = p.maxhealth,
                    ["anim"] = p.spranim_prefer != null && p.spranim_prefer.pixel != null && p.spranim_prefer.pixel.anim != null
                        ? p.spranim_prefer.GetAnimationTrueName() : p.aniStatus.ToString(),
                };
            }
            if (full && p != null && p.t != null && wm != null)
            {
                // What is around the player, from the game's own state (Surroundings.cs).
                ((JObject)o["player"]).Merge(Surroundings.Player(p));
                JObject view = Surroundings.View();
                JArray characters = Surroundings.Characters(p, view);
                JArray elements = Surroundings.Elements(p.t.position, view);
                JArray items = Surroundings.Items(p.t.position, view);
                o["view"] = view;
                o["local_map"] = Surroundings.LocalMap(p, characters, elements, items);
                o["nearby"] = characters;
                o["elements"] = elements;
                o["items"] = items;
                o["projectiles"] = Surroundings.Projectiles(p, view, 8);
                var lasers = new JArray();
                foreach (Threats.Laser l in Threats.ReadLasers(p))
                {
                    lasers.Add(new JObject { ["type"] = l.Type, ["from"] = new JArray(Math.Round(l.From.x, 1), Math.Round(l.From.y, 1)), ["to"] = new JArray(Math.Round(l.To.x, 1), Math.Round(l.To.y, 1)), ["radius"] = Math.Round(l.Radius, 1), ["hurting_raw"] = l.Hurting });
                }
                o["lasers"] = lasers;
                o["area_elements"] = Surroundings.AreaElements(p.t.position, 3);
            }
            if (full)
            {
                EventManager em = EventManager.Instance;
                o["save"] = new JObject
                {
                    ["slot"] = MainVar.instance._saveslot,
                    ["randomizer"] = RandomizerEnabled(),
                    ["guard"] = SaveGuard.Report(),
                };
                if (SaveManager.Instance != null && wm != null)
                {
                    // The Custom Game options this save runs with, as the game answers for each (not the title screen's
                    // choice: the Randomizer turns some on by itself).
                    var custom = new JArray();
                    for (byte i = 0; i < (byte)Game.CustomGame.MAX; i++)
                    {
                        if (SaveManager.Instance.GetCustomGame((Game.CustomGame)i)) custom.Add(((Game.CustomGame)i).ToString());
                    }
                    o["save"]["custom_game"] = custom;
                }
                o["screen_text"] = ScreenText();
                o["trail"] = Recorder.Trail(180, 3);
                o["extras"] = new JObject
                {
                    ["event_mode_raw"] = em != null ? em.getMode().ToString() : null,
                    ["changing_map_raw"] = em != null && wm != null ? (JToken)em.IsChangingMap() : null,
                    ["any_pause_raw"] = GameSystem.Instance != null ? (JToken)GameSystem.Instance.isAnyPause() : null,
                    ["map_inited_raw"] = wm != null ? (JToken)wm.MapInited : null,
                    ["fade_alpha_raw"] = FadeManager.Instance != null ? (JToken)Math.Round(FadeManager.Instance.GetCurrentAlpha(), 3) : null,
                    ["fade_target_raw"] = FadeManager.Instance != null ? (JToken)Math.Round(FadeManager.Instance.GetTargetAlpha(), 3) : null,
                    ["input_actions"] = InputInjection.Actions(),
                    ["input_focus"] = InputInjection.FocusReport(),
                    ["clock"] = Clock.Report(),
                    ["recorder_cost"] = Recorder.Cost(),
                };
                JArray persisting = Persisting();
                if (persisting.Count > 0) o["persisting"] = persisting;
            }
            return o;
        }

        private static readonly FieldInfo SaveMenuPage = typeof(HUDSaveMenu).GetField("page", BindingFlags.Instance | BindingFlags.NonPublic);
        private static readonly FieldInfo SaveMenuSelected = typeof(HUDSaveMenu).GetField("selected", BindingFlags.Instance | BindingFlags.NonPublic);
        private static readonly FieldInfo SaveMenuEntering = typeof(HUDSaveMenu).GetField("isEntering", BindingFlags.Instance | BindingFlags.NonPublic);

        // The save list (title and in game): 4 rows a page, a slot is page * 4 + row. Its fields are the menu's own, so
        // `slot` is where the game's cursor is, whatever the highlight has drawn yet.
        private static JObject SaveMenu()
        {
            HUDSaveMenu m = HUDSaveMenu.Instance;
            if (m == null || !m.gameObject.activeInHierarchy || SaveMenuPage == null || SaveMenuSelected == null) return null;
            byte page = (byte)SaveMenuPage.GetValue(m), row = (byte)SaveMenuSelected.GetValue(m);
            return new JObject
            {
                ["name"] = "save_list",
                ["purpose"] = m.isSave ? "save" : "load_or_new",
                ["page"] = page,
                ["row"] = row,
                ["slot"] = page * 4 + row,
                ["question"] = m.isQuestion(),
                ["entering"] = SaveMenuEntering != null && (bool)SaveMenuEntering.GetValue(m),
            };
        }

        private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;

        // The title's own menus: the main menu, Custom Game and the difficulty list. Each keeps its entries in a private
        // `selections` (slots whose GetText is the text drawn) and its cursor in a private byte `selected`; the title
        // screen holds the other two. Only the one on screen is returned.
        private static JObject TitleMenu()
        {
            GemaTitleScreenManager title = GemaTitleScreenManager.Instance;
            if (title == null || WorldManager.Instance != null) return null;
            if (title.GetType().GetField("gemanewgame", Private)?.GetValue(title) is GemaNewGame difficulty && difficulty.isActiveAndEnabled)
            {
                return ListMenu("difficulty", difficulty);
            }
            if (title.GetType().GetField("gemacustomgame", Private)?.GetValue(title) is GemaCustomGame custom && custom.isActiveAndEnabled)
            {
                JObject m = ListMenu("custom_game", custom);
                if (m != null && MainVar.instance.NewCustomGame != null)
                {
                    var ticked = new JArray();
                    foreach (bool b in MainVar.instance.NewCustomGame) ticked.Add(b);
                    m["ticked"] = ticked;
                }
                return m;
            }
            MethodInfo inTitle = title.GetType().GetMethod("InTitleScreen", Private);
            if (inTitle != null && (bool)inTitle.Invoke(title, null)) return ListMenu("title", title);
            return null;
        }

        private static JObject ListMenu(string name, object owner)
        {
            if (!(owner.GetType().GetField("selections", Private)?.GetValue(owner) is IEnumerable slots)) return null;
            var items = new JArray();
            foreach (object s in slots) items.Add(s is GemaMainMenuSelectionSlot slot && slot != null ? slot.GetText() : null);
            object cursor = owner.GetType().GetField("selected", Private)?.GetValue(owner);
            return new JObject { ["name"] = name, ["items"] = items, ["cursor"] = cursor is byte c ? (JToken)c : null };
        }

        // A conversation (ChatSystem): its status while not OFF, the section and line the game is on of how many, who
        // speaks (the row's character id), the whole line and how much of it has printed. Private fields, read by name.
        private static JObject Dialogue()
        {
            ChatSystem chat = ChatSystem.Instance;
            if (chat == null || chat.getStatus() == SystemVar.Status.OFF) return null;
            Type t = typeof(ChatSystem);
            int line = t.GetField("CurrentLine", Private)?.GetValue(chat) is int l ? l : -1;
            var rows = t.GetField("chatdb", Private)?.GetValue(chat) as IList;
            object row = rows != null && line >= 0 && line < rows.Count ? rows[line] : null;
            string full = t.GetField("TargetText", Private)?.GetValue(chat) as string;
            string shown = (t.GetField("text_prefer", Private)?.GetValue(chat) as TMPro.TextMeshPro)?.GetParsedText();
            return new JObject
            {
                ["status"] = chat.getStatus().ToString(),
                ["section"] = t.GetField("CurrentSection", Private)?.GetValue(chat) as string,
                ["line"] = line,
                ["lines"] = rows?.Count,
                ["speaker"] = row?.GetType().GetField("character")?.GetValue(row) as string,
                ["text"] = full,
                ["printed"] = shown?.Length,
                ["auto"] = t.GetField("autovoiceadvance", Private)?.GetValue(chat) is bool a && a,
            };
        }

        // The short instruction banner (ControlTips): its keyword (Tips.<name>), the text as drawn with the button pictures
        // taken out, and how far it has faded in. Returned while it is fading in or shown, not once it fades out.
        private static JObject Tip()
        {
            ControlTips tips = ControlTips.Instance;
            if (tips == null) return null;
            Type t = typeof(ControlTips);
            float target = t.GetField("targetalpha", Private)?.GetValue(tips) is float f ? f : 0f;
            var text = t.GetField("text", Private)?.GetValue(tips) as TMPro.TextMeshPro;
            float alpha = text != null ? text.color.a : 0f;
            if (target <= 0f) return null;
            // The keyword changes before the text does: while fading in (measured 2026-09-17: alpha 0.012 with the last tip's
            // text) the text is left out, and `shown` is false until the banner is half faded in.
            bool shown = alpha >= 0.5f;
            return new JObject
            {
                ["keyword"] = t.GetField("lastkeyword", Private)?.GetValue(tips) as string,
                ["text"] = shown ? text?.GetParsedText() : null,
                ["shown"] = shown,
                ["alpha_raw"] = Math.Round(alpha, 3),
            };
        }

        // Every text the game draws right now: each active TextMeshPro (world or UI) whose text is not empty and whose colour
        // is not faded out, with the object's name, top to bottom by screen position. What no reader above knows by name
        // (a tutorial window, a popup) still reaches the agent as words. At most 150 entries (a menu's list with its labels ran past 40) of 1500 characters (a tutorial
        // window's text ran past 400).
        private static JArray ScreenText()
        {
            var found = new List<KeyValuePair<float, JObject>>();
            Camera cam = Camera.main;
            foreach (TMPro.TMP_Text t in FindObjectsOfType<TMPro.TMP_Text>())
            {
                if (t == null || !t.isActiveAndEnabled || t.color.a <= 0.01f || t.alpha <= 0.01f) continue;
                string s = t.GetParsedText();
                if (string.IsNullOrEmpty(s) || s.Trim().Length == 0) continue;
                if (s.Length > 1500) s = s.Substring(0, 1500);
                float y = 0f;
                if (t is TMPro.TextMeshProUGUI) y = -t.transform.position.y;
                else if (cam != null) y = -cam.WorldToScreenPoint(t.transform.position).y;
                found.Add(new KeyValuePair<float, JObject>(y, new JObject { ["object"] = t.gameObject.name, ["text"] = s.Trim() }));
            }
            found.Sort((a, b) => a.Key.CompareTo(b.Key));
            var arr = new JArray();
            for (int i = 0; i < found.Count && i < 150; i++) arr.Add(found[i].Value);
            return arr;
        }

        // The bubble over the player's head that says Up does something here (EnterTips): `kind` by its sprite -- `enter` (a
        // door), `talk`, `action` -- while the game keeps it shown (it re-arms a short timer each frame the player is in range,
        // and fades once that runs out). The user, 2026-09-17: "there will be an icon above the player head, when you can use
        // the up arrow to interact with things".
        private static JObject Interact()
        {
            EnterTips tips = EnterTips.Instance;
            if (tips == null || !tips.isActiveAndEnabled) return null;
            Type t = typeof(EnterTips);
            float fadeout = t.GetField("fadeout", Private)?.GetValue(tips) is float f ? f : 0f;
            if (fadeout <= 0f) return null;
            Sprite shown = (t.GetField("sr", Private)?.GetValue(tips) as SpriteRenderer)?.sprite;
            string kind = "unknown";
            if (shown != null)
            {
                if (shown == t.GetField("entersprite", Private)?.GetValue(tips) as Sprite) kind = "enter";
                else if (shown == t.GetField("talksprite", Private)?.GetValue(tips) as Sprite) kind = "talk";
                else if (shown == t.GetField("actionsprite", Private)?.GetValue(tips) as Sprite) kind = "action";
            }
            return new JObject { ["kind"] = kind };
        }

        // The message that slides in at the bottom left (HUDPopupMessage): a new ability and how to use it, and the like. While its
        // timer runs, `title` and `text` are the whole message it is printing, with the game's markup taken out. The user,
        // 2026-09-17: "you got another ui popup, a new skill, along with a description at the bottom left of how to use it".
        private static readonly System.Text.RegularExpressions.Regex Markup = new System.Text.RegularExpressions.Regex("<[^>]*>");

        private static JObject Popup()
        {
            HUDPopupMessage hud = HUDPopupMessage.Instance;
            if (hud == null || !hud.isActiveAndEnabled) return null;
            Type t = typeof(HUDPopupMessage);
            float timer = t.GetField("timer", Private)?.GetValue(hud) is float f ? f : 0f;
            if (timer <= 0f) return null;
            string title = t.GetField("targetTitleText", Private)?.GetValue(hud) as string;
            string text = t.GetField("targetPopupText", Private)?.GetValue(hud) as string;
            if (string.IsNullOrEmpty(title) && string.IsNullOrEmpty(text)) return null;
            return new JObject
            {
                ["title"] = title == null ? null : Markup.Replace(title, "").Trim(),
                ["text"] = text == null ? null : Markup.Replace(text, "").Trim(),
                ["timer_raw"] = Math.Round(timer, 2),
            };
        }

        // The box that names an item just picked up (HUDObtainedItem), while it is up: the item's type and the name and
        // description drawn. Confirm closes it.
        private static JObject Obtained()
        {
            HUDObtainedItem hud = HUDObtainedItem.Instance;
            if (hud == null || !hud.isDisplaying()) return null;
            Type t = typeof(HUDObtainedItem);
            return new JObject
            {
                ["item"] = t.GetField("gotitem", Private)?.GetValue(hud)?.ToString(),
                ["name"] = (t.GetField("itemname", Private)?.GetValue(hud) as TMPro.TextMeshPro)?.GetParsedText(),
                ["description"] = (t.GetField("itemdesc", Private)?.GetValue(hud) as TMPro.TextMeshPro)?.GetParsedText(),
            };
        }

        private static readonly string[] DiffKeys = { "mode", "popup.title", "interact.kind", "tip.keyword", "obtained.item", "dialogue.section", "dialogue.line", "menu.name", "menu.cursor", "menu.slot", "menu.question", "menu.entering", "location.area", "location.area_id", "location.room_x", "location.room_y", "location.x", "location.y", "location.facing", "player.anim", "player.hp" };

        private static JObject Changed(JObject before, JObject after)
        {
            var out_ = new JObject();
            foreach (string k in DiffKeys)
            {
                JToken a = before.SelectToken(k), b = after.SelectToken(k);
                if (!JToken.DeepEquals(a, b)) out_[k] = new JObject { ["from"] = a, ["to"] = b };
            }
            return out_;
        }

        // ---- the frame loop --------------------------------------------------------------------------------------

        private void Update()
        {
            try
            {
                Recorder.Record(Player(), Mode());
            }
            catch (Exception)
            {
                // a frame between scenes: nothing to record
            }
            if (link == null) return;
            foreach (string line in link.DrainLogs()) Log(line);
            foreach (string line in SaveGuard.DrainLog()) Log(line);

            if (link.Connected && !welcomedOnce)
            {
                welcomedOnce = true;
                if (!SaveGuard.Armed)
                {
                    try
                    {
                        Log(SaveGuard.Arm());
                    }
                    catch (Exception e)
                    {
                        // Unguarded, nothing may be carried out: drop the core and stay off until a reload.
                        Log("SAVE GUARD FAILED TO ARM (" + e.Message + "); the driver disconnects and stays off");
                        link.Dispose();
                        link = null;
                        return;
                    }
                }
            }
            if (Time.frameCount % 30 == 0) link.SetHello(Hello());

            InputInjection.MuteReal = SaveGuard.Armed && !Application.isFocused; // armed: a core has connected since the game started
            InputInjection.Expire();
            SendEvents();

            foreach (Link.Request req in link.Poll()) waiting.Enqueue(req);
            if (current != null && current.Generation != link.Generation)
            {
                Log("dropping " + current.Type + " " + current.Id + ": its core has gone");
                current = null;
                currentTick = null;
            }
            if (current == null && waiting.Count > 0)
            {
                Begin(waiting.Dequeue());
            }
            if (current != null) TickCurrent();
            Clock.LetInputRun(current != null && Array.IndexOf(InputVerbs, current.Type) >= 0);
        }

        // The requests that carry input: while the clock is held, these run game time for their own frames (Clock.cs).
        private static readonly string[] InputVerbs = { "press", "sequence", "reflex", "advance_text" };

        private void SendEvents()
        {
            List<JObject> hits = Events.Drain(); // a hit while no core is connected is dropped, never sent to the next one
            if (!link.Connected)
            {
                Events.Unprime();
                return;
            }
            foreach (JObject e in hits) Emit(e);
            Events.Poll(Player(), Dialogue(), SaveMenu() ?? TitleMenu(), Tip(), Obtained(), Interact(), Popup());
            foreach (JObject e in Events.Drain()) Emit(e);
            string mode = Mode();
            WorldManager wm = WorldManager.Instance;
            string area = wm != null ? wm.CurrentRoomArea.ToString() : null;
            string room = wm != null ? wm.CurrentRoomX + "," + wm.CurrentRoomY : null;
            if (lastMode != null && mode != lastMode) Emit(new JObject { ["kind"] = "mode_changed", ["from"] = lastMode, ["to"] = mode, ["frame"] = Time.frameCount });
            if (lastArea != null && area != null && area != lastArea) Emit(new JObject { ["kind"] = "area_changed", ["from"] = lastArea, ["to"] = area, ["frame"] = Time.frameCount });
            if (lastRoom != null && room != null && room != lastRoom) Emit(new JObject { ["kind"] = "room_changed", ["from"] = lastRoom, ["to"] = room, ["frame"] = Time.frameCount });
            lastMode = mode;
            if (area != null) lastArea = area;
            if (room != null) lastRoom = room;
        }

        // Every event goes out through here, and a running sequence sees each one first (its stop_on).
        private Action<JObject> eventWatch;

        private void Emit(JObject e)
        {
            eventWatch?.Invoke(e);
            link.Event(e);
        }

        private void Begin(Link.Request req)
        {
            string verb = req.Type;
            string capability = verb == "cheat" || verb == "reflex" ? verb + ":" + (string)req.Payload["kind"]
                : verb == "screenshot" && (bool?)req.Payload["annotate"] == true ? "screenshot:annotate" : verb;
            if (Array.IndexOf(Capabilities, capability) < 0)
            {
                link.Fail(req, "this driver does not support " + capability);
                return;
            }
            current = req;
            try
            {
                switch (verb)
                {
                    case "observe":
                        Finish(Observe(true));
                        return;
                    case "wait":
                        currentTick = WaitJob(req.Payload);
                        break;
                    case "press":
                        currentTick = PressJob(req.Payload);
                        break;
                    case "sequence":
                        currentTick = SequenceJob(req.Payload);
                        break;
                    case "advance_text":
                        currentTick = AdvanceTextJob();
                        break;
                    case "recent":
                        Finish(Recorder.Read((int?)req.Payload["frames"] ?? 120, Math.Max(1, (int?)req.Payload["every"] ?? 1), (int?)req.Payload["until_frame"]));
                        return;
                    case "clock":
                        currentTick = Clock.Job(req.Payload, Observe);
                        break;
                    case "reflex":
                        // The capability check above refuses a kind not listed.
                        string kind = (string)req.Payload["kind"];
                        JObject rargs = req.Payload["args"] as JObject ?? new JObject();
                        int rframes = (int?)req.Payload["frames"] ?? 600;
                        currentTick = kind == "evade" ? Reflexes.Evade(rargs, rframes, Player, Mode, Observe) : Reflexes.Fight(rargs, rframes, Player, Mode, Observe);
                        Log("reflex " + kind);
                        break;
                    case "screenshot":
                        currentTick = ScreenshotJob(req.Payload);
                        break;
                    case "snapshot":
                        Finish(Snapshot(req.Payload));
                        return;
                    case "restore":
                        currentTick = RestoreJob(req.Payload);
                        break;
                    case "cheat":
                        currentTick = TeleportJob(req.Payload["args"] as JObject ?? new JObject());
                        break;
                }
            }
            catch (Exception e)
            {
                FailCurrent(e.Message);
            }
        }

        private void TickCurrent()
        {
            try
            {
                JToken answer = currentTick();
                if (answer != null) Finish(answer);
            }
            catch (Exception e)
            {
                FailCurrent(e.Message);
            }
        }

        private void Finish(JToken answer)
        {
            eventWatch = null;
            link.Reply(current, answer);
            current = null;
            currentTick = null;
        }

        private void FailCurrent(string message)
        {
            eventWatch = null;
            Log(current.Type + " failed: " + message);
            link.Fail(current, message);
            current = null;
            currentTick = null;
        }

        // ---- verbs -----------------------------------------------------------------------------------------------

        private Func<JToken> WaitJob(JObject p)
        {
            int frames = (int?)p["frames"] ?? 0;
            if (frames < 1) throw new Exception("wait needs frames");
            JObject before = Observe(false);
            int until = Time.frameCount + frames;
            return () =>
            {
                if (Time.frameCount < until) return null;
                JObject after = Observe(false);
                return new JObject { ["frames"] = frames, ["before"] = before, ["after"] = after, ["changed"] = Changed(before, after) };
            };
        }

        private Func<JToken> PressJob(JObject p)
        {
            int frames = (int?)p["frames"] ?? 0;
            var buttons = new List<string>();
            foreach (JToken b in p["buttons"] as JArray ?? new JArray()) buttons.Add((string)b);
            if (frames < 1 || buttons.Count == 0) throw new Exception("press needs buttons and frames");
            JObject before = Observe(false);
            string err = InputInjection.Schedule(buttons, frames, out int done);
            if (err != null) throw new Exception(err);
            Log("press " + string.Join("+", buttons.ToArray()) + " for " + frames + " frames");
            return () =>
            {
                if (Time.frameCount < done) return null;
                JObject after = Observe(false);
                return new JObject { ["frames"] = frames, ["buttons"] = new JArray(buttons.ToArray()), ["before"] = before, ["after"] = after, ["changed"] = Changed(before, after) };
            };
        }

        // SEQUENCE {steps: [{buttons, from, frames}], stop_on}: every hold scheduled at once from the next frame, so they
        // overlap exactly as asked; the first event whose kind is in stop_on cuts what is held (let go on the next frame)
        // and drops what has not begun, and the answer waits a frame for that release.
        private Func<JToken> SequenceJob(JObject p)
        {
            var steps = new List<KeyValuePair<IList<string>, KeyValuePair<int, int>>>();
            foreach (JToken st in p["steps"] as JArray ?? new JArray())
            {
                var buttons = new List<string>();
                foreach (JToken b in st["buttons"] as JArray ?? new JArray()) buttons.Add((string)b);
                int from = (int?)st["from"] ?? 0, frames = (int?)st["frames"] ?? 0;
                if (buttons.Count == 0 || frames < 1 || from < 0) throw new Exception("each step needs buttons, from and frames");
                steps.Add(new KeyValuePair<IList<string>, KeyValuePair<int, int>>(buttons, new KeyValuePair<int, int>(from, frames)));
            }
            if (steps.Count == 0) throw new Exception("sequence needs steps");
            var stopOn = new HashSet<string>();
            foreach (JToken k in p["stop_on"] as JArray ?? new JArray()) stopOn.Add((string)k);
            JObject before = Observe(false);
            string err = InputInjection.ScheduleSequence(steps, out int done);
            if (err != null) throw new Exception(err);
            int start = Time.frameCount + 1;
            JObject stoppedBy = null;
            int stopFrame = -1;
            if (stopOn.Count > 0)
            {
                eventWatch = e =>
                {
                    if (stoppedBy == null && stopOn.Contains((string)e["kind"] ?? "")) stoppedBy = e;
                };
            }
            Log("sequence of " + steps.Count + " steps over " + (done - start - 1) + " frames" + (stopOn.Count > 0 ? ", stop on " + string.Join(",", new List<string>(stopOn).ToArray()) : ""));
            return () =>
            {
                if (stoppedBy != null && stopFrame < 0)
                {
                    InputInjection.CutShort();
                    stopFrame = Time.frameCount;
                }
                if (stopFrame >= 0 ? Time.frameCount < stopFrame + 2 : Time.frameCount < done) return null;
                JObject after = Observe(false);
                var answer = new JObject
                {
                    ["frames_run"] = (stopFrame >= 0 ? stopFrame : done - 1) - start,
                    ["before"] = before,
                    ["after"] = after,
                    ["changed"] = Changed(before, after),
                };
                if (stoppedBy != null) answer["stopped_by"] = stoppedBy;
                return answer;
            };
        }

        // ADVANCE_TEXT: through a conversation line by line, the way a player reads it. While a line is up, Confirm is tapped
        // once it has stood TapEvery frames with no change (the first tap on a line still printing finishes it, the next moves
        // on); each new line goes into the log, and the item box is logged and confirmed the same way. Ends `closed` once no
        // conversation has been open for SettleFrames and the game is not paused, `window_open` when paused with no conversation (a
        // tutorial window: its words are in observe's screen_text), or `stuck` after StuckTaps taps with no change.
        private const int TapEvery = 30, SettleFrames = 90, StuckTaps = 6, AdvanceFrameLimit = 3 * 60 * 60;

        private Func<JToken> AdvanceTextJob()
        {
            var log = new JArray();
            int start = Time.frameCount, lastChange = start, taps = 0;
            string lastKey = null;
            JObject entry = null; // the line being read: its text is filled while it is up, since the game's text changes after the line number
            JObject Done(string outcome, JObject extra = null)
            {
                var o = new JObject { ["outcome"] = outcome, ["frames"] = Time.frameCount - start, ["log"] = log, ["after"] = Observe(false) };
                if (extra != null) o.Merge(extra);
                return o;
            }
            Log("advance_text");
            return () =>
            {
                int f = Time.frameCount;
                if (f - start > AdvanceFrameLimit) return Done("stuck", new JObject { ["reason"] = "the frame limit" });
                if (InputInjection.Busy) return null;
                JObject d = Dialogue();
                JObject box = d == null ? Obtained() : null;
                if (d != null || box != null)
                {
                    string key = d != null ? (string)d["section"] + "#" + (int?)d["line"] : "item#" + (string)box["item"];
                    if (key != lastKey)
                    {
                        lastKey = key;
                        lastChange = f;
                        taps = 0;
                        entry = null;
                        if (box != null) log.Add(new JObject { ["obtained"] = box });
                        else if ((int?)d["line"] < (int?)d["lines"])
                        {
                            entry = new JObject { ["section"] = d["section"], ["line"] = d["line"] };
                            log.Add(entry);
                        }
                        return null;
                    }
                    if (entry != null)
                    {
                        entry["speaker"] = d["speaker"];
                        entry["text"] = d["text"];
                    }
                    if (f - lastChange < TapEvery * (taps + 1)) return null;
                    if (taps >= StuckTaps) return Done("stuck", new JObject { ["reason"] = "the line did not change after " + taps + " taps", ["dialogue"] = d, ["obtained"] = box });
                    string err = InputInjection.Schedule(new[] { "Confirm" }, 3, out int _);
                    if (err != null) return Done("stuck", new JObject { ["reason"] = err });
                    taps++;
                    return null;
                }
                if (lastKey != null)
                {
                    lastKey = null;
                    lastChange = f;
                }
                if (f - lastChange < SettleFrames) return null;
                string mode = Mode();
                if (mode == "paused") return Done("window_open", new JObject { ["screen_text"] = ScreenText() });
                if (mode == "play" || mode == "title") return Done(log.Count > 0 ? "closed" : "no_text");
                return null; // an event still running: a scene between lines
            };
        }

        // ---- snapshots: the game's own save and load, through autoplay's slot in the save guard's shadow ----------------

        // The file the game uses for a slot, where Easy Save resolves it now: in the shadow while the guard is armed. Only
        // a path inside the shadow is returned; anything else is refused, so a snapshot never reads or writes a real save.
        private string ShadowSlotFile(byte slot)
        {
            string shadow = SaveGuard.ShadowRoot;
            if (!SaveGuard.Armed || shadow == null) throw new Exception("the save guard is not shadowing the save folder, so no slot file is touched");
            MethodInfo name = typeof(SaveManager).GetMethod("GetSaveFileName", Private);
            if (name == null || SaveManager.Instance == null) throw new Exception("SaveManager.GetSaveFileName is not there to name the slot's file");
            string file = new ES3Settings((string)name.Invoke(SaveManager.Instance, new object[] { slot })).FullPath.Replace('\\', '/');
            if (!file.StartsWith(shadow + "/", StringComparison.OrdinalIgnoreCase)) throw new Exception("slot " + slot + " resolves to " + file + ", outside the shadow; refusing");
            return file;
        }

        // A snapshot's own file, which the core names: only under this repo's autoplay/states/<game>/.
        private string StatePath(JObject p)
        {
            string path = ((string)p["path"] ?? "").Replace('\\', '/');
            string states = repo + "/autoplay/states/" + GameName + "/";
            if (repo == null || !path.StartsWith(states, StringComparison.OrdinalIgnoreCase) || path.Contains("..") || path.Substring(states.Length).Contains("/"))
            {
                throw new Exception("a snapshot path must be a file directly in " + states + ", got " + path);
            }
            return path;
        }

        // SNAPSHOT {path}: the game saves to autoplay's slot exactly as its save menu does (SaveManager.SaveGame with the
        // slot set; it keeps the area and the player's x and y), and that file is copied to the core's path.
        private JToken Snapshot(JObject p)
        {
            string path = StatePath(p);
            string mode = Mode();
            if (mode != "play") throw new Exception("a snapshot is taken in play, not in " + mode);
            string slotFile = ShadowSlotFile(WorkingSlot);
            MainVar.instance._saveslot = WorkingSlot;
            SaveManager.Instance.savedata.isAutoSave = false;
            SaveManager.Instance.SaveGame();
            if (!File.Exists(slotFile)) throw new Exception("the game saved, but " + slotFile + " is not there");
            File.Copy(slotFile, path, overwrite: true);
            File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
            Log("snapshot: slot " + WorkingSlot + " saved and copied to " + path);
            return new JObject { ["slot"] = WorkingSlot, ["slot_file"] = slotFile, ["bytes"] = new FileInfo(path).Length, ["frame"] = Time.frameCount, ["at"] = Observe(false) };
        }

        // RESTORE {path}: the file goes back into autoplay's slot, the recent-slot pointer is set to it the way the save
        // menu's load sets it, and the game reloads (SaveManager.ReloadToGame, what that menu calls once its fade is out).
        // Answers once a new world has loaded and play has resumed, or fails after RestoreFrameLimit frames.
        private const int RestoreFrameLimit = 1800;

        private Func<JToken> RestoreJob(JObject p)
        {
            string path = StatePath(p);
            if (!File.Exists(path)) throw new Exception("no snapshot file at " + path);
            if (SaveManager.Instance == null || SettingManager.Instance == null) throw new Exception("the game's save and setting managers are not loaded");
            string slotFile = ShadowSlotFile(WorkingSlot);
            File.Copy(path, slotFile, overwrite: true);
            MainVar.instance._saveslot = WorkingSlot;
            MainVar.instance._isAutoSave = false;
            SettingManager.Instance.SaveSystemRecentSlot(recentMSave: false);
            SettingManager.Instance.SaveSystemRecentSlot(recentMSave: true);
            WorldManager before = WorldManager.Instance;
            int start = Time.frameCount;
            SaveManager.Instance.ReloadToGame();
            Log("restore: " + path + " copied to slot " + WorkingSlot + ", reloading");
            int settledAt = -1;
            return () =>
            {
                int frames = Time.frameCount - start;
                if (frames > RestoreFrameLimit) throw new Exception("the game had not resumed play " + RestoreFrameLimit + " frames after the reload (mode " + Mode() + ")");
                WorldManager wm = WorldManager.Instance;
                CharacterBase pl = Player();
                // Play resumes before the area and the camera are set (measured 2026-09-17: 10 frames after `play` the area
                // read NONE and the camera's view was far from the player), so both are waited for too.
                // And the fade-in: play resumed at alpha 0.49, which fell to 0 about 132 frames later, and a teleport made
                // while it was above 0 did not hold, while one made at 0 did (measured 2026-09-17).
                bool loaded = wm != null && wm != before && wm.MapInited && (Mode() == "play" || Mode() == "event")
                    && wm.CurrentRoomArea != Map.AreaType.NONE && pl != null && pl.t != null && !Utility.isOutsideCamera(pl.t.position, 0f)
                    && FadeManager.Instance != null && FadeManager.Instance.GetCurrentAlpha() <= 0.001f;
                if (!loaded) { settledAt = -1; return null; }
                if (settledAt < 0) settledAt = Time.frameCount;
                if (Time.frameCount - settledAt < 10) return null;
                return new JObject { ["slot"] = WorkingSlot, ["frames"] = frames, ["after"] = Observe(false) };
            };
        }

        // CHEAT teleport {x, y}: the player's transform to world x, y (as observe's location reads them), the velocity
        // zeroed; answers 10 frames later with where the game has the player then, read back, not the values written.
        private Func<JToken> TeleportJob(JObject args)
        {
            if (args["x"] == null || args["y"] == null) throw new Exception("teleport needs x and y, world units as observe's location reads them");
            float x = (float)args["x"], y = (float)args["y"];
            string mode = Mode();
            if (mode != "play") throw new Exception("a teleport is made in play, not in " + mode);
            CharacterBase pl = Player();
            JObject before = Observe(false);
            pl.t.position = new Vector3(x, y, pl.t.position.z);
            if (pl.phy_perfer != null) pl.phy_perfer._velocity = Vector3.zero;
            int until = Time.frameCount + 10;
            Log("cheat teleport to " + x + "," + y);
            return () =>
            {
                if (Time.frameCount < until) return null;
                JObject after = Observe(false);
                // Held: the position the game has 10 frames on is the one asked for (within a unit). One made 11 frames after a
                // restore answered did not hold (measured 2026-09-17), so this is said, never assumed.
                CharacterBase now = Player();
                bool held = now != null && now.t != null && Mathf.Abs(now.t.position.x - x) < 1f && Mathf.Abs(now.t.position.y - y) < 1f;
                return new JObject { ["requested"] = new JObject { ["x"] = x, ["y"] = y }, ["held"] = held, ["before"] = before, ["after"] = after, ["changed"] = Changed(before, after) };
            };
        }

        private Func<JToken> ScreenshotJob(JObject p)
        {
            if (repo == null) throw new Exception("no repo in meshghost-autoplay.txt, so there is no shots folder");
            string name = (string)p["name"] ?? "";
            if (name.Length == 0 || name.Length > 64 || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || name.Contains(".") || name.Contains(" "))
            {
                throw new Exception("a screenshot name is letters, digits, _ or -");
            }
            string dir = repo + "/dev-scripts/shots/" + GameName;
            Directory.CreateDirectory(dir);
            string path = dir + "/autoplay_" + name + ".png";
            string error = null;
            JObject answer = null;
            bool annotate = (bool?)p["annotate"] == true;
            StartCoroutine(Annotate.Capture(path, annotate, Player, (a, e) => { answer = a; error = e; }));
            return () =>
            {
                if (error != null) throw new Exception(error);
                return answer;
            };
        }
    }
}
