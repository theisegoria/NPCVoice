#include "NPCVoiceSpeechComponent.h"

#include "NPCVoiceSubsystem.h"
#include "Dom/JsonObject.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"

static constexpr int32 NPCVoiceSampleRate = 24000;

UNPCVoiceSpeechComponent::UNPCVoiceSpeechComponent(const FObjectInitializer& ObjectInitializer)
	: Super(ObjectInitializer)
{
	PrimaryComponentTick.bCanEverTick = true;
	bAutoActivate = false;
}

bool UNPCVoiceSpeechComponent::Init(int32& SampleRate)
{
	SampleRate = NPCVoiceSampleRate;
	NumChannels = 1;
	return true;
}

int32 UNPCVoiceSpeechComponent::OnGenerateAudio(float* OutAudio, int32 NumSamples)
{
	std::shared_ptr<FStream> Stream;
	{
		std::lock_guard<std::mutex> Lock(CurrentMutex);
		Stream = Current;
	}
	int32 Written = 0;
	if (Stream)
	{
		std::lock_guard<std::mutex> Lock(Stream->Mutex);
		while (Written < NumSamples && !Stream->Samples.empty())
		{
			OutAudio[Written++] = Stream->Samples.front();
			Stream->Samples.pop_front();
		}
		Stream->Played += Written;
	}
	for (int32 I = Written; I < NumSamples; ++I) OutAudio[I] = 0.f;   // silence while waiting for the next chunk
	return NumSamples;
}

int64 UNPCVoiceSpeechComponent::SpeakLine(const FNPCVoiceLine& Line, float Speed)
{
	return Speak(Line.Text, Line.Voice, Speed);
}

int64 UNPCVoiceSpeechComponent::Speak(const FString& Text, const FString& Voice, float Speed)
{
	UWorld* World = GetWorld();
	UGameInstance* GameInstance = World ? World->GetGameInstance() : nullptr;
	UNPCVoiceSubsystem* NPCVoice = GameInstance ? GameInstance->GetSubsystem<UNPCVoiceSubsystem>() : nullptr;
	const npcvoice::Session* Session = NPCVoice ? NPCVoice->GetSession() : nullptr;
	if (!Session || !Session->speech()) return 0;

	StopSpeaking();
	std::shared_ptr<FStream> Stream = std::make_shared<FStream>();
	std::string Error;
	const uint64_t Ticket = Session->speech()->submit(
		std::string(TCHAR_TO_UTF8(*Text)), std::string(TCHAR_TO_UTF8(*Voice)), Speed,
		[Stream](uint64_t, const npcvoice::SpeechChunk& Chunk)
		{
			std::vector<FViseme> Visemes;
			TSharedPtr<FJsonObject> Info;
			const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(FString(UTF8_TO_TCHAR(std::string(Chunk.infoJson).c_str())));
			const TArray<TSharedPtr<FJsonValue>>* List = nullptr;
			if (FJsonSerializer::Deserialize(Reader, Info) && Info.IsValid() && Info->TryGetArrayField(TEXT("visemes"), List))
			{
				for (const TSharedPtr<FJsonValue>& V : *List)
				{
					const TSharedPtr<FJsonObject> O = V->AsObject();
					if (O.IsValid())
					{
						Visemes.push_back({FName(*O->GetStringField(TEXT("viseme"))), O->GetNumberField(TEXT("start")),
						                   O->GetNumberField(TEXT("end")), static_cast<float>(O->GetNumberField(TEXT("weight")))});
					}
				}
			}
			std::lock_guard<std::mutex> Lock(Stream->Mutex);
			Stream->Samples.insert(Stream->Samples.end(), Chunk.samples, Chunk.samples + Chunk.sampleCount);
			Stream->Visemes.insert(Stream->Visemes.end(), Visemes.begin(), Visemes.end());
		},
		[Stream](uint64_t, int Status, std::string_view)
		{
			std::lock_guard<std::mutex> Lock(Stream->Mutex);
			Stream->bFinished = true;
			Stream->Status = Status;
		},
		&Error);
	if (!Ticket) return 0;
	Stream->Ticket = Ticket;
	{
		std::lock_guard<std::mutex> Lock(CurrentMutex);
		Current = Stream;
	}
	Start();
	return static_cast<int64>(Ticket);
}

void UNPCVoiceSpeechComponent::StopSpeaking()
{
	std::shared_ptr<FStream> Old;
	{
		std::lock_guard<std::mutex> Lock(CurrentMutex);
		Old.swap(Current);
	}
	if (!Old) return;
	UWorld* World = GetWorld();
	UGameInstance* GameInstance = World ? World->GetGameInstance() : nullptr;
	if (UNPCVoiceSubsystem* NPCVoice = GameInstance ? GameInstance->GetSubsystem<UNPCVoiceSubsystem>() : nullptr)
	{
		if (const npcvoice::Session* Session = NPCVoice->GetSession())
		{
			if (Session->speech()) Session->speech()->cancel(Old->Ticket);
		}
	}
	OnSpeechFinished.Broadcast(static_cast<int64>(Old->Ticket), false);
}

bool UNPCVoiceSpeechComponent::IsSpeaking() const
{
	std::lock_guard<std::mutex> Lock(CurrentMutex);
	return Current != nullptr;
}

FName UNPCVoiceSpeechComponent::GetCurrentViseme(float& Weight) const
{
	Weight = 0.f;
	std::shared_ptr<FStream> Stream;
	{
		std::lock_guard<std::mutex> Lock(CurrentMutex);
		Stream = Current;
	}
	if (!Stream) return FName(TEXT("sil"));
	const double Time = static_cast<double>(Stream->Played.load()) / NPCVoiceSampleRate;
	std::lock_guard<std::mutex> Lock(Stream->Mutex);
	for (const FViseme& V : Stream->Visemes)
	{
		if (Time >= V.Start && Time < V.End)
		{
			Weight = V.Weight;
			return V.Name;
		}
	}
	return FName(TEXT("sil"));
}

void UNPCVoiceSpeechComponent::TickComponent(float DeltaTime, ELevelTick TickType, FActorComponentTickFunction* ThisTickFunction)
{
	Super::TickComponent(DeltaTime, TickType, ThisTickFunction);
	std::shared_ptr<FStream> Stream;
	{
		std::lock_guard<std::mutex> Lock(CurrentMutex);
		Stream = Current;
	}
	if (!Stream) return;
	bool bDone = false, bCompleted = false;
	{
		std::lock_guard<std::mutex> Lock(Stream->Mutex);
		// Finished once the SDK is done and the audio thread has played every sample.
		if (Stream->bFinished && Stream->Samples.empty() && !Stream->bReported)
		{
			Stream->bReported = true;
			bDone = true;
			bCompleted = Stream->Status == NPC_SPEECH_DONE;
		}
	}
	if (bDone)
	{
		{
			std::lock_guard<std::mutex> Lock(CurrentMutex);
			if (Current == Stream) Current.reset();
		}
		Stop();
		OnSpeechFinished.Broadcast(static_cast<int64>(Stream->Ticket), bCompleted);
	}
}
