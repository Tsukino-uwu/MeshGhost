using System;
using System.IO;
using System.Reflection;
using BepInEx;
using UnityEngine;

namespace MeshGhostTeviDevCheats
{
    // DEV-ONLY CHEATS FOR A TEST SESSION. Asked for by the user 2026-09-10 ("infinite energy, hp,
    // meter, charge, bars etc for dev"). This writes game state every frame, which the shipped
    // adapter may never do (CLAUDE.md), so it lives in its own assembly that is never staged.
    //
    // What it holds full, and where each value lives (names from the assembly, see
    // agent_docs/licensing.md's facts-not-code posture):
    //   hp      CharacterBase.health / maxhealth, written through SetHealthInt so the game's own
    //           clamp applies.
    //   mp      OrbBall.MP / MaxMP -- the energy each orbitar spends on shots. Private fields.
    //   charge  CharacterPhy.charge (the bar) and chargeheld (the banked units the HUD wheel
    //           counts), the latter set through SetChargeHeld so the bar recolours.
    //
    // TOGGLE FILE, so a test can switch one cheat off without a rebuild (hot reload is the loop):
    // `meshghost-devcheats.txt` beside this DLL, one `name=0|1` per line. No file, or a name not
    // in it, means ON -- the DLL being present is the master switch. Re-read once a second.
    [BepInPlugin("dev.meshghost.tevi.devcheats", "MeshGhost Dev Cheats", "0.1.0")]
    public class Plugin : BaseUnityPlugin
    {
        private static readonly PropertyInfo MainCharacterProperty = typeof(EventManager).GetProperty("mainCharacter");
        private static readonly FieldInfo MainCharacterField = typeof(EventManager).GetField("mainCharacter");
        private static readonly FieldInfo OrbMpField = typeof(OrbBall).GetField("MP", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbMaxMpField = typeof(OrbBall).GetField("MaxMP", BindingFlags.NonPublic | BindingFlags.Instance);

        private bool hp = true, mp = true, charge = true, crystal = true;
        private float lastToggleRead = float.NegativeInfinity;
        private string togglePath;

        private void Awake()
        {
            togglePath = Path.Combine(Path.GetDirectoryName(Info.Location) ?? ".", "meshghost-devcheats.txt");
            Logger.LogWarning("MeshGhost DevCheats loaded -- DEV ONLY, writes HP/MP/charge every frame. "
                + $"Toggle file: {togglePath} (hp=, mp=, charge=, crystal=; absent means on). Crystals are SAVE data.");
        }

        private static CharacterBase GetMainCharacter(EventManager em)
        {
            if (MainCharacterProperty != null) return (CharacterBase)MainCharacterProperty.GetValue(em);
            if (MainCharacterField != null) return (CharacterBase)MainCharacterField.GetValue(em);
            return null;
        }

        private void ReadToggles()
        {
            if (Time.unscaledTime - lastToggleRead < 1f) return;
            lastToggleRead = Time.unscaledTime;
            bool nhp = true, nmp = true, ncharge = true, ncrystal = true;
            try
            {
                if (File.Exists(togglePath))
                {
                    foreach (string raw in File.ReadAllLines(togglePath))
                    {
                        string line = raw.Trim();
                        int eq = line.IndexOf('=');
                        if (eq <= 0) continue;
                        string key = line.Substring(0, eq).Trim().ToLowerInvariant();
                        bool on = line.Substring(eq + 1).Trim() != "0";
                        if (key == "hp") nhp = on;
                        else if (key == "mp") nmp = on;
                        else if (key == "charge") ncharge = on;
                        else if (key == "crystal") ncrystal = on;
                    }
                }
            }
            catch (Exception e)
            {
                Logger.LogWarning($"MeshGhost DevCheats: toggle file unreadable ({e.Message}); keeping last values.");
                return;
            }
            if (nhp != hp || nmp != mp || ncharge != charge || ncrystal != crystal)
            {
                Logger.LogInfo($"MeshGhost DevCheats: hp={nhp} mp={nmp} charge={ncharge} crystal={ncrystal}");
            }
            hp = nhp; mp = nmp; charge = ncharge; crystal = ncrystal;
        }

        private void Update()
        {
            ReadToggles();
            EventManager em = EventManager.Instance;
            if (em == null) return;
            CharacterBase player = GetMainCharacter(em);
            if (player == null || player.t == null) return;

            if (hp && player.health < player.maxhealth)
            {
                player.SetHealthInt(player.maxhealth, addrec: false);
            }

            if (mp && player.playerc_perfer != null && player.playerc_perfer.orb != null
                && OrbMpField != null && OrbMaxMpField != null)
            {
                foreach (OrbBall orb in player.playerc_perfer.orb)
                {
                    if (orb == null) continue;
                    float max = (float)OrbMaxMpField.GetValue(orb);
                    if ((float)OrbMpField.GetValue(orb) < max)
                    {
                        OrbMpField.SetValue(orb, max);
                    }
                }
            }

            if (charge && player.cphy_perfer != null && SaveManager.Instance != null)
            {
                CharacterPhy phy = player.cphy_perfer;
                // GetMaxAllowedCharge is the bar-plus-banked ceiling in bar units (AddCharge
                // compares charge + chargeheld*100 against it), so the banked units are that / 100.
                int allowed = SaveManager.Instance.GetMaxAllowedCharge();
                int units = Mathf.Max(0, allowed / 100);
                if (units > 255) units = 255;
                if (phy.chargeheld < units)
                {
                    phy.SetChargeHeld((byte)units);
                }
                // The bar itself, held just under full: AddCharge converts a full bar into a
                // banked unit, and the units are already at the ceiling above.
                float bar = phy.maxcharge - 1f;
                if (phy.charge < bar)
                {
                    phy.charge = bar;
                }
            }

            // CRYSTALS -- what a core expansion spends (user, 2026-09-10). SAVE DATA, not a
            // transient bar: SaveManager.savedata.crystal[] is what an autosave writes to disk, so
            // a save touched while this is on keeps the maxed count. Dev install only, by design.
            if (crystal && SaveManager.Instance != null)
            {
                short max = SaveManager.Instance.GetMaxCrystal();
                for (int i = 0; i < 2; i++)
                {
                    Character.OrbType ot = (Character.OrbType)i;
                    if (SaveManager.Instance.GetCrystal(ot) < max)
                    {
                        SaveManager.Instance.SetCrystal(ot, max);
                    }
                }
            }
        }
    }
}
