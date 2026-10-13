// NPCVoice for Unreal Engine 5 (Mac, Apple silicon). Run Integrations/Unreal/setup.sh first: it
// copies NPCVoiceKit.framework and the headers into Source/ThirdParty.
using System.IO;
using UnrealBuildTool;

public class NPCVoice : ModuleRules
{
	public NPCVoice(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
		PublicDependencyModuleNames.AddRange(new string[] { "Core", "CoreUObject", "Engine", "AudioMixer", "Json" });

		if (Target.Platform == UnrealTargetPlatform.Mac)
		{
			string ThirdParty = Path.Combine(ModuleDirectory, "..", "ThirdParty");
			PublicIncludePaths.Add(Path.Combine(ThirdParty, "include"));
			// Linked, and copied into the app's Contents/Frameworks when packaging.
			PublicAdditionalFrameworks.Add(new Framework("NPCVoiceKit", Path.Combine(ThirdParty, "NPCVoiceKit.framework"), null, true));
		}
	}
}
