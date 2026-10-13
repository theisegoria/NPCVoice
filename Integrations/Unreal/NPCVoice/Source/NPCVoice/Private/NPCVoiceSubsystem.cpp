#include "NPCVoiceSubsystem.h"

#include "Async/Async.h"
#include "Dom/JsonObject.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"

namespace
{
std::string ToUtf8(const FString& S) { return std::string(TCHAR_TO_UTF8(*S)); }
FString FromUtf8(const std::string& S) { return FString(UTF8_TO_TCHAR(S.c_str())); }

std::vector<std::string> ToUtf8(const TArray<FString>& Items)
{
	std::vector<std::string> Out;
	for (const FString& I : Items) Out.push_back(ToUtf8(I));
	return Out;
}

FString Absolute(const FString& Path)
{
	return FPaths::IsRelative(Path) ? FPaths::ConvertRelativePathToFull(FPaths::ProjectDir() / Path) : Path;
}

FNPCVoiceLine ParseResult(const TSharedPtr<FJsonObject>& R)
{
	FNPCVoiceLine L;
	L.Ticket = static_cast<int64>(R->GetNumberField(TEXT("ticket")));
	L.bCancelled = R->GetStringField(TEXT("status")) == TEXT("cancelled");
	L.Source = R->GetStringField(TEXT("source"));
	L.FallbackReason = R->GetStringField(TEXT("fallbackReason"));
	L.LatencyMs = static_cast<float>(R->GetNumberField(TEXT("latencyMs")));
	const TSharedPtr<FJsonObject>* Line = nullptr;
	if (R->TryGetObjectField(TEXT("line"), Line))
	{
		L.Character = (*Line)->GetStringField(TEXT("character"));
		L.Text = (*Line)->GetStringField(TEXT("text"));
		L.Emotion = (*Line)->GetStringField(TEXT("emotion"));
		L.Intent = (*Line)->GetStringField(TEXT("intent"));
		L.Voice = (*Line)->GetStringField(TEXT("voice"));
		L.Language = (*Line)->GetStringField(TEXT("language"));
		const TArray<TSharedPtr<FJsonValue>>* Commands = nullptr;
		if ((*Line)->TryGetArrayField(TEXT("commands"), Commands))
		{
			for (const TSharedPtr<FJsonValue>& C : *Commands)
			{
				const TSharedPtr<FJsonObject> O = C->AsObject();
				if (!O.IsValid()) continue;
				FNPCVoiceCommand Command;
				Command.Kind = O->GetStringField(TEXT("kind"));
				Command.Target = O->GetStringField(TEXT("target"));
				L.Commands.Add(Command);
			}
		}
	}
	return L;
}
} // namespace

void UNPCVoiceSubsystem::Deinitialize()
{
	// The opening thread holds its own reference to OpenState; nothing to join.
	std::lock_guard<std::mutex> Lock(OpenState->Mutex);
	OpenState->Session.reset();
	Super::Deinitialize();
}

void UNPCVoiceSubsystem::Open(const FNPCVoiceSettings& Settings)
{
	if (bOpening || IsOpen()) return;
	bOpening = true;
	npcvoice::Session::Options Options;
	const FString Project = Absolute(Settings.ProjectPath);
	if (Project.EndsWith(TEXT(".json")))
	{
		FString Json;   // FFileHelper reads through the platform file, so this works inside a .pak
		if (!FFileHelper::LoadFileToString(Json, *Project))
		{
			bOpening = false;
			OnOpened.Broadcast(FString::Printf(TEXT("can't read %s"), *Project));
			return;
		}
		Options.projectJson = ToUtf8(Json);
	}
	else
	{
		Options.projectPath = ToUtf8(Project);
	}
	Options.backend = ToUtf8(Settings.Backend);
	Options.backendConfigJson = ToUtf8(Settings.BackendConfigJson);
	Options.modelsDir = Settings.ModelsDir.IsEmpty() ? std::string() : ToUtf8(Absolute(Settings.ModelsDir));
	Options.speech = Settings.bSpeech;

	std::shared_ptr<FOpenState> State = OpenState;
	Async(EAsyncExecution::Thread, [State, Options]()
	{
		std::string Error;
		std::unique_ptr<npcvoice::Session> Session = npcvoice::Session::open(Options, &Error);
		std::lock_guard<std::mutex> Lock(State->Mutex);
		State->Error = Session ? std::string() : (Error.empty() ? std::string("could not open NPCVoice") : Error);
		State->Session = std::move(Session);
		State->bDone = true;
	});
}

bool UNPCVoiceSubsystem::IsOpen() const
{
	std::lock_guard<std::mutex> Lock(OpenState->Mutex);
	return OpenState->Session != nullptr;
}

const npcvoice::Session* UNPCVoiceSubsystem::GetSession() const
{
	std::lock_guard<std::mutex> Lock(OpenState->Mutex);
	return OpenState->Session.get();
}

int64 UNPCVoiceSubsystem::Submit(npcvoice::Call Call, const FNPCVoiceGameState& State)
{
	const npcvoice::Session* Session = GetSession();
	if (!Session)
	{
		OnFailed.Broadcast(TEXT("NPCVoice is not open yet (wait for OnOpened)"));
		return 0;
	}
	if (State.Flags.Num()) Call.flags(ToUtf8(State.Flags));
	if (State.Memories.Num()) Call.memories(ToUtf8(State.Memories));
	if (State.Topics.Num()) Call.topics(ToUtf8(State.Topics));
	if (!State.Location.IsEmpty()) Call.location(ToUtf8(State.Location));
	if (!State.Objective.IsEmpty()) Call.objective(ToUtf8(State.Objective));
	if (!State.Mood.IsEmpty()) Call.mood(ToUtf8(State.Mood));
	if (State.DeadlineMs > 0) Call.deadlineMs(static_cast<uint32_t>(State.DeadlineMs));
	std::string Error;
	const uint64_t Ticket = Session->say(Call, &Error);
	if (!Ticket) OnFailed.Broadcast(FromUtf8(Error));
	return static_cast<int64>(Ticket);
}

int64 UNPCVoiceSubsystem::Say(const FString& Character, const FString& PlayerLine, const FNPCVoiceGameState& State)
{
	return Submit(npcvoice::Call(ToUtf8(Character)).player(ToUtf8(PlayerLine)), State);
}

int64 UNPCVoiceSubsystem::React(const FString& Character, const FString& Event, const FNPCVoiceGameState& State)
{
	return Submit(npcvoice::Call(ToUtf8(Character)).event(ToUtf8(Event)), State);
}

bool UNPCVoiceSubsystem::Cancel(int64 Ticket)
{
	const npcvoice::Session* Session = GetSession();
	return Session && Session->service().cancel(static_cast<uint64_t>(Ticket));
}

void UNPCVoiceSubsystem::UnloadModel()
{
	if (const npcvoice::Session* Session = GetSession()) Session->backend().unload();
}

void UNPCVoiceSubsystem::PrewarmModel()
{
	if (const npcvoice::Session* Session = GetSession()) Session->backend().prewarm();
}

void UNPCVoiceSubsystem::Tick(float)
{
	if (bOpening)
	{
		bool bDone = false;
		std::string Error;
		{
			std::lock_guard<std::mutex> Lock(OpenState->Mutex);
			bDone = OpenState->bDone;
			Error = OpenState->Error;
		}
		if (bDone)
		{
			bOpening = false;
			OnOpened.Broadcast(FromUtf8(Error));
		}
	}
	const npcvoice::Session* Session = GetSession();
	if (!Session) return;
	const std::string Done = Session->service().drain();   // non-blocking
	if (Done.size() <= 2) return;
	TArray<TSharedPtr<FJsonValue>> Results;
	const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(FromUtf8(Done));
	if (!FJsonSerializer::Deserialize(Reader, Results)) return;
	for (const TSharedPtr<FJsonValue>& V : Results)
	{
		const TSharedPtr<FJsonObject> R = V->AsObject();
		if (R.IsValid()) OnLine.Broadcast(ParseResult(R));
	}
}
