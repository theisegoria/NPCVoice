// NPCVoice game-instance subsystem: opens the project and models off the game thread, submits
// game calls, and broadcasts finished lines every tick.
#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "Tickable.h"
#include "NPCVoiceTypes.h"

#include <memory>
#include <mutex>
#include <string>

THIRD_PARTY_INCLUDES_START
#include "npcvoice/npcvoice.hpp"
THIRD_PARTY_INCLUDES_END

#include "NPCVoiceSubsystem.generated.h"

UCLASS()
class NPCVOICE_API UNPCVoiceSubsystem : public UGameInstanceSubsystem, public FTickableGameObject
{
	GENERATED_BODY()

public:
	virtual void Deinitialize() override;

	/** Opens the project, dialogue model and speech on a background thread; OnOpened follows. */
	UFUNCTION(BlueprintCallable, Category = "NPCVoice")
	void Open(const FNPCVoiceSettings& Settings);

	UFUNCTION(BlueprintPure, Category = "NPCVoice")
	bool IsOpen() const;

	/** The character answers the player. Returns a ticket (0 on failure, with OnFailed). */
	UFUNCTION(BlueprintCallable, Category = "NPCVoice")
	int64 Say(const FString& Character, const FString& PlayerLine, const FNPCVoiceGameState& State);

	/** The character reacts to an event ("The player draws a knife."). */
	UFUNCTION(BlueprintCallable, Category = "NPCVoice")
	int64 React(const FString& Character, const FString& Event, const FNPCVoiceGameState& State);

	UFUNCTION(BlueprintCallable, Category = "NPCVoice")
	bool Cancel(int64 Ticket);

	/** Frees the dialogue model's memory (~2.5 GB); the next line reloads it. */
	UFUNCTION(BlueprintCallable, Category = "NPCVoice")
	void UnloadModel();

	/** Loads the dialogue model in the background ahead of the next conversation. */
	UFUNCTION(BlueprintCallable, Category = "NPCVoice")
	void PrewarmModel();

	UPROPERTY(BlueprintAssignable, Category = "NPCVoice")
	FNPCVoiceOpened OnOpened;

	UPROPERTY(BlueprintAssignable, Category = "NPCVoice")
	FNPCVoiceLineReady OnLine;

	UPROPERTY(BlueprintAssignable, Category = "NPCVoice")
	FNPCVoiceFailed OnFailed;

	/** C++: the open session (null until OnOpened). Used by UNPCVoiceSpeechComponent. */
	const npcvoice::Session* GetSession() const;

	// FTickableGameObject
	virtual void Tick(float DeltaTime) override;
	virtual TStatId GetStatId() const override { RETURN_QUICK_DECLARE_CYCLE_STAT(UNPCVoiceSubsystem, STATGROUP_Tickables); }
	virtual bool IsTickable() const override { return !IsTemplate(); }
	virtual ETickableTickType GetTickableTickType() const override { return ETickableTickType::Conditional; }

private:
	// Shared with the opening thread.
	struct FOpenState
	{
		std::mutex Mutex;
		std::unique_ptr<npcvoice::Session> Session;
		bool bDone = false;
		std::string Error;
	};

	int64 Submit(npcvoice::Call Call, const FNPCVoiceGameState& State);

	std::shared_ptr<FOpenState> OpenState = std::make_shared<FOpenState>();
	bool bOpening = false;
};
