# NPCVoice for Unreal Engine 5

A runtime plugin for UE 5.4+ on Apple-silicon Macs. Characters answer the player and game events
through Blueprint events, and a component streams their speech, with lip-sync visemes.

> **Status: untested.** This was written without Unreal Engine at hand. The C++ layer it is built
> on (`Integrations/cpp`) is tested against the library, but the Unreal classes are not. If
> something doesn't compile or behave, please open an issue.

## Install

```bash
Integrations/Unreal/setup.sh /path/to/NPCVoiceKit.xcframework   # copies the framework and headers into the plugin
cp -R Integrations/Unreal/NPCVoice <YourProject>/Plugins/
```

The xcframework comes from the release's SDK zip, or from `tools/build_xcframework.sh`.

## Use (Blueprints or C++)

1. **Open.** Get the **NPCVoice Subsystem** (game instance) and call **Open** with settings:
   - `ProjectPath`: a `.npcproj` folder relative to the project directory (add it under Project
     Settings → Packaging → *Additional Non-Asset Directories to Copy*), or the one-file JSON
     from `npcvoice bundle`.
   - `Backend`: `mlx`, `apple` or `stub`.
   - `ModelsDir`: the folder with the weights (see below).

   **OnOpened** fires when the session is ready, with an empty error.
2. **Talk.** Call **Say** (the player speaks) or **React** (an event happens) with an
   `FNPCVoiceGameState`: flags, location, memories, and a deadline. **OnLine** delivers an
   `FNPCVoiceLine`: text, emotion, intent, validated commands, voice, and source / fallback
   reason.
3. **Speak.** Add an **NPCVoice Speech** component to the character and call **SpeakLine** with the
   line. Audio streams sentence by sentence (24 kHz mono). In Tick or your Anim Blueprint,
   **GetCurrentViseme** returns the mouth shape and its weight, and **OnSpeechFinished** fires at
   the end.

**UnloadModel** frees about 2.5 GB, e.g. during a cutscene, and **PrewarmModel** reloads it
ahead of the next conversation.

## Model weights

The weights (about 2 GB) aren't in the plugin. Put a `Models` folder (`qwen3.5-2b-4bit`,
`kokoro-82m-coreml`, `misaki-en`, `misaki-ja`, from the NPCVoice release or
`tools/fetch_models.sh`) in your project, stage it as a non-asset directory, and set `ModelsDir`
to it. Left empty, it falls back to `$NPCVOICE_MODELS`, then the app's
`Contents/Resources/Models`.
