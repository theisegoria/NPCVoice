// Process-wide log sink for the SDK (npc_set_log_callback). Silent until a game installs
// a callback; messages below the minimum level are never formatted.
#pragma once
#include <string>

namespace npc::log {
enum Level { Debug = 0, Info = 1, Warning = 2, Error = 3 };
bool enabled(int level);
void emit(int level, const std::string& message);
}
