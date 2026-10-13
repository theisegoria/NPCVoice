#pragma once
// JSON contract for the dialogue core (docs/JSON.md). Every public surface (C ABI,
// Swift API, CLI, app) exchanges these shapes, so they are versioned and strict:
// decoding rejects unknown keys and wrong types with a path in the message
// (e.g. "character.traits[2]: expected a string").
#include "Dialogue.hpp"
#include <stdexcept>
#include <string>
#include <string_view>

namespace npc::dialogue::codec {

// Thrown by every decoder. what() starts with the JSON path of the offending value.
struct DecodeError : std::invalid_argument {using std::invalid_argument::invalid_argument;};

DialogueRequest decodeRequest(std::string_view json);
std::string encodeRequest(const DialogueRequest&);

WorldProfile decodeWorld(std::string_view json);
CharacterProfile decodeCharacter(std::string_view json);

std::string encodeResult(const DialogueResult&);
std::string encodeLine(const DialogueLine&);
std::string encodeStats(const ServiceStats&);
// Prompt inspection for tools: instructions, prompt, schema, grounding, cache key.
std::string encodePreparedPrompt(const PreparedPrompt&);
std::string encodeValidation(const Validation&);

// Backend wire format (npc_core.h native backends).
std::string encodeBackendRequest(const BackendRequest&);
BackendResponse decodeBackendResponse(std::string_view json);
std::string encodeBackendResponse(const BackendResponse&);

ServiceConfig decodeServiceConfig(std::string_view json);   // empty string = defaults

std::optional<BackendStatus> parseBackendStatus(std::string_view);

} // namespace npc::dialogue::codec
