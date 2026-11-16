# AGENTS.md — setting up and extending AICall

Instructions for a coding agent (Claude Code, Codex, …) helping a user install, configure or extend AICall.

## Install and verify

1. Run the installer: `curl -fsSL https://raw.githubusercontent.com/gyujeongion/aicall/main/install.sh | zsh`
   It needs the user's Mac password once (to install the audio device) — let the user type it.
2. Run `aicall doctor`. Each `✗` line prints the command that fixes it. Repeat until it says ready.
   `aicall doctor --json` gives the same list as `[{id, name, ok, fix}]`.
3. Save the user's settings — ask the user for each value, never invent one:
   `aicall setup --key <OpenAI key> --name <name to introduce them by> --phone <their number>`
   The number may be in any format (`01012345678`, `+82 10 …`); it is stored as digits.
4. Permissions can only be granted by the user, in System Settings → Privacy & Security:
   **Accessibility**, **Screen & System Audio Recording** and **Microphone** for *AICall*.
5. Smoke test without a phone call: `aicall call 0 "say hello" --practice --follow` (uses the Mac mic and speakers).

Where things live:

| What | Path |
|---|---|
| API keys | `~/.config/aicall/.env` (`OPENAI_API_KEY=…`), mode 600 |
| Settings | `~/Library/Application Support/AICall/config.json` |
| Call transcripts / recordings | `~/Library/Application Support/AICall/calls/` |
| Source (installer) | `~/.local/share/aicall` |
| Python env | `~/.config/aicall/venv` |

## Settings (`config.json`)

| Key | Default | Meaning |
|---|---|---|
| `owner_name`, `owner_phone` | — | Who the AI calls for; used in prompts and to confirm "is this your number?" menus |
| `voice` | `live:gpt-live-1:voice_new` | Realtime voice model and voice. `voice_new` creates a voice from `voice_prompt` on first use |
| `voice_prompt` | Korean male voice description | Voice description for the custom voice |
| `llm` | `openai:gpt-6-luna` | Judge model that handles phone menus and decides when a call is done |
| `monitor` | `false` | Play call audio (both sides) on the Mac speakers. Off = transcript only |
| `record` | `false` | Keep a stereo `.m4a` per call |
| `stt`, `tts` | `deepgram`, `say:Yuna` | Only used by the older `--brain external` path, not by normal calls |

`aicall config --llm openai:<model>` changes the judge model.

## Voice providers

Normal calls use **GPT-Live**, a realtime speech-to-speech model (`live.py`). Keep it as the default: one model hears and speaks, so replies start in about a second. A speech-to-text → LLM → text-to-speech chain adds roughly 1–2 s per turn on a live call.

If the user still wants another provider, these are the seams:

- **Realtime voice session** — `live.py`, class `Session`: `run()` opens the websocket and streams 24 kHz mono PCM in (`tx`) and out (`rx` → `_route` → `_play`). A different realtime provider replaces `run`/`rx`/`tx`; the gate logic (`line()`, `_utterance`, `_release`) stays.
- **Phone-menu judge** — `agent.py`, `Call.decide` and `openai()`: an OpenAI-compatible chat-completions call with tool calling. Any compatible endpoint works by changing `openai()`'s host.
- **Legacy STT/TTS** — `arsear.swift` (Deepgram streaming) and `Call.say` in `agent.py` (`say:` macOS voices or `openai:` TTS).

Run `python3 tests/test_live_gate.py` and `python3 tests/test_offline.py` after any change.

## Language

Prompts are Korean: `SYSTEM` and `HYBRID` in `agent.py`, `INSTRUCTIONS` in `live.py`. The person/menu keyword lists (`ARS_WORDS`, `UNANSWERED`, `KEYPAD_CUE`, `NOT_PERSON`) are at the top of `live.py`. Translate both together, and add phone-menu transcripts in the new language to `tests/test_offline.py`.

## Rules the code enforces — keep them

- The AI never speaks or types resident ID, birth date, card/account numbers or passwords; it hands off to the user.
- No payments or commitments; off-script ends as `needs_user`.
- Calls only from the user's own line; no caller-ID spoofing.
