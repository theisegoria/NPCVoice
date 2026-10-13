// Asks Marta (the sample project's innkeeper) a question and speaks her answer.
// Scene: an NPCVoiceManager (projectPath under StreamingAssets, backend "mlx"), and on the
// character an AudioSource + NPCVoiceSpeaker + this script.
using NPCVoice;
using UnityEngine;

public class TalkToMarta : MonoBehaviour
{
    public NPCVoiceManager manager;
    public NPCVoiceSpeaker speaker;
    public SkinnedMeshRenderer face;          // optional: blend shapes named after visemes (aa, E, ih, oh, ou, PP, FF...)

    void Start()
    {
        manager.onOpened.AddListener(error =>
        {
            if (error != "") { Debug.LogError("NPCVoice: " + error); return; }
            var state = new NPCVoiceGameState { location = "The Gull & Lantern", deadlineMs = 2500 };
            manager.Say("marta", "Evening. Got a room for the night?", state);
        });
        manager.onLine.AddListener(result =>
        {
            Debug.Log($"{result.line.character} ({result.line.emotion}, {result.source}): {result.line.text}");
            foreach (var command in result.line.commands) Debug.Log($"  wants to: {command.kind} {command.target}");
            speaker.SpeakLine(result);
        });
    }

    void Update()
    {
        if (face == null || !speaker.IsSpeaking) return;
        string viseme = speaker.CurrentViseme(out float weight);
        for (int i = 0; i < face.sharedMesh.blendShapeCount; i++)
            face.SetBlendShapeWeight(i, face.sharedMesh.GetBlendShapeName(i) == viseme ? weight * 100f : 0f);
    }
}
