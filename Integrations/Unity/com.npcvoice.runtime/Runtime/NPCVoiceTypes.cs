// Result and game-state types. Field names match docs/JSON.md (JsonUtility maps them by name).
using System;
using System.Collections.Generic;
using System.Text;

namespace NPCVoice
{
    [Serializable]
    public class NPCVoiceCommand
    {
        public string kind;
        public string target;
    }

    [Serializable]
    public class NPCVoiceLine
    {
        public string text;
        public string emotion;
        public string intent;
        /// <summary>Validated against the project's commands; your game decides whether to run them.</summary>
        public NPCVoiceCommand[] commands;
        public string language;
        public string voice;
        public string character;
    }

    [Serializable]
    public class NPCVoiceResult
    {
        public long ticket;
        /// <summary>"line" or "cancelled".</summary>
        public string status;
        /// <summary>"model", "cache" or "fallback".</summary>
        public string source;
        /// <summary>Why a hand-written fallback line was used ("timeout", "guardrail_rejected"...), or "none".</summary>
        public string fallbackReason;
        public NPCVoiceLine line;
        public string diagnostic;
        public int promptTokens;
        public int outputTokens;
        public double latencyMs;
        public string[] usedFactIds;

        public bool IsFallback => source == "fallback";
    }

    [Serializable]
    class NPCVoiceResultList { public NPCVoiceResult[] items; }

    [Serializable]
    public class NPCVoiceViseme
    {
        /// <summary>sil, PP, FF, TH, DD, kk, CH, SS, RR, aa, E, ih, oh, ou or Y.</summary>
        public string viseme;
        public double start;
        public double end;
        public float weight;
    }

    [Serializable]
    class NPCVoiceChunkInfo
    {
        public string phonemes;
        public double gainDB;
        public NPCVoiceViseme[] visemes;
    }

    /// <summary>What the game knows right now; sent with each call.</summary>
    [Serializable]
    public class NPCVoiceGameState
    {
        /// <summary>Progress flags currently set (they unlock secret facts).</summary>
        public List<string> flags = new List<string>();
        public string location = "";
        public string objective = "";
        /// <summary>Overrides the character's mood for this line.</summary>
        public string mood = "";
        /// <summary>Long-term notes about the player, e.g. "The player paid on time".</summary>
        public List<string> memories = new List<string>();
        public List<string> topics = new List<string>();
        /// <summary>0 keeps the project's default (2.5 s). Late lines fall back to hand-written ones.</summary>
        public int deadlineMs = 0;
    }

    /// <summary>Builds a game call (docs/schema/call.schema.json).</summary>
    static class CallJson
    {
        public static string Build(string character, string playerLine, string trigger, NPCVoiceGameState state)
        {
            var j = new StringBuilder("{\"character\":").Append(Quote(character));
            if (!string.IsNullOrEmpty(playerLine)) j.Append(",\"playerUtterance\":").Append(Quote(playerLine));
            if (!string.IsNullOrEmpty(trigger)) j.Append(",\"trigger\":").Append(Quote(trigger));
            if (state != null)
            {
                if (state.flags != null && state.flags.Count > 0) j.Append(",\"flags\":").Append(Array(state.flags));
                if (!string.IsNullOrEmpty(state.location)) j.Append(",\"location\":").Append(Quote(state.location));
                if (!string.IsNullOrEmpty(state.objective)) j.Append(",\"objective\":").Append(Quote(state.objective));
                if (!string.IsNullOrEmpty(state.mood)) j.Append(",\"mood\":").Append(Quote(state.mood));
                if (state.memories != null && state.memories.Count > 0) j.Append(",\"memories\":").Append(Array(state.memories));
                if (state.topics != null && state.topics.Count > 0) j.Append(",\"topics\":").Append(Array(state.topics));
                if (state.deadlineMs > 0) j.Append(",\"budget\":{\"deadlineMs\":").Append(state.deadlineMs).Append('}');
            }
            return j.Append('}').ToString();
        }

        public static string Quote(string s)
        {
            var o = new StringBuilder("\"");
            foreach (char c in s ?? "")
            {
                switch (c)
                {
                    case '"': o.Append("\\\""); break;
                    case '\\': o.Append("\\\\"); break;
                    case '\n': o.Append("\\n"); break;
                    case '\r': o.Append("\\r"); break;
                    case '\t': o.Append("\\t"); break;
                    default:
                        if (c < 0x20) o.Append("\\u").Append(((int)c).ToString("x4"));
                        else o.Append(c);
                        break;
                }
            }
            return o.Append('"').ToString();
        }

        static string Array(List<string> items)
        {
            var o = new StringBuilder("[");
            for (int i = 0; i < items.Count; i++) o.Append(i > 0 ? "," : "").Append(Quote(items[i]));
            return o.Append(']').ToString();
        }
    }
}
