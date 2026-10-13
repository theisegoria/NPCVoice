#pragma once
// .npcproj projects (docs/JSON.md, docs/schema): a folder of authored JSON files.
//
//   MyGame.npcproj/
//     project.json            {"format":"npcvoice-project","version":1,"world":{...},"defaults":{...}}
//     facts.json              {"facts":[...]}
//     commands.json           {"commands":[...]}
//     characters/<id>.json    a character profile plus "fallbacks" and "commands" (command kinds)
//
// The game owns runtime state (flags, location, conversation, memories) and passes it
// with each call; the project supplies everything authored.
#include "Dialogue.hpp"
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace npc::dialogue {

struct ProjectCharacter {
    CharacterProfile profile;
    std::vector<FallbackLine> fallbacks;
    std::vector<std::string> commandKinds;     // references into Project::commands
};

struct ProjectDefaults {
    Budget budget{};
    Sampling sampling{};
    std::uint32_t maxCommands{2};
};

// An author-supplied pronunciation for TTS (names, invented words). Phonemes use the
// misaki alphabet Kokoro reads (e.g. "ˈOkəfɔɹ" for English, "aiko" for Japanese).
struct Pronunciation {
    std::string word;
    std::string phonemes;
    Language language{Language::English};
};

struct Project {
    std::string name;                           // folder name without extension
    WorldProfile world;
    ProjectDefaults defaults;
    std::vector<ProjectCharacter> characters;   // sorted by id
    std::vector<Fact> facts;
    std::vector<CommandSpec> commands;
    std::vector<Pronunciation> pronunciations;

    const ProjectCharacter* character(std::string_view id) const;
};

struct ProjectDiagnostic {
    enum class Severity : std::uint8_t {Error,Warning} severity{Severity::Error};
    std::string path;                           // file-relative, e.g. "characters/guard.json: voice"
    std::string message;
};

// Throws codec::DecodeError (with the file name in the path) on malformed files.
Project loadProject(const std::filesystem::path&);
// The combined form written by encodeProject (in-memory edits from tools).
Project decodeProject(std::string_view json);
std::vector<ProjectDiagnostic> diagnose(const Project&);
std::string encodeProject(const Project&);
std::string encodeDiagnostics(const std::vector<ProjectDiagnostic>&);

// A game call against a project (see npc_project_request in npc_core.h).
DialogueRequest buildRequest(const Project&,std::string_view callJson);

// Writes the "Harbor Town" sample. Throws std::runtime_error if `path` exists.
void writeSampleProject(const std::filesystem::path&);

// Kokoro voices bundled with NPCVoice; the first letter encodes the language
// ('a'/'b' English, 'j' Japanese).
const std::vector<std::string>& knownVoices();
std::optional<Language> voiceLanguage(std::string_view voice);

} // namespace npc::dialogue
