// Scene component: opens NPCVoice on a background thread, submits game calls and raises
// events for finished lines on the main thread.
using System;
using System.IO;
using System.Threading;
using UnityEngine;
using UnityEngine.Events;

namespace NPCVoice
{
    [Serializable] public class NPCVoiceLineEvent : UnityEvent<NPCVoiceResult> { }
    [Serializable] public class NPCVoiceTextEvent : UnityEvent<string> { }

    [AddComponentMenu("NPCVoice/NPCVoice Manager")]
    public class NPCVoiceManager : MonoBehaviour
    {
        [Tooltip("A .npcproj folder, or the one-file JSON from `npcvoice bundle`. Relative paths are under StreamingAssets.")]
        public string projectPath = "NPCVoice/Game.npcproj";
        [Tooltip("mlx: the bundled model. apple: Apple Intelligence. stub: testing.")]
        public string backend = "mlx";
        [TextArea] public string backendConfigJson = "";
        [Tooltip("Folder with qwen3.5-2b-4bit, kokoro-82m-coreml, misaki-en, misaki-ja. Relative paths are under StreamingAssets.")]
        public string modelsDir = "NPCVoice/Models";
        public bool speech = true;
        public bool openOnStart = true;

        public NPCVoiceTextEvent onOpened = new NPCVoiceTextEvent();   // empty string: success
        public NPCVoiceLineEvent onLine = new NPCVoiceLineEvent();
        public NPCVoiceTextEvent onFailed = new NPCVoiceTextEvent();

        public NPCVoiceClient Client { get; private set; }
        public bool IsOpen => Client != null;

        Thread opener;
        NPCVoiceClient opened;
        string openError;
        volatile bool openDone;

        void Start()
        {
            if (openOnStart) Open();
        }

        static string Resolve(string path) =>
            string.IsNullOrEmpty(path) || Path.IsPathRooted(path) ? path : Path.Combine(Application.streamingAssetsPath, path);

        /// <summary>Opens the project, model and speech without blocking; onOpened follows.</summary>
        public void Open()
        {
            if (opener != null || Client != null) return;
            var options = new NPCVoiceClient.Options
            {
                ProjectPath = Resolve(projectPath),
                Backend = backend,
                BackendConfigJson = backendConfigJson,
                ModelsDir = Resolve(modelsDir) ?? "",
                Speech = speech,
            };
            if (!string.IsNullOrEmpty(options.ModelsDir) && !Directory.Exists(options.ModelsDir)) options.ModelsDir = "";
            opener = new Thread(() =>
            {
                opened = NPCVoiceClient.Open(options, out openError);
                openDone = true;
            }) { IsBackground = true, Name = "NPCVoice open" };
            opener.Start();
        }

        /// <summary>The character answers the player. Returns a ticket (0 on failure, with onFailed).</summary>
        public long Say(string character, string playerLine, NPCVoiceGameState state = null) => Submit(character, playerLine, null, state);

        /// <summary>The character reacts to an event, e.g. "The player draws a knife."</summary>
        public long React(string character, string gameEvent, NPCVoiceGameState state = null) => Submit(character, null, gameEvent, state);

        public bool Cancel(long ticket) => Client != null && Client.Cancel(ticket);

        /// <summary>Frees the dialogue model's memory (~2.5 GB); the next line reloads it.</summary>
        public void UnloadModel() => Client?.UnloadModel();
        public void PrewarmModel() => Client?.PrewarmModel();

        long Submit(string character, string playerLine, string gameEvent, NPCVoiceGameState state)
        {
            if (Client == null) { onFailed.Invoke("NPCVoice is not open yet (wait for onOpened)"); return 0; }
            long ticket = Client.Submit(character, playerLine, gameEvent, state, out string error);
            if (ticket == 0) onFailed.Invoke(error);
            return ticket;
        }

        void Update()
        {
            if (openDone && opener != null)
            {
                opener.Join();
                opener = null;
                Client = opened;
                onOpened.Invoke(Client != null ? "" : openError);
            }
            if (Client == null) return;
            foreach (var result in Client.Drain()) onLine.Invoke(result);
        }

        void OnDestroy()
        {
            opener?.Join();
            if (Client == null && openDone) Client = opened;
            Client?.Dispose();
            Client = null;
        }
    }
}
