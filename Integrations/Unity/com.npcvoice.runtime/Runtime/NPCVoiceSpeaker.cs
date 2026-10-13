// Plays a character's streamed speech through an AudioSource and reports the current
// lip-sync viseme. Attach next to the character's AudioSource.
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Events;

namespace NPCVoice
{
    [RequireComponent(typeof(AudioSource))]
    [AddComponentMenu("NPCVoice/NPCVoice Speaker")]
    public class NPCVoiceSpeaker : MonoBehaviour
    {
        const int SampleRate = 24000;          // NPCVoice speech; Unity resamples to the output rate
        const int MaxSeconds = 600;

        public NPCVoiceManager manager;
        public UnityEvent onFinished = new UnityEvent();

        AudioSource source;
        NPCVoiceClient.SpeechInbox inbox;
        long ticket;
        readonly Queue<float> buffer = new Queue<float>();   // guarded by lock(buffer)
        readonly List<NPCVoiceViseme> visemes = new List<NPCVoiceViseme>();
        bool started, finishedReported;
        long received;                                        // samples of this line so far

        void Awake()
        {
            source = GetComponent<AudioSource>();
            if (manager == null) manager = FindObjectOfType<NPCVoiceManager>();
        }

        /// <summary>Speaks a line in its character's voice. Returns a ticket (0 if speech isn't available).</summary>
        public long SpeakLine(NPCVoiceResult result, float speed = 1f) => Speak(result.line.text, result.line.voice, speed);

        /// <summary>voice: af_heart, af_bella, am_michael, am_fenrir, jf_alpha, jf_tebukuro, jm_kumo.</summary>
        public long Speak(string text, string voice, float speed = 1f)
        {
            if (manager == null || manager.Client == null || !manager.Client.HasSpeech) return 0;
            Stop();
            inbox = new NPCVoiceClient.SpeechInbox();
            ticket = manager.Client.Speak(text, voice, speed, inbox, out string error);
            if (ticket == 0) { Debug.LogWarning("NPCVoice: " + error); inbox = null; return 0; }
            started = false;
            finishedReported = false;
            received = 0;
            return ticket;
        }

        public void Stop()
        {
            if (inbox != null && !inbox.Finished && manager != null && manager.Client != null) manager.Client.CancelSpeech(ticket);
            inbox = null;
            lock (buffer) buffer.Clear();
            visemes.Clear();
            if (source.isPlaying) source.Stop();
        }

        public bool IsSpeaking => inbox != null;

        /// <summary>The viseme at the playback position and its weight, for mouth shapes or blend shapes.</summary>
        public string CurrentViseme(out float weight)
        {
            weight = 0f;
            if (!started) return "sil";
            double t = (double)source.timeSamples / SampleRate;
            foreach (var v in visemes)
            {
                if (t >= v.start && t < v.end) { weight = v.weight; return v.viseme; }
            }
            return "sil";
        }

        void Update()
        {
            if (inbox == null) return;
            while (inbox.Chunks.TryDequeue(out var chunk))
            {
                lock (buffer) foreach (var s in chunk.Samples) buffer.Enqueue(s);
                received += chunk.Samples.Length;
                visemes.AddRange(chunk.Visemes);
                if (!started)
                {
                    // Start on the first chunk so the clip's clock matches the line's timeline.
                    source.clip = AudioClip.Create("NPCVoice", SampleRate * MaxSeconds, 1, SampleRate, true, Read);
                    source.Play();
                    started = true;
                }
            }
            // Done once the SDK has finished and playback has passed the last sample (the
            // streaming clip reads ahead, so an empty buffer alone would cut the line short).
            if (inbox.Finished && !finishedReported && (!started || source.timeSamples >= received || !source.isPlaying))
            {
                finishedReported = true;
                if (inbox.Status == Native.SpeechFailed) Debug.LogWarning("NPCVoice speech failed: " + inbox.Error);
                inbox = null;
                if (source.isPlaying) source.Stop();
                onFinished.Invoke();
            }
        }

        // Called by Unity to fill the streaming clip.
        void Read(float[] data)
        {
            lock (buffer)
            {
                for (int i = 0; i < data.Length; i++) data[i] = buffer.Count > 0 ? buffer.Dequeue() : 0f;
            }
        }

        void OnDestroy() => Stop();
    }
}
