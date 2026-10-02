using System;
using System.IO;
using System.Reflection;
using BepInEx;
using UnityEngine;

namespace MeshGhostTeviDevCheats
{
    // Dev-only cheats for a test session, never staged: this writes game state every frame, which the adapter may never
    // do, so it lives in its own assembly. It holds HP, both orbs' MP, the charge bank and both crystal counts at max.
    // meshghost-devcheats.txt turns one off with name=0, re-read once a second; no file, or a name not in it, means on.
    // It is read from beside this DLL, or from the game's root folder under ScriptEngine, where Info.Location is empty.
    [BepInPlugin("dev.meshghost.tevi.devcheats", "MeshGhost Dev Cheats", "0.1.0")]
    public class Plugin : BaseUnityPlugin
    {
        private static readonly PropertyInfo MainCharacterProperty = typeof(EventManager).GetProperty("mainCharacter");
        private static readonly FieldInfo MainCharacterField = typeof(EventManager).GetField("mainCharacter");
        private static readonly FieldInfo OrbMpField = typeof(OrbBall).GetField("MP", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbMaxMpField = typeof(OrbBall).GetField("MaxMP", BindingFlags.NonPublic | BindingFlags.Instance);

        private bool hp = true, mp = true, charge = true, crystal = true, swap = true;
        private float lastToggleRead = float.NegativeInfinity;
        private string togglePath;

        private void Awake()
        {
            togglePath = Path.Combine(Path.GetDirectoryName(Info.Location) ?? ".", "meshghost-devcheats.txt");
            Logger.LogWarning("MeshGhost DevCheats loaded -- DEV ONLY, writes HP/MP/charge every frame. "
                + $"Toggle file: {togglePath} (hp=, mp=, charge=, crystal=, swap=; absent means on). Crystals are SAVE data.");
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
            bool nhp = true, nmp = true, ncharge = true, ncrystal = true, nswap = true;
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
                        else if (key == "swap") nswap = on;
                    }
                }
            }
            catch (Exception e)
            {
                Logger.LogWarning($"MeshGhost DevCheats: toggle file unreadable ({e.Message}); keeping last values.");
                return;
            }
            if (nhp != hp || nmp != mp || ncharge != charge || ncrystal != crystal || nswap != swap)
            {
                Logger.LogInfo($"MeshGhost DevCheats: hp={nhp} mp={nmp} charge={ncharge} crystal={ncrystal} swap={nswap}");
            }
            hp = nhp; mp = nmp; charge = ncharge; crystal = ncrystal; swap = nswap;
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
                // Through SetHealthInt, so the game's own clamp applies.
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
                // GetMaxAllowedCharge is in bar units, and a banked unit counts as 100 of them.
                int allowed = SaveManager.Instance.GetMaxAllowedCharge();
                int units = Mathf.Max(0, allowed / 100);
                if (units > 255) units = 255;
                if (phy.chargeheld < units)
                {
                    // Through SetChargeHeld, so the bar recolours.
                    phy.SetChargeHeld((byte)units);
                }
                // The bar held just under full: a full bar turns into a banked unit, and the bank is already full.
                float bar = phy.maxcharge - 1f;
                if (phy.charge < bar)
                {
                    phy.charge = bar;
                }
            }

            // The orb swap's two locks, cleared every frame. Its refusals during a core expansion stay: they are the
            // boost state machine itself, and forcing them breaks the return-to-orb sequence.
            if (swap && player.cphy_perfer != null)
            {
                if (player.cphy_perfer.BadgeCD_ChangeOrbCharger > 0f) player.cphy_perfer.BadgeCD_ChangeOrbCharger = 0f;
                if (player.cphy_perfer.NoOrbChange) player.cphy_perfer.NoOrbChange = false;
            }

            // Crystals are save data, not a bar: a save written while this is on keeps the maxed count.
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
