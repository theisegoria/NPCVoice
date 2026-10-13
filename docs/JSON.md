# NPCVoice JSON

Every NPCVoice payload is UTF-8 JSON, and each has a JSON Schema (2020-12) in [schema/](schema/).
Decoding is strict: unknown fields, wrong types and unknown tokens are errors, and errors name
the path. The schemas are tested against the core: the sample project validates, real results
validate, and both reject the same malformed calls (`Tests/NPCKitTests/SchemaTests.swift`).

## Payloads

| Payload | Where it's used | Schema |
|---|---|---|
| `project.json` | A `.npcproj` folder: format, version, world, defaults, pronunciations | [project](schema/project.schema.json) |
| `characters/<id>.json` | One character: persona, constraints, voice, fallback lines, commands | [character](schema/character.schema.json) |
| `facts.json` | Facts and lore: who knows each one, and which flags unlock it | [facts](schema/facts.schema.json) |
| `commands.json` | Game actions characters may propose | [commands](schema/commands.schema.json) |
| Game call | `npc_project_request`: what the game sends per line | [call](schema/call.schema.json) |
| Result | `npc_service_wait` / `npc_service_drain` | [result](schema/result.schema.json) |
| Speech info | `npc_audio.info_json` | [speech-info](schema/speech-info.schema.json) |
| Streamed chunk info | `npc_speech_chunk.info_json` | [speech-chunk-info](schema/speech-chunk-info.schema.json) |
| Backend request / response | Custom backends | [request](schema/backend-request.schema.json), [response](schema/backend-response.schema.json) |
| Service config | `npc_service_create` | [service-config](schema/service-config.schema.json) |
| MLX config | `npc_backend_create_mlx` | [mlx-config](schema/mlx-config.schema.json) |

Shared definitions (vocabularies, budget, sampling, facts, lines, lip-sync segments) live in
[common](schema/common.schema.json).

## Project folder

```
Harbor Town.npcproj/
  project.json        {"format":"npcvoice-project","version":1,"name","world","defaults","pronunciations"}
  facts.json          {"facts":[...]}
  commands.json       {"commands":[...]}
  characters/marta.json
  portraits/marta.png authoring art for the app (optional; the runtime ignores it)
```

## A game call

```json
{
  "character": "marta",
  "playerUtterance": "Evening. Got a room for the night?",
  "flags": ["earned_tamsin_trust"],
  "location": "The Gull & Lantern, common room",
  "memories": ["The player paid on time last week"],
  "budget": {"deadlineMs": 2500}
}
```

Use `trigger` instead of `playerUtterance` for an event (`"The player draws a knife."`). The
project supplies everything else: persona, world rules, facts filtered by who knows them and by
`flags`, allowed commands, and fallback lines.

## A result

```json
{
  "ticket": 7, "status": "line", "source": "model", "fallbackReason": "none",
  "line": {"text": "Three marks a night, love.", "emotion": "happy", "intent": "inform",
           "commands": [{"kind": "give_item", "target": "room_key"}],
           "language": "en", "voice": "af_heart", "character": "marta"},
  "diagnostic": "", "promptTokens": 612, "outputTokens": 24, "latencyMs": 1180.5,
  "usedFactIds": ["room_price"]
}
```

`source` is `model`, `cache` (an identical request was already answered; `allowCache`) or `fallback`.
Commands have already been validated against `commands.json` and the character's allowed list,
but your game still decides whether to run them.

### Fallback reasons

| Reason | Meaning |
|---|---|
| `timeout` | The deadline passed (queueing included) |
| `queue_full` | Too many requests are pending (`queueCapacity`) |
| `backend_unavailable`, `unsupported_language` | The model can't serve this request |
| `invalid_request` | The request couldn't be turned into a prompt (the error is in `diagnostic`) |
| `schema_invalid` | The model's JSON didn't fit the schema |
| `guardrail_rejected` | Off-persona, a forbidden term, a withheld secret, the fourth wall, wrong script or length |
| `refusal`, `model_guardrail` | The model declined |
| `context_exceeded`, `rate_limited`, `backend_error` | Backend problems |

## Vocabularies

- **Emotions:** neutral, happy, sad, angry, fear, surprise, disgust, contempt, pain, exertion,
  concentration, fatigue.
- **Intents:** inform, warn, request, refuse, greet, farewell, deflect, plead, threaten.
- **Visemes:** sil, PP, FF, TH, DD, kk, CH, SS, RR, aa, E, ih, oh, ou, Y.
- **Voices:** af_heart, af_bella, am_michael, am_fenrir (English); jf_alpha, jf_tebukuro,
  jm_kumo (Japanese).
