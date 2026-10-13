#!/usr/bin/env python3
"""Golden English phonemes from misaki (the G2P Kokoro was trained with) for the
native EnglishG2P parity test. Needs tools/requirements-dev.txt:
  python3 -I tools/make_g2p_golden.py Tests/NPCSpeechTests/Fixtures/misaki-en-golden.json
"""
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import kokoro_engine  # noqa: E402
kokoro_engine.setup_imports()
from misaki import en  # noqa: E402

g2p = en.G2P(trf=False, british=False, fallback=None)
corpus = [
    # NPC dialogue in the style the dialogue models produce.
    "Evening, love. A room costs three silver marks a night.",
    "Move along. The watch is busy.",
    "Now why would I tell you that?",
    "Welcome to the Gull & Lantern. Mind the puddle.",
    "No writ, no passage.",
    "The east gate closes at the eighth bell, and nobody passes after without a writ.",
    "The merchant ship Saltwren is three days overdue.",
    "I'd rather have a full house than a quiet night. What's your story, love?",
    "Oh, a fellow in need of a hand? Well, I can haul a few crates to the docks.",
    "You think I'm some robot? Well, I'm Marta, and I've heard every lie twice.",
    "The harbor is a graveyard of rusted hulls and rotting timber, Captain.",
    "Don't you dare! I won't let you near the lighthouse.",
    "It's the highest tide in ten years; we're all going to get wet.",
    "Take the key, then. Room four, up the stairs and to the left.",
    "She's been gone since the storm on the 3rd of May.",
    "That'll be 12 marks, or 5 if you help me with the barrels.",
    "In 1999, the old king closed the harbor for 100 days.",
    "It costs $3.50, not £20.",
    "We need 2,500 men by the 21st.",
    "He read the letter yesterday, and now I read it every night.",
    "I live by the docks; the music is live tonight.",
    "Lead the way, but watch out for the lead pipes.",
    "They refuse to take the refuse to the dump.",
    "The wind was too strong to wind the sails.",
    "I object to that object on the table.",
    "Close the door, the storm is close.",
    "Tamsin Reed knows more than she says.",
    "Captain Rhys Hallow guards the east gate.",
    "Smuggler, sailor, traveler: all are welcome at the inn.",
    "Hmm... I'm not sure. Ask the harbormaster.",
    "Well—that's not something I'd talk about.",
    "\"Halt!\" he shouted. \"Who goes there?\"",
    "You've got until the tide turns, mate.",
    "The Saltwren's cargo isn't mine to sell.",
    "My grandmother's grandmother built this inn.",
    "He's running, jumping, and climbing over the walls.",
    "The guards were stopped, questioned, and released.",
    "Please, sir, it's raining cats and dogs out there.",
    "Can't you see I'm busy? Come back tomorrow.",
    "What brings you to Harbor Town, stranger?",
]
out = [{"text": t, "phonemes": g2p(t)[0]} for t in corpus]
json.dump({"source": "misaki 0.9.4 en.G2P(trf=False, british=False, fallback=None) + en_core_web_sm 3.8.0", "lines": out},
          open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
for o in out[:6]: print(o["phonemes"])
print("unknown:", sum("❓" in o["phonemes"] for o in out))
