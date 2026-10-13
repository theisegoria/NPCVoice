// P/Invoke declarations for the NPCVoice C ABI (npc_core.h, npc_sdk.h). Strings cross as
// UTF-8 byte arrays and IntPtrs; the managed wrappers in NPCVoiceClient.cs do the conversions.
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace NPCVoice
{
    internal static class Native
    {
        // Assets/.../Plugins/macOS/NPCVoiceKit.bundle (built by tools/package_unity_plugin.sh).
        const string Lib = "NPCVoiceKit";

        public const int SpeechDone = 0, SpeechCancelled = 1, SpeechFailed = 2;

        [StructLayout(LayoutKind.Sequential)]
        public struct SpeechChunk
        {
            public IntPtr pcm;            // const float*
            public ulong sample_count;
            public double sample_rate;
            public double start_time;
            public uint index;
            public int is_last;
            public IntPtr info_json;      // const char*
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Audio
        {
            public IntPtr pcm;            // float*
            public ulong sample_count;
            public double sample_rate;
            public IntPtr info_json;      // char*
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void LogFn(IntPtr context, int level, IntPtr message);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void SpeechChunkFn(IntPtr context, ulong ticket, IntPtr chunk);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void SpeechDoneFn(IntPtr context, ulong ticket, int status, IntPtr error);

        [DllImport(Lib)] public static extern int npc_core_abi_version();
        [DllImport(Lib)] public static extern IntPtr npc_sdk_version();
        [DllImport(Lib)] public static extern void npc_string_free(IntPtr s);
        [DllImport(Lib)] public static extern void npc_set_log_callback(LogFn fn, IntPtr context, int minLevel);

        [DllImport(Lib)] public static extern IntPtr npc_project_load(byte[] path, out IntPtr error);
        [DllImport(Lib)] public static extern IntPtr npc_project_load_json(byte[] json, out IntPtr error);
        [DllImport(Lib)] public static extern void npc_project_release(IntPtr project);
        [DllImport(Lib)] public static extern IntPtr npc_project_request(IntPtr project, byte[] callJson, out IntPtr error);

        [DllImport(Lib)] public static extern IntPtr npc_backend_create_mlx(byte[] configJson, out IntPtr error);
        [DllImport(Lib)] public static extern IntPtr npc_backend_create_apple(out IntPtr error);
        [DllImport(Lib)] public static extern IntPtr npc_backend_create_stub(byte[] configJson, out IntPtr error);
        [DllImport(Lib)] public static extern void npc_backend_release(IntPtr backend);
        [DllImport(Lib)] public static extern void npc_backend_prewarm(IntPtr backend);
        [DllImport(Lib)] public static extern void npc_backend_unload(IntPtr backend);

        [DllImport(Lib)] public static extern IntPtr npc_service_create(IntPtr backend, byte[] configJson, out IntPtr error);
        [DllImport(Lib)] public static extern void npc_service_destroy(IntPtr service);
        [DllImport(Lib)] public static extern ulong npc_service_submit(IntPtr service, byte[] requestJson, out IntPtr error);
        [DllImport(Lib)] public static extern int npc_service_cancel(IntPtr service, ulong ticket);
        [DllImport(Lib)] public static extern IntPtr npc_service_drain(IntPtr service);

        [DllImport(Lib)] public static extern IntPtr npc_speech_create(byte[] modelsDir, out IntPtr error);
        [DllImport(Lib)] public static extern void npc_speech_release(IntPtr speech);
        [DllImport(Lib)] public static extern int npc_speech_set_project(IntPtr speech, IntPtr project, out IntPtr error);
        [DllImport(Lib)] public static extern IntPtr npc_speech_speak(IntPtr speech, byte[] text, byte[] voice, double speed, out IntPtr error);
        [DllImport(Lib)] public static extern void npc_audio_free(IntPtr audio);
        [DllImport(Lib)] public static extern ulong npc_speech_submit(IntPtr speech, byte[] text, byte[] voice, double speed,
                                                                      SpeechChunkFn onChunk, SpeechDoneFn onDone, IntPtr context,
                                                                      out IntPtr error);
        [DllImport(Lib)] public static extern int npc_speech_cancel(IntPtr speech, ulong ticket);

        /// <summary>Null-terminated UTF-8, or null for an empty string (the C ABI's "default").</summary>
        public static byte[] Utf8(string s, bool emptyAsNull = false)
        {
            if (s == null || (emptyAsNull && s.Length == 0)) return null;
            int n = Encoding.UTF8.GetByteCount(s);
            var bytes = new byte[n + 1];
            Encoding.UTF8.GetBytes(s, 0, s.Length, bytes, 0);
            return bytes;
        }

        /// <summary>Reads a null-terminated UTF-8 string without freeing it.</summary>
        public static string Read(IntPtr p)
        {
            if (p == IntPtr.Zero) return null;
            int n = 0;
            while (Marshal.ReadByte(p, n) != 0) n++;
            var bytes = new byte[n];
            Marshal.Copy(p, bytes, 0, n);
            return Encoding.UTF8.GetString(bytes);
        }

        /// <summary>Reads and frees a string the library returned.</summary>
        public static string Take(IntPtr p)
        {
            string s = Read(p);
            if (p != IntPtr.Zero) npc_string_free(p);
            return s;
        }
    }
}
