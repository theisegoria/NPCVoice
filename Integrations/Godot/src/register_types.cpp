#include "npc_voice.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_npcvoice(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
    GDREGISTER_CLASS(NPCVoice);
}

static void uninitialize_npcvoice(ModuleInitializationLevel) {}

extern "C" GDExtensionBool GDE_EXPORT npcvoice_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                                                            GDExtensionClassLibraryPtr library,
                                                            GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_npcvoice);
    init.register_terminator(uninitialize_npcvoice);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
