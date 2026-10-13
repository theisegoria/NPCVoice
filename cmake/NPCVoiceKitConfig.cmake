# NPCVoiceKit for CMake projects (C and C++ engines).
#
#   find_package(NPCVoiceKit 0.1 CONFIG REQUIRED PATHS <folder with this file and NPCVoiceKit.xcframework>)
#   target_link_libraries(my_game PRIVATE NPCVoiceKit::NPCVoiceKit)
#   #include <NPCVoiceKit/NPCVoiceKit.h>
#
# Apple-silicon macOS only. The framework is linked with an rpath to its folder; when you
# bundle your app, copy NPCVoiceKit.framework into Contents/Frameworks and add
# @executable_path/../Frameworks to your rpaths.
if(NOT APPLE)
    set(NPCVoiceKit_FOUND FALSE)
    set(NPCVoiceKit_NOT_FOUND_MESSAGE "NPCVoiceKit supports macOS on Apple silicon only")
    return()
endif()

set(_npc_slice "${CMAKE_CURRENT_LIST_DIR}/NPCVoiceKit.xcframework/macos-arm64")
if(NOT EXISTS "${_npc_slice}/NPCVoiceKit.framework")
    set(NPCVoiceKit_FOUND FALSE)
    set(NPCVoiceKit_NOT_FOUND_MESSAGE "NPCVoiceKit.xcframework/macos-arm64 not found next to ${CMAKE_CURRENT_LIST_FILE}")
    return()
endif()

if(NOT TARGET NPCVoiceKit::NPCVoiceKit)
    add_library(NPCVoiceKit::NPCVoiceKit INTERFACE IMPORTED)
    set_target_properties(NPCVoiceKit::NPCVoiceKit PROPERTIES
        # -F finds <NPCVoiceKit/...> headers; the Headers folder also serves quoted includes.
        INTERFACE_COMPILE_OPTIONS "-F${_npc_slice}"
        INTERFACE_INCLUDE_DIRECTORIES "${_npc_slice}/NPCVoiceKit.framework/Headers"
        INTERFACE_LINK_OPTIONS "-F${_npc_slice};SHELL:-framework NPCVoiceKit;-Wl,-rpath,${_npc_slice}")
endif()
set(NPCVoiceKit_FRAMEWORK "${_npc_slice}/NPCVoiceKit.framework")
unset(_npc_slice)
