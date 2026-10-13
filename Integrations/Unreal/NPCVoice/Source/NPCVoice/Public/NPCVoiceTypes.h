// Blueprint types for NPCVoice. Field meanings: docs/JSON.md in the NPCVoice repository.
#pragma once

#include "CoreMinimal.h"
#include "NPCVoiceTypes.generated.h"

USTRUCT(BlueprintType)
struct NPCVOICE_API FNPCVoiceSettings
{
	GENERATED_BODY()

	/** A .npcproj folder (relative to the project directory, staged as a non-asset directory), or the
	 *  one-file JSON from `npcvoice bundle`, which also loads from a .pak. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	FString ProjectPath = TEXT("NPC/Game.npcproj");

	/** "mlx" (bundled model), "apple" (Apple Intelligence) or "stub" (testing). */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	FString Backend = TEXT("mlx");

	/** Optional backend config JSON (mlx: {"cacheMB": 256}; stub: {"fixedResponse": "..."}). */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	FString BackendConfigJson;

	/** Folder holding qwen3.5-2b-4bit/, kokoro-82m-coreml/, misaki-en/, misaki-ja/. Empty: $NPCVOICE_MODELS,
	 *  then the app's Contents/Resources/Models. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	FString ModelsDir;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	bool bSpeech = true;
};

/** What the game knows right now; sent with each call. */
USTRUCT(BlueprintType)
struct NPCVOICE_API FNPCVoiceGameState
{
	GENERATED_BODY()

	/** Progress flags currently set (they unlock secret facts). */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	TArray<FString> Flags;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	FString Location;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	FString Objective;

	/** Overrides the character's mood for this line. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	FString Mood;

	/** Long-term notes about the player, e.g. "The player paid on time". */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	TArray<FString> Memories;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	TArray<FString> Topics;

	/** 0 keeps the project's default (2.5 s). Late lines fall back to hand-written ones. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "NPCVoice")
	int32 DeadlineMs = 0;
};

USTRUCT(BlueprintType)
struct NPCVOICE_API FNPCVoiceCommand
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	FString Kind;

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	FString Target;
};

USTRUCT(BlueprintType)
struct NPCVOICE_API FNPCVoiceLine
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	int64 Ticket = 0;

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	FString Character;

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	FString Text;

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	FString Emotion;

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	FString Intent;

	/** Already validated against the project's commands; your game decides whether to run them. */
	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	TArray<FNPCVoiceCommand> Commands;

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	FString Voice;

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	FString Language;

	/** "model", "cache" or "fallback". */
	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	FString Source;

	/** Why a fallback line was used ("timeout", "guardrail_rejected"...), or "none". */
	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	FString FallbackReason;

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	float LatencyMs = 0;

	UPROPERTY(BlueprintReadOnly, Category = "NPCVoice")
	bool bCancelled = false;
};

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FNPCVoiceOpened, const FString&, Error);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FNPCVoiceLineReady, const FNPCVoiceLine&, Line);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FNPCVoiceFailed, const FString&, Error);
