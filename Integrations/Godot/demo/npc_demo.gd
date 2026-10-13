# Talks to Marta from the sample project and plays her streamed reply with lip-sync visemes.
# Scene: a Node with this script, an NPCVoice child named "NPCVoice" (project_path set to your
# .npcproj folder, or the one-file JSON from `npcvoice bundle`), and an AudioStreamPlayer
# child named "Voice".
extends Node

@onready var npc: NPCVoice = $NPCVoice
@onready var voice: AudioStreamPlayer = $Voice
var playback: AudioStreamGeneratorPlayback
var visemes: Array = []          # [{viseme, start, end, weight}] on the line's timeline
var line_started_at := 0.0

func _ready() -> void:
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = 24000.0        # NPCVoice speech is 24 kHz mono
	stream.buffer_length = 10.0
	voice.stream = stream
	npc.opened.connect(_on_opened)
	npc.line_ready.connect(_on_line)
	npc.speech_chunk.connect(_on_chunk)
	npc.failed.connect(func(error): push_warning("NPCVoice: " + error))

func _on_opened(error: String) -> void:
	if error != "":
		push_error("NPCVoice: " + error)
		return
	npc.say("marta", "Evening. Got a room for the night?", {"location": "The Gull & Lantern", "deadline_ms": 2500})

func _on_line(result: Dictionary) -> void:
	var line: Dictionary = result["line"]
	print("%s (%s, %s via %s): %s" % [line["character"], line["emotion"], line["intent"], result["source"], line["text"]])
	for command in line["commands"]:
		print("  wants to: %s %s" % [command["kind"], command["target"]])
	voice.play()
	playback = voice.get_stream_playback()
	visemes.clear()
	line_started_at = Time.get_ticks_msec() / 1000.0
	npc.speak(line["text"], line["voice"])

func _on_chunk(_ticket: int, samples: PackedFloat32Array, _start_time: float, _index: int, _last: bool, info: Dictionary) -> void:
	for s in samples:
		playback.push_frame(Vector2(s, s))
	visemes.append_array(info.get("visemes", []))

func current_viseme() -> String:
	var t := Time.get_ticks_msec() / 1000.0 - line_started_at
	for v in visemes:
		if t >= v["start"] and t < v["end"]:
			return v["viseme"]
	return "sil"
