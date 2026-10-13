// A managed NPCVoice session: project, dialogue model, service and speech. Not tied to
// MonoBehaviour; NPCVoiceManager and NPCVoiceSpeaker use it from the main thread.
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using AOT;
using UnityEngine;

namespace NPCVoice
{
    public sealed class NPCVoiceClient : IDisposable
    {
        public class Options
        {
            /// <summary>A .npcproj folder, or the one-file JSON from `npcvoice bundle` (absolute paths).</summary>
            public string ProjectPath;
            /// <summary>"mlx" (bundled model), "apple" (Apple Intelligence) or "stub" (testing).</summary>
            public string Backend = "mlx";
            public string BackendConfigJson = "";
            /// <summary>Folder with qwen3.5-2b-4bit/, kokoro-82m-coreml/, misaki-en/, misaki-ja/. Empty: the default search.</summary>
            public string ModelsDir = "";
            public bool Speech = true;
        }

        IntPtr project, backend, service, speech;

        NPCVoiceClient() { }

        /// <summary>Opens everything (blocking: model loading takes 1-3 s). Call off the main thread.</summary>
        public static NPCVoiceClient Open(Options o, out string error)
        {
            var c = new NPCVoiceClient();
            error = null;
            IntPtr err;
            if (o.ProjectPath.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
                c.project = Native.npc_project_load_json(Native.Utf8(System.IO.File.ReadAllText(o.ProjectPath)), out err);
            else
                c.project = Native.npc_project_load(Native.Utf8(o.ProjectPath), out err);
            if (c.project == IntPtr.Zero) return c.Fail(err, out error);

            string config = o.BackendConfigJson ?? "";
            switch (o.Backend)
            {
                case "mlx":
                    if (config.Length == 0 && !string.IsNullOrEmpty(o.ModelsDir))
                        config = "{\"modelDir\":" + CallJson.Quote(System.IO.Path.Combine(o.ModelsDir, "qwen3.5-2b-4bit")) + "}";
                    c.backend = Native.npc_backend_create_mlx(Native.Utf8(config, true), out err);
                    break;
                case "apple": c.backend = Native.npc_backend_create_apple(out err); break;
                case "stub": c.backend = Native.npc_backend_create_stub(Native.Utf8(config, true), out err); break;
                default: c.Dispose(); error = "unknown backend '" + o.Backend + "'"; return null;
            }
            if (c.backend == IntPtr.Zero) return c.Fail(err, out error);

            c.service = Native.npc_service_create(c.backend, null, out err);
            if (c.service == IntPtr.Zero) return c.Fail(err, out error);

            if (o.Speech)
            {
                c.speech = Native.npc_speech_create(Native.Utf8(o.ModelsDir, true), out err);
                if (c.speech == IntPtr.Zero) return c.Fail(err, out error);
                if (Native.npc_speech_set_project(c.speech, c.project, out err) == 0) return c.Fail(err, out error);
            }
            return c;
        }

        NPCVoiceClient Fail(IntPtr err, out string error)
        {
            error = Native.Take(err) ?? "unknown error";
            Dispose();
            return null;
        }

        public bool HasSpeech => speech != IntPtr.Zero;

        /// <summary>Submits a game call. Returns a ticket, or 0 with an error.</summary>
        public long Submit(string character, string playerLine, string trigger, NPCVoiceGameState state, out string error)
        {
            error = null;
            IntPtr err;
            IntPtr request = Native.npc_project_request(project, Native.Utf8(CallJson.Build(character, playerLine, trigger, state)), out err);
            if (request == IntPtr.Zero) { error = Native.Take(err); return 0; }
            string requestJson = Native.Take(request);
            ulong ticket = Native.npc_service_submit(service, Native.Utf8(requestJson), out err);
            if (ticket == 0) error = Native.Take(err);
            return (long)ticket;
        }

        public bool Cancel(long ticket) => Native.npc_service_cancel(service, (ulong)ticket) != 0;

        /// <summary>Finished results since the last call. Non-blocking: call every frame.</summary>
        public NPCVoiceResult[] Drain()
        {
            string json = Native.Take(Native.npc_service_drain(service));
            if (string.IsNullOrEmpty(json) || json.Length <= 2) return Array.Empty<NPCVoiceResult>();
            var list = JsonUtility.FromJson<NPCVoiceResultList>("{\"items\":" + json + "}");
            return list?.items ?? Array.Empty<NPCVoiceResult>();
        }

        public void UnloadModel() => Native.npc_backend_unload(backend);
        public void PrewarmModel() => Native.npc_backend_prewarm(backend);

        // ------------------------------------------------------------ streamed speech

        /// <summary>One streamed piece, copied out of the native callback.</summary>
        public struct Chunk
        {
            public long Ticket;
            public float[] Samples;        // mono, 24 kHz
            public double StartTime;       // seconds from the start of the line
            public int Index;
            public bool Last;
            public NPCVoiceViseme[] Visemes;
        }

        /// <summary>Receives a request's chunks and its end on SDK threads; read them from the main thread.</summary>
        public sealed class SpeechInbox
        {
            public readonly ConcurrentQueue<Chunk> Chunks = new ConcurrentQueue<Chunk>();
            public volatile bool Finished;
            public volatile int Status = -1;
            public string Error;
        }

        /// <summary>Streams speech by sentence. Returns a ticket (0 with error); the inbox fills as audio is ready.</summary>
        public long Speak(string text, string voice, double speed, SpeechInbox inbox, out string error)
        {
            error = null;
            if (speech == IntPtr.Zero) { error = "speech is off"; return 0; }
            GCHandle handle = GCHandle.Alloc(inbox);
            IntPtr err;
            ulong ticket = Native.npc_speech_submit(speech, Native.Utf8(text), Native.Utf8(voice), speed, OnChunk, OnDone,
                                                    GCHandle.ToIntPtr(handle), out err);
            if (ticket == 0) { handle.Free(); error = Native.Take(err); }
            return (long)ticket;
        }

        public bool CancelSpeech(long ticket) => speech != IntPtr.Zero && Native.npc_speech_cancel(speech, (ulong)ticket) != 0;

        // Static, kept alive by these fields, and marked for IL2CPP.
        static readonly Native.SpeechChunkFn OnChunk = ChunkCallback;
        static readonly Native.SpeechDoneFn OnDone = DoneCallback;

        [MonoPInvokeCallback(typeof(Native.SpeechChunkFn))]
        static void ChunkCallback(IntPtr context, ulong ticket, IntPtr chunkPtr)
        {
            var inbox = (SpeechInbox)GCHandle.FromIntPtr(context).Target;
            var c = Marshal.PtrToStructure<Native.SpeechChunk>(chunkPtr);
            var samples = new float[(int)c.sample_count];
            if (samples.Length > 0) Marshal.Copy(c.pcm, samples, 0, samples.Length);
            var info = JsonUtility.FromJson<NPCVoiceChunkInfo>(Native.Read(c.info_json) ?? "{}");
            inbox.Chunks.Enqueue(new Chunk
            {
                Ticket = (long)ticket, Samples = samples, StartTime = c.start_time, Index = (int)c.index,
                Last = c.is_last != 0, Visemes = info?.visemes ?? Array.Empty<NPCVoiceViseme>()
            });
        }

        [MonoPInvokeCallback(typeof(Native.SpeechDoneFn))]
        static void DoneCallback(IntPtr context, ulong ticket, int status, IntPtr error)
        {
            GCHandle handle = GCHandle.FromIntPtr(context);
            var inbox = (SpeechInbox)handle.Target;
            inbox.Error = Native.Read(error);
            inbox.Status = status;
            inbox.Finished = true;
            handle.Free();      // on_done is the last call for this ticket
        }

        // ------------------------------------------------------------ logging

        static Action<int, string> logHandler;
        static readonly Native.LogFn OnLog = LogCallback;

        /// <summary>Routes NPCVoice diagnostics (model loads, fallbacks and why) to your logger. Runs on SDK threads.</summary>
        public static void SetLogHandler(Action<int, string> handler, int minLevel = 1)
        {
            logHandler = handler;
            Native.npc_set_log_callback(handler == null ? null : OnLog, IntPtr.Zero, minLevel);
        }

        [MonoPInvokeCallback(typeof(Native.LogFn))]
        static void LogCallback(IntPtr context, int level, IntPtr message)
        {
            logHandler?.Invoke(level, Native.Read(message));
        }

        public void Dispose()
        {
            if (speech != IntPtr.Zero) { Native.npc_speech_release(speech); speech = IntPtr.Zero; }
            if (service != IntPtr.Zero) { Native.npc_service_destroy(service); service = IntPtr.Zero; }
            if (backend != IntPtr.Zero) { Native.npc_backend_release(backend); backend = IntPtr.Zero; }
            if (project != IntPtr.Zero) { Native.npc_project_release(project); project = IntPtr.Zero; }
        }
    }
}
