# Builds the C sample against the binary NPCVoiceKit.xcframework only (no sources), the way
# a C or C++ engine would:
#   cmake -S Samples/c-sample -B build/c-sample -DNPCVoiceKit_DIR=$PWD/dist && cmake --build build/c-sample
cmake_minimum_required(VERSION 3.24)
project(npc_c_sample C)
find_package(NPCVoiceKit 0.1 CONFIG REQUIRED)
add_executable(npc-c-sample main.c)
target_link_libraries(npc-c-sample PRIVATE NPCVoiceKit::NPCVoiceKit)
