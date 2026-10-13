// Plays a character's streamed speech (24 kHz mono) and reports the current lip-sync viseme.
// Attach to the character; call SpeakLine with a line from UNPCVoiceSubsystem::OnLine.
#pragma once

#include "CoreMinimal.h"
#include "Components/SynthComponent.h"
#include "NPCVoiceTypes.h"

#include <atomic>
#include <deque>
#include <memory>
#include <mutex>
#include <vector>

#include "NPCVoiceSpeechComponent.generated.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FNPCVoiceSpeechFinished, int64, Ticket, bool, bCompleted);

UCLASS(ClassGroup = (NPCVoice), meta = (BlueprintSpawnableComponent))
class NPCVOICE_API UNPCVoiceSpeechComponent : public USynthComponent
{
	GENERATED_BODY()

public:
	UNPCVoiceSpeechComponent(const FObjectInitializer& ObjectInitializer);

	/** Speaks a line in its character's voice. Returns a ticket (0 if speech isn't available). */
	UFUNCTION(BlueprintCallable, Category = "NPCVoice")
	int64 SpeakLine(const FNPCVoiceLine& Line, float Speed = 1.f);

	/** voice: af_heart, af_bella, am_michael, am_fenrir, jf_alpha, jf_tebukuro, jm_kumo. */
	UFUNCTION(BlueprintCallable, Category = "NPCVoice")
	int64 Speak(const FString& Text, const FString& Voice, float Speed = 1.f);

	UFUNCTION(BlueprintCallable, Category = "NPCVoice")
	void StopSpeaking();

	UFUNCTION(BlueprintPure, Category = "NPCVoice")
	bool IsSpeaking() const;

	/** The viseme at the current playback position (sil, PP, FF, TH, DD, kk, CH, SS, RR, aa, E, ih, oh, ou, Y)
	 *  and its weight, for driving mouth shapes or morph targets. */
	UFUNCTION(BlueprintPure, Category = "NPCVoice")
	FName GetCurrentViseme(float& Weight) const;

	UPROPERTY(BlueprintAssignable, Category = "NPCVoice")
	FNPCVoiceSpeechFinished OnSpeechFinished;

	virtual void TickComponent(float DeltaTime, ELevelTick TickType, FActorComponentTickFunction* ThisTickFunction) override;

protected:
	virtual bool Init(int32& SampleRate) override;
	virtual int32 OnGenerateAudio(float* OutAudio, int32 NumSamples) override;

private:
	struct FViseme { FName Name; double Start; double End; float Weight; };
	// One line's audio, filled by SDK threads and drained by the audio render thread.
	struct FStream
	{
		std::mutex Mutex;
		std::deque<float> Samples;
		std::vector<FViseme> Visemes;
		std::atomic<int64_t> Played{0};
		bool bFinished = false;     // the SDK sent its last chunk (or failed)
		int Status = 0;
		bool bReported = false;
		uint64_t Ticket = 0;
	};

	std::shared_ptr<FStream> Current;
	mutable std::mutex CurrentMutex;
};
