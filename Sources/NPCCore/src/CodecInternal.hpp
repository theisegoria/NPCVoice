#pragma once
// Decoders for individual contract objects, shared by Codec.cpp and Project.cpp.
#include "Codec.hpp"
#include "JsonIO.hpp"

namespace npc::dialogue::codec::detail {

Language languageAt(const json::Value&,const std::string& path);
Emotion emotionAt(const json::Value&,const std::string& path);
Intent intentAt(const json::Value&,const std::string& path);
WorldProfile worldAt(const json::Value&,const std::string& path);
CharacterProfile characterAt(const json::Value&,const std::string& path);
Fact factAt(const json::Value&,const std::string& path);
CommandSpec commandSpecAt(const json::Value&,const std::string& path);
FallbackLine fallbackAt(const json::Value&,const std::string& path);
GroundingContext contextAt(const json::Value&,const std::string& path);
Budget budgetAt(const json::Value&,const std::string& path);
Sampling samplingAt(const json::Value&,const std::string& path);
void writeWorld(io::Writer&,const WorldProfile&);
void writeCharacter(io::Writer&,const CharacterProfile&);
void writeSampling(io::Writer&,const Sampling&);

} // namespace npc::dialogue::codec::detail
