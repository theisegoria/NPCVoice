# Engine integrations

All of these sit on the same C ABI (`docs/C_API.md`) and work the same way:
- open NPCVoice at load time, off the main thread;
- submit game calls, which return tickets;
- receive finished lines once per frame;
- stream speech with lip-sync visemes.

| Folder | Engine | Status |
|---|---|---|
| [`cpp/`](cpp) | Any C++ engine: header-only RAII wrapper, no exceptions, C++17 | **Tested** against the library (`swift run npcvoice-cpp-tests <project>`) |
| [`Unreal/`](Unreal) | Unreal Engine 5.4+: subsystem with Blueprint events, speech component | Untested: written without Unreal |
| [`Godot/`](Godot) | Godot 4.3+: GDExtension `NPCVoice` node with signals | Untested: written without Godot |
| [`Unity/`](Unity) | Unity 2022.3+: UPM package, manager and speaker components | Untested C#; the native plugin bundle is tested |

The Unreal and Godot layers are thin; the logic lives in the tested C++ wrapper. If an
integration doesn't build or behave in your engine version, please open an issue (or a PR).

All of them need the model weights (about 2 GB) next to your game: download them with
`tools/fetch_models.sh` or from the release, and point the integration's models folder at them.
