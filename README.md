# AICall

An AI that places phone calls **from your own iPhone number** on a Mac — it navigates phone menus (ARS/IVR) by pressing keys, and talks to people when a person picks up.

Type a number and what you want done ("opt out of marketing texts", "ask if there's a table for two at 7pm Saturday"). AICall dials through the macOS Phone app (iPhone Continuity), listens to the call, and:

- **Automated menu** → a judge model listens to each prompt and presses the right keypad digit (it can press while the prompt is still playing, which many IVRs require).
- **Person** → a realtime voice model (GPT-Live) holds the conversation, introduces itself as an AI assistant calling on your behalf, and hangs up when the job is done.

It tells the two apart on its own, and switches back to keypad mode if a "person" turns out to be a menu ("press 1 to…"). Every call leaves a transcript, and optionally a stereo recording (left = them, right = AI).

> Prompts and the voice are Korean today. The structure is language-agnostic; see [Customizing](#customizing).

## Requirements

- Apple Silicon Mac, macOS 27 (uses the built-in Phone app), an iPhone signed in for Continuity calling
- Xcode command line tools (`swiftc`, `xcodebuild`)
- `brew install sox ffmpeg`
- Python 3 with `pip install websockets`
- OpenAI API key (GPT-Live voice + judge model). Deepgram key only for the legacy non-realtime path.

## Install

```bash
git clone <this repo> aicall && cd aicall

# 1. Virtual mic/speaker pair the Phone app uses as its microphone (builds BlackHole from source)
vmic/build_driver.sh
sudo cp -R vmic/AICall.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod

# 2. The app (ad-hoc signed by default; set AICALL_SIGN_ID to your Developer ID to keep permissions across rebuilds)
./build_app.sh && cp -R dist/AICall.app /Applications/

# 3. Keys and your identity
mkdir -p ~/.config/aicall && echo 'OPENAI_API_KEY=sk-...' > ~/.config/aicall/.env
mkdir -p ~/Library/Application\ Support/AICall
cp config.example.json ~/Library/Application\ Support/AICall/config.json   # then edit owner_name / owner_phone
```

First launch asks for **Accessibility**, **Screen & System Audio Recording** and **Microphone** permissions.

## Use

From the app: enter a number and a purpose, press call.

From a terminal or an agent:

```bash
./aicall call 0212345678 "Ask if a table for 2 is free Sat 7pm. If conditions differ, end(needs_user). After the goodbye, end_call(success)." --follow
./aicall events --since 0 --wait 10     # JSON event stream
./aicall press 1 | ./aicall say "..." | ./aicall end success "summary"
```

`--brain external` hands every decision to your own agent through `events` / `press` / `say` / `end`. `mcp_server.py` exposes the same as MCP tools (`call_start`, `call_events`, `call_press`, `call_say`, `call_end`, `call_status`).

Logs: `~/Library/Application Support/AICall/calls/*.md`. Set `"record": true` in `config.json` to also keep a `.m4a` per call.

## Safety rules built in

- The AI says up front that it is an AI calling on your behalf.
- It only ever shares your name and phone number. Resident ID, birth date, card, account numbers and passwords are never spoken or typed; when asked, it hands off to you with a notification (`--handoff`, on by default).
- No payments, deposits or contract commitments; anything off-script ends as `needs_user` with a summary.
- Calls go out on your own line only. There is no caller-ID spoofing.
- Voicemail / phone-off / busy announcements end the call as `failed` without speaking.

You are responsible for the laws where you call from and to — AI-voice disclosure, call recording consent, and telemarketing rules vary by country. Recording is off by default.

## Tests

```bash
python3 tests/test_live_gate.py      # person/menu gate, timing, hang-up handling (offline)
python3 tests/test_runtime.py        # engine runtime (offline)
python3 tests/test_offline.py        # replays real IVR transcripts against the live judge model (needs OPENAI_API_KEY)
```

## How it works

| File | Role |
|---|---|
| `agent.py` | Call engine: dial, event log, judge model for menus, control port, CLI request handling |
| `live.py` | Realtime voice session: person/menu gate, voice output timing, hang-up and voicemail detection, recording |
| `arsear.swift` | Taps call audio (ScreenCaptureKit) and streams PCM |
| `phonectl.swift` / `phone.py` | Drives the Phone app via Accessibility: dial, keypad, hang up, mic selection |
| `app/AICall.swift` | Mac app (call screen) |
| `aicall`, `mcp_server.py` | CLI and MCP front-ends |
| `vmic/build_driver.sh` | Builds the `AICall Mic` / `AICall Speaker` device pair |

## Customizing

- Your identity: `owner_name`, `owner_phone` in `config.json` (used in prompts and for "is this your number?" checks).
- Voice: `voice` / `voice_prompt` in `config.json`.
- Language: the system prompts are `SYSTEM` / `HYBRID` in `agent.py` and `INSTRUCTIONS` in `live.py`; the menu/person keyword lists are at the top of `live.py`.

## License

MIT — see [LICENSE](LICENSE). The virtual audio device is built from [BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPL-3.0), which is fetched at build time and not included in this repository.
