using System;
using HarmonyLib;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace MeshGhostAutoplay.Tevi
{
    // CLOCK (the plan's layer 3; agent_docs/phases/phase13.md, "how an agent sees a game"): the game's time held while the model
    // decides. TEVI sets Time.timeScale itself every frame in GameSystem.TimeScale (0 while paused or in its own short stops, the
    // game speed otherwise; names read from the Steam build's assemblies, 2026-09-17), so a value written from outside lasts one
    // frame. A postfix on that method sets 0 after the game has, while held; a step lets the game's own value stand for that many
    // of its calls, then holds again. What a timeScale of 0 does and does not freeze in TEVI is in adapters/tevi/MEASURED.md.
    //
    // The hold survives a core going away (mcpcall starts a core per call, and a hold that ended with each call would hold nothing)
    // and a hot reload: the patch goes with the plugin, but whether the clock is held is kept in the AppDomain's data, which the next
    // copy reads as it installs (a reload that let go of the clock in the middle of a boss fight let the boss act, 2026-09-17).
    //
    // FAST: the game run faster than real time with every frame still one frame of game time. Time.captureDeltaTime makes Time.time
    // advance by it each frame "regardless of real time and the duration of a frame", scaled by timeScale, and targetFrameRate -1 renders
    // "as fast as possible" on desktop while vSyncCount is 0 (Unity 2021.3's scripting reference, Time.captureDeltaTime and
    // Application.targetFrameRate; TEVI is 2021.3.25f1 and its log sets VSYNC 0, FPS limit 60, expected delta 0.01666667). Set every frame
    // in the same postfix, since the game's own settings may set the frame rate again; off puts back the frame rate it found. Whether a
    // fast frame is the same frame as a real-time one is measured, not assumed (adapters/tevi/MEASURED.md).
    public static class Clock
    {
        public const string HarmonyId = "dev.meshghost.autoplay.clock";
        private const string KeyFast = "meshghost.autoplay.clock.fast";
        public static bool Fast
        {
            get => AppDomain.CurrentDomain.GetData(KeyFast) is bool b && b;
            private set => AppDomain.CurrentDomain.SetData(KeyFast, value);
        }
        private const string KeyFoundRate = "meshghost.autoplay.clock.found_rate";
        private static float rateSince = -1f;
        private static int rateFrames;
        private static double measuredFps;

        private static Harmony harmony;
        private const string KeyHeld = "meshghost.autoplay.clock.held";
        public static bool Held
        {
            get => AppDomain.CurrentDomain.GetData(KeyHeld) is bool b && b;
            private set => AppDomain.CurrentDomain.SetData(KeyHeld, value);
        }
        private static int stepLeft;
        private static int stepped; // game-time frames let pass by the last step

        // While held, a request that carries input (press, sequence, reflex, advance_text) runs game time for exactly its own
        // frames, as a frame advance with input does: the plugin says so each frame, and the next frame runs.
        private static bool letRun;

        public static void LetInputRun(bool running)
        {
            if (!Held) { letRun = false; return; }
            if (running && !letRun)
            {
                // The game's own call has already run this frame and set 0: the next frame must run.
                Time.timeScale = MainVar.instance != null ? MainVar.instance.GetGameSpeed() : 1f;
            }
            else if (!running && letRun)
            {
                Time.timeScale = 0f;
            }
            letRun = running;
        }

        public static void Install()
        {
            if (harmony != null) return;
            harmony = new Harmony(HarmonyId);
            harmony.Patch(AccessTools.Method(typeof(GameSystem), "TimeScale"), postfix: new HarmonyMethod(typeof(Clock), nameof(TimeScalePostfix)));
            if (Held) Time.timeScale = 0f; // held before the reload: still held
        }

        public static void Uninstall()
        {
            harmony?.UnpatchSelf();
            harmony = null;
            stepLeft = 0; // Held stays as it is for the next copy
        }

        private static void TimeScalePostfix()
        {
            if (Fast)
            {
                Time.captureDeltaTime = 1f / 60f;
                Application.targetFrameRate = -1;
            }
            // Frames a real second, for the answer's `fps`.
            float now = Time.realtimeSinceStartup;
            if (rateSince < 0f) rateSince = now;
            rateFrames++;
            if (now - rateSince >= 1f)
            {
                measuredFps = rateFrames / (now - rateSince);
                rateSince = now;
                rateFrames = 0;
            }
            if (!Held || letRun) return;
            if (stepLeft > 0)
            {
                stepLeft--;
                stepped++;
                return;
            }
            Time.timeScale = 0f;
        }

        public static JObject Report()
        {
            return new JObject { ["held"] = Held, ["step_left"] = stepLeft, ["time_scale_raw"] = Math.Round(Time.timeScale, 3), ["fast"] = Fast, ["fps"] = Math.Round(measuredFps, 1), ["target_frame_rate_raw"] = Application.targetFrameRate, ["capture_delta_raw"] = Math.Round(Time.captureDeltaTime, 5) };
        }

        // CLOCK {action, frames}: hold and release answer at once; step answers once its frames have passed and it holds again.
        public static Func<JToken> Job(JObject p, Func<bool, JObject> observe)
        {
            string action = (string)p["action"] ?? "";
            int start = Time.frameCount;
            switch (action)
            {
                case "hold":
                    Held = true;
                    stepLeft = 0;
                    // The game's own TimeScale call has already run this frame (measured 2026-09-17: a hold that waited for the
                    // postfix let one more frame of game time pass), so the next frame is stopped here.
                    Time.timeScale = 0f;
                    return () => Time.frameCount > start ? Answer(action, start, observe) : null;
                case "release":
                    Held = false;
                    stepLeft = 0;
                    return () => Answer(action, start, observe);
                case "step":
                    int frames = (int?)p["frames"] ?? 0;
                    if (frames < 1) throw new Exception("step needs frames");
                    Held = true;
                    stepped = 0;
                    stepLeft = frames;
                    int done = -1;
                    return () =>
                    {
                        if (stepLeft > 0) return null;
                        if (done < 0) done = Time.frameCount;
                        // The last stepped frame runs after the count reaches 0: answer once it has.
                        return Time.frameCount > done ? Answer(action, start, observe) : null;
                    };
                case "fast":
                    bool on = (bool?)p["on"] ?? throw new Exception("fast needs on");
                    if (on && !Fast) AppDomain.CurrentDomain.SetData(KeyFoundRate, Application.targetFrameRate);
                    if (!on && Fast)
                    {
                        Time.captureDeltaTime = 0f;
                        Application.targetFrameRate = AppDomain.CurrentDomain.GetData(KeyFoundRate) is int r ? r : 60;
                    }
                    Fast = on;
                    return () => Time.frameCount > start ? Answer(action, start, observe) : null;
                default:
                    throw new Exception("clock action must be hold, step, release or fast");
            }
        }

        private static JObject Answer(string action, int start, Func<bool, JObject> observe)
        {
            var o = Report();
            o["action"] = action;
            if (action == "step") o["stepped"] = stepped;
            o["frames"] = Time.frameCount - start;
            o["after"] = observe(false);
            return o;
        }
    }
}
