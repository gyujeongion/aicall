#!/usr/bin/env python3
"""AICall 통화 엔진 — 내 번호로 전화 걸어 듣고(STT) 판단하고(LLM 또는 외부 에이전트) 누르거나 말한다(TTS).

  agent.py <번호> <목적> [--speak] [--handoff] [--brain auto|external]

  brain=auto      : 엔진 안의 LLM(설정의 llm)이 판단한다. 앱 단독 사용.
  brain=external  : 엔진은 듣고 실행만 한다. 판단은 제어 포트로 붙은 에이전트(클로드 코드·Codex·agy)가 한다.
제어 포트: 127.0.0.1:<port> (state.json에 기록)
  GET  /events?since=N&wait=초   상대·AI 발화와 상태 이벤트
  POST /press {"keys":"1"}  /say {"text":"..."}  /end {"outcome":"success","summary":"..."}
설정: <DATA>/config.json  {"stt":"deepgram","llm":"openai:gpt-6-luna","tts":"say:Yuna"}
"""
import argparse, atexit, json, os, queue, re, signal, subprocess, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.environ.get("AICALL_DATA") or HERE
os.makedirs(os.path.join(DATA, "calls"), exist_ok=True)
os.chdir(DATA)
BIN = lambda n: os.path.join(HERE, n)
MAX_CALL = 300
DEFAULTS = {"stt": "deepgram", "llm": "openai:gpt-6-luna", "tts": "say:Yuna", "voice": "live:gpt-live-1:voice_new",   # 처음 쓰면 voice_prompt로 내 API 프로젝트에 목소리를 만들어 config에 저장한다(ensure_voice)
            "voice_prompt": "A native Korean man in his early thirties from Seoul. Standard Seoul Korean pronunciation, natural native rhythm and intonation, no foreign accent at all. Calm, clear, mid-low pitch, polite and conversational, like a capable personal assistant on the phone."}

SYSTEM = """너는 {owner_name}의 AI 전화 비서다. {owner_name} 본인 휴대폰 번호로 상대에게 전화를 건 상태다.
통화 받아쓰기(실시간, 오타·끊김 있음)를 읽고 지금 해야 할 일을 판단해 도구를 정확히 하나 호출한다. 글로 답하지 말고 반드시 도구만 부른다.
도구: press_keypad(키패드 입력) · say(말하기) · handoff(사용자에게 넘기기) · end_call(통화 종료) · keep_listening(더 듣기)
판단 원칙:
- ARS가 목적에 맞는 선택지를 안내하면(예: "수신 차단하시려면 1번을 눌러주세요") 안내가 끝나기 전에 press_keypad로 그 번호를 누른다. ARS는 안내 도중에도 입력을 받고, 끝난 뒤 누르면 "입력되지 않았습니다"로 끊기는 일이 많다.
- 번호가 여럿이면(상담원 1번, 수신거부 2번…) 목적에 맞는 번호 하나만 고른다. 선택지가 나열되는 중이라 목록이 끝나지 않았으면, 목적에 정확히 맞는 항목('수신거부 등록'·'수신 차단')이 들릴 때만 누른다. 조회·해지·철회·상담원·방문판매 거부 같은 비슷한 항목은 누르지 않는다. 광고·마케팅 수신거부가 목적이면 상담원·서비스 안내·가입 번호는 누르지 않는다.
- 받아쓰기 오류를 읽어낸다("수신 커브·수신가부"=수신거부, "한 번·일 번"=1번, "이 번"=2번).
- 번호 확인("010-… 번이 맞으면 1번")은 읽어준 번호가 내 번호 {owner_phone}과 일치할 때만 맞다고 누른다. 숫자는 한글로도 읽힌다({owner_phone_ko} = {owner_phone}). 다르거나 확신이 없으면 누르지 않는다.
- 안내가 끝나지 않았거나("말하는 중") 서론이면 keep_listening. 없는 번호·서비스 점검처럼 진행이 불가능한 안내면 end_call(failed). 확신이 없으면 keep_listening.
- 같은 안내 문장이 반복되어도 이미 누른 키를 다시 누르지 않는다.
- 내 휴대폰 번호 입력을 요구하면 press_keypad로 {owner_digits}을 누른다("우물정자·샵"을 누르라고 하면 끝에 #).
- 처리 완료 안내("정상적으로 처리되었습니다")를 들으면 end_call(success). 진행이 불가능하거나 사람 판단이 필요하면 end_call(needs_user)·failed.
- 사람이 받아 대화하는 경우에만 say(말하기가 켜짐일 때). 전화 말투로 짧게 한두 문장만, 질문은 한 번에 하나만 한다. 첫 마디는 "안녕하세요, {owner_name} 님을 대신해 전화드린 AI 비서입니다." 후 용건. 말하기 꺼짐이면 say 금지.
- '알려도 되는 정보' 밖 개인정보(주민번호·생년월일·카드·계좌·비밀번호·주소)는 말하거나 누르지 않는다. 요구받으면 넘겨받기 켜짐일 때 handoff, 꺼짐이면 end_call(needs_user). 결제·계약 확정 금지. 조건이 다른 제안은 end_call(needs_user)+요약.
목적: {task}
말하기: {speak} / 넘겨받기: {handoff}
알려도 되는 정보: 이름 {owner_name}, 연락처 {owner_phone} {extra}"""

TOOLS = [
    {"type": "function", "function": {"name": "press_keypad", "description": "통화 중 키패드 숫자를 누른다. 예: ARS가 '수신거부는 1번'이라고 하면 keys='1'.",
        "parameters": {"type": "object", "properties": {"keys": {"type": "string", "description": "누를 숫자·*·# (보통 한 글자)"}}, "required": ["keys"]}}},
    {"type": "function", "function": {"name": "say", "description": "상대(사람)에게 말한다. 말하기가 켜져 있을 때만.",
        "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}},
    {"type": "function", "function": {"name": "handoff", "description": "본인이 직접 해야 하는 입력(주민번호 등)을 요구받았을 때 사용자에게 넘긴다.",
        "parameters": {"type": "object", "properties": {"reason": {"type": "string"}}, "required": ["reason"]}}},
    {"type": "function", "function": {"name": "end_call", "description": "통화를 끝낸다.",
        "parameters": {"type": "object", "properties": {"outcome": {"type": "string", "enum": ["success", "failed", "needs_user"]},
                                                        "summary": {"type": "string", "description": "결과를 사용자에게 알리는 한 문장. 해요체. 예: 수신거부가 처리됐어요."}}, "required": ["outcome", "summary"]}}},
    {"type": "function", "function": {"name": "keep_listening", "description": "아직 행동할 때가 아니다. 더 듣는다.",
        "parameters": {"type": "object", "properties": {}, "required": []}}},
]


HUMAN_TOOL = {"type": "function", "function": {"name": "human_answered", "description": "상대가 녹음·자동 안내가 아니라 사람이다.", "parameters": {"type": "object", "properties": {}, "required": []}}}
HYBRID = """
[이 통화의 역할 분담] 너는 ARS만 처리한다. 사람과의 대화는 음성 모델이 맡는다.
- 상대가 사람이면(여보세요, 네 ○○입니다, 되묻는 말, 자연스러운 대화) human_answered만 부르고 say는 쓰지 않는다. 안내 멘트·메뉴·음성봇(AI 상담사 포함)은 사람이 아니다. 이름·상호·용건 없이 "안녕하십니까"만 들리면 안내의 시작일 수 있으니 keep_listening으로 더 듣는다. human_answered는 되돌릴 수 없다.
- ARS가 음성으로 답하라고 하면("말씀해 주세요") 안내가 끝난 뒤 say로 안내가 예로 든 표현이나 용건을 짧은 한 구절만 말한다. 그 외에 ARS에게 say 하지 않는다.
- 입력이 안 된 것 같으면 안내를 더 듣고 다시 누른다. 키패드·연결 같은 기술 문제로 사용자에게 부탁하지 않는다. handoff는 주민번호처럼 본인만 넣을 수 있는 정보를 요구받을 때만 쓴다.
"""


def env_key(name, files):
    if os.environ.get(name):
        return os.environ[name]
    for f in files:
        f = os.path.expanduser(f)
        if not os.path.exists(f):
            continue
        if f.endswith(".json"):
            d = json.load(open(f)); return d.get("api_key") or d.get("key") or next(v for v in d.values() if isinstance(v, str))
        for line in open(f):
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip('"')
    return ""


KEY_FILES = [os.environ.get("AICALL_ENV_FILE", ""), os.path.join(DATA, ".env"), "~/.config/aicall/.env"]   # 키는 환경변수 → 이 파일들 순서로 찾는다
OPENAI = env_key("OPENAI_API_KEY", KEY_FILES)
DEEPGRAM = env_key("DEEPGRAM_API_KEY", KEY_FILES + ["~/.config/aicall/deepgram.json"])


_tl = threading.local()


def openai(path, body, raw=False):
    """스레드별로 HTTPS 연결을 재사용한다 (판단마다 새 연결을 맺으면 소켓이 고갈된다). 실패하면 재연결해 두 번 더 시도."""
    import http.client
    data = json.dumps(body).encode()
    hdr = {"Authorization": f"Bearer {OPENAI}", "Content-Type": "application/json"}
    err = None
    for _ in range(3):
        try:
            c = getattr(_tl, "c", None)
            if c is None:
                c = _tl.c = http.client.HTTPSConnection("api.openai.com", timeout=20)
            c.request("POST", f"/v1/{path}", data, hdr)
            resp = c.getresponse(); r = resp.read()
            if resp.status >= 400:
                raise RuntimeError(f"HTTP {resp.status} {r[:80]!r}")
            return r if raw else json.loads(r)
        except Exception as e:  # noqa: BLE001
            err = e; _tl.c = None; time.sleep(0.4)
    raise err



KO_DIGITS = "공일이삼사오육칠팔구"


def owner_fields(cfg):
    """설정의 사용자 이름·번호를 지시문에 넣을 꼴로 만든다. config.json: {"owner_name": "홍길동", "owner_phone": "010-1234-5678"}"""
    name, ph = (cfg.get("owner_name") or "").strip(), (cfg.get("owner_phone") or "").strip()
    if not name or not re.sub(r"\D", "", ph):
        raise SystemExit("config.json에 owner_name·owner_phone을 넣어 주세요 (예: {\"owner_name\": \"홍길동\", \"owner_phone\": \"010-1234-5678\"})")
    digits = re.sub(r"\D", "", ph)
    groups = re.findall(r"\d+", ph) if "-" in ph or " " in ph else [digits]
    return {"owner_name": name, "owner_phone": ph, "owner_digits": digits,
            "owner_phone_ko": " ".join("".join(KO_DIGITS[int(c)] for c in g) for g in groups)}


def personalize(text, owner):
    for k, v in owner.items():
        text = text.replace("{" + k + "}", v)
    return text


import phone

SPEAK_DEV = "AICall Speaker"   # AI 음성을 내보내는 가상 장치 (vmic/AICall.driver). 여기 쓴 소리가 AICall Mic로 나온다
PHONE_MIC = "AICall Mic"       # 전화 앱 마이크. 입력 전용 1채널 (BlackHole 16ch는 통화 엔진이 상대에게 보내지 않았다, 11-13 실측)


class Call:
    def __init__(self, a, cfg):
        self.a, self.cfg = a, cfg
        self.num = re.sub(r"\D", "", a.number)
        self.events, self.cv = [], threading.Condition()
        self.convo, self.presses = [], []
        self.speaking_until = 0.0
        self.done = threading.Event()
        self.finished = threading.Event()
        self.cancelled = False
        self.end_lock = threading.RLock()
        self.log_lock = threading.RLock()
        self.outcome, self.summary = "timeout", "최대 통화 시간 초과"
        self.logp = f"calls/{time.strftime('%y%m%d_%H%M%S')}_{self.num}.md"
        self.logf = open(self.logp, "w")
        self.logf.write(f"# 통화 {self.num} ({time.strftime('%F %T')})\n\n용건: {a.task}\n\n")
        self.owner = owner_fields(cfg)
        self.system = (personalize(SYSTEM, self.owner).replace("{task}", a.task).replace("{extra}", a.extra)
                       .replace("{speak}", "켜짐" if a.speak else "꺼짐")
                       .replace("{handoff}", "켜짐" if a.handoff else "꺼짐"))
        self.hybrid = a.speak and a.brain == "auto" and not a.practice and not getattr(a, "replay", None)
        self.tools = TOOLS + [HUMAN_TOOL] if self.hybrid else TOOLS
        if self.hybrid:
            self.system += HYBRID
        self.human, self.ars = False, False    # 상대 종류 판단 결과 (live.py가 음성 출구를 정할 때 본다)
        self.live, self.last_speech = "", time.time()
        self.cue_hit = self.cue_used = self.final_pending = self.pressed_in_utterance = False
        self.t_heard = 0.0
        self.silence = 0.6 if a.speak else SILENCE_SEC   # 사람과 대화할 땐 빨리 받는다
        self.lock = threading.Lock()

    # ---- 이벤트 (앱 화면·CLI·MCP가 같은 것을 본다)
    def emit(self, tag, text):
        stamp = time.strftime("%H:%M:%S")
        print(f"{stamp} {tag}: {text}", flush=True)
        with self.log_lock:
            if self.logf.closed:
                return
            self.logf.write(f"- {stamp} {tag}: {text}\n"); self.logf.flush()
        if tag in ("상대", "AI말함", "AI누름"):
            self.convo.append(f"{tag}: {text}")
        with self.cv:
            self.events.append({"seq": len(self.events), "t": stamp, "tag": tag, "text": text})
            self.cv.notify_all()

    # ---- 행동
    def press(self, keys):
        """같은 키를 8초 안에 또 누르는 건 막는다. 실제 입력이 성공했을 때만 'AI누름'으로 기록한다 (실패는 '입력실패')."""
        with self.lock:
            if self.done.is_set():
                return
            if not isinstance(keys, str) or not re.fullmatch(r"[0-9*#]{1,32}", keys):
                self.emit("입력실패", "키패드는 숫자·*·#만 입력할 수 있어요"); return
            now = time.time()
            if keys == getattr(self, "last_keys", None) and now - getattr(self, "last_press_t", 0) < 8:
                self.emit("무시", f"{keys} 반복 입력 (직전 {now - self.last_press_t:.1f}초)"); return
            self.last_keys, self.last_press_t = keys, now      # 시도 시각을 먼저 잡아 겹친 판단이 같은 입력을 또 하지 않게 한다
            if not (getattr(self.a, "replay", None) or self.a.practice):
                ok, msg = phone.dtmf(keys)
                if not ok:
                    self.last_keys = None                       # 실패했으니 다시 시도할 수 있게 푼다
                    self.emit("입력실패", f"{keys}: {msg.splitlines()[-1][:100] if msg else '?'}"); return
                shown = keys
            else:
                shown = keys
            self.presses.append(keys)
            self.pressed_in_utterance = bool(self.live)   # 안내가 끝나기 직전에 눌렀으면 그 문장으로 재판단하지 않는다
        self.emit("AI누름", shown)

    def say(self, text):
        if self.done.is_set():
            return
        if not self.a.speak:
            self.emit("오류", "말하기가 꺼져 있어 말하지 않음"); return
        kind, _, opt = self.cfg["tts"].partition(":")
        path = os.path.join(DATA, f"say_{len(self.convo)}.{'wav' if kind == 'openai' else 'aiff'}")
        if kind == "openai":
            model, _, voice = opt.partition(":")
            open(path, "wb").write(openai("audio/speech", {"model": model or "gpt-4o-mini-tts", "voice": voice or "alloy",
                                                           "input": text, "response_format": "wav"}, raw=True))
        else:                                    # macOS 내장 음성 — 무료·즉시
            subprocess.run(["say", "-v", opt or "Yuna", "-o", path, text])
        if self.done.is_set():
            return
        dur = float(subprocess.run(["soxi", "-D", path], capture_output=True, text=True).stdout or 2)
        self.speaking_until = time.time() + dur + (1.0 if self.a.practice else 0.4)     # 연습은 스피커 소리가 마이크로 되돌아오므로 여유를 더 둔다
        if self.t_heard:
            self.emit("지연", f"말 끝 → AI 음성 시작 {time.time() - self.t_heard:.1f}초")
        threading.Thread(target=subprocess.run, args=(["sox", "-q", path, "-d"] if self.a.practice else ["sox", "-q", path, "-t", "coreaudio", SPEAK_DEV],), daemon=True).start()
        if self.cfg.get("monitor") and not self.a.practice:   # 사용자 스피커로도 들려준다
            threading.Thread(target=subprocess.run, args=(["sox", "-q", path, "-d"],), daemon=True).start()
        self.emit("AI말함", text)

    def end(self, outcome, summary):
        with self.end_lock:
            if self.done.is_set():
                return
            self.outcome, self.summary = outcome, summary
            self.done.set()

    def cancel(self, outcome="failed", summary="직접 끊었어요"):
        self.cancelled = True
        self.end(outcome, summary)
        session = getattr(self, "live_session", None)
        if session is not None:
            session._silence()

    def handoff(self, reason):
        if self.done.is_set():
            return
        if not self.a.handoff:
            self.end("needs_user", reason)
            return
        script = ('on run argv\n'
                  'display notification (item 1 of argv) with title "AI 통화: 직접 입력 필요" sound name "Glass"\n'
                  'end run')
        subprocess.run(["osascript", "-e", script, reason + " — 통화 키패드에서 직접 눌러주세요"])
        self.emit("넘겨받기", reason)

    # ---- 내장 LLM 판단 (brain=auto)
    def decide(self, interim=""):
        """LLM이 도구를 호출해 판단한다. 반환: {"action": press|say|handoff|end|wait, ...} (act가 실행)"""
        _, _, model = self.cfg["llm"].partition(":")
        convo = self.convo[-30:] + ([f"상대(말하는 중): {interim}"] if interim else [])
        body = {"model": model or "gpt-6-luna", "reasoning_effort": "none", "tools": self.tools, "tool_choice": "required",
                "messages": [{"role": "system", "content": self.system},
                             {"role": "user", "content": "통화 기록:\n" + "\n".join(convo) + "\n\n지금 도구는?"}]}
        try:
            calls = openai("chat/completions", body)["choices"][0]["message"].get("tool_calls") or []
            if not calls:
                return {"action": "wait"}
            name, args = calls[0]["function"]["name"], json.loads(calls[0]["function"].get("arguments") or "{}")
        except Exception as e:  # noqa: BLE001
            self.emit("오류", f"LLM {str(e)[:80]}"); return {"action": "wait"}
        if name == "press_keypad":
            return {"action": "press", "keys": re.sub(r"[^0-9*#]", "", args.get("keys", "")), "heard": (interim or (self.convo[-1] if self.convo else ""))[-60:]}
        if name == "end_call":
            return {"action": "end", "outcome": args.get("outcome", "?"), "summary": args.get("summary", "")}
        if name == "human_answered":
            return {"action": "human"}
        if name in ("say", "handoff"):
            return {"action": name, **args}
        return {"action": "wait"}

    def act(self, act):
        if self.done.is_set():
            return
        k = act.get("action")
        if k == "human":
            self.human = True
            self.emit("상대구분", "사람이 받았어요")
            return
        if not self.ars and k in ("press", "say"):
            self.emit("상대구분", "자동 안내예요")     # 앱 화면이 '자동 안내' 상태로 바뀐다
        self.ars = self.ars or k in ("press", "say")
        if k == "press" and act.get("keys"):
            if act.get("heard"):
                self.emit("판단", f"'{act['heard']}' → {act['keys']}")
            self.press(act["keys"])
        elif k == "say" and act.get("text"):
            self.say(act["text"])
        elif k == "handoff":
            self.handoff(act.get("reason", "직접 입력 필요"))
        elif k == "end":
            self.end(act.get("outcome", "?"), act.get("summary", ""))

    # ---- 언제 판단하나: 안내를 끝까지 듣고 판단한다 (조각 문장으로 누르지 않는다)
    #   ① 안내가 "…눌러 주십시오"로 끝나는 순간  ② 말이 1.5초 끊긴 순간  에만 LLM을 부른다. 판단은 한 번에 하나.
    def on_interim(self, text):
        self.live, self.last_speech = text, time.time()
        if CUE.search(text) and not self.cue_used:
            self.cue_used = self.cue_hit = True

    def on_final(self, text):
        self.live, self.last_speech = "", time.time()
        self.t_heard = self.last_speech
        pressed, self.pressed_in_utterance = self.pressed_in_utterance, False
        used, self.cue_used = self.cue_used, False
        if pressed:                                # 이 문장 끝을 듣고 이미 눌렀다 → 같은 문장으로 다시 판단하지 않는다
            return
        self.final_pending = True
        if CUE.search(text) and not used:
            self.cue_hit = True

    def decider(self):
        while not self.done.is_set() and not self.human:   # 사람이 받으면 대화는 음성 모델 몫이다
            time.sleep(0.05)
            silent = time.time() - self.last_speech >= self.silence
            if not (self.cue_hit or (self.final_pending and silent)):
                continue
            interim = self.live
            self.cue_hit = self.final_pending = False
            act = self.decide(interim)
            if not self.done.is_set():
                self.act(act)


CUE = re.compile(r"눌러\s*(주십|주세|주시|줘)|누르(세요|십시오|시기)|입력(해|하여|하시고)?\s*(주십|주세)")
SILENCE_SEC = 1.5


def serve(call):
    from urllib.parse import urlparse, parse_qs

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass

        def reply(self, obj, code=200):
            b = json.dumps(obj, ensure_ascii=False).encode()
            self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)

        def do_GET(self):
            u = urlparse(self.path); q = parse_qs(u.query)
            if u.path == "/events":
                since, wait = int(q.get("since", ["0"])[0]), float(q.get("wait", ["0"])[0])
                with call.cv:
                    call.cv.wait_for(lambda: len(call.events) > since or call.finished.is_set(), timeout=wait)
                    ev = call.events[since:]
                return self.reply({"events": ev, "next": since + len(ev), "ended": call.finished.is_set()})
            if u.path == "/status":
                return self.reply({"number": call.num, "ended": call.done.is_set(), "outcome": call.outcome, "log": os.path.join(DATA, call.logp)})
            self.reply({"error": "unknown"}, 404)

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            if self.path == "/press":
                call.press(body.get("keys", ""))
            elif self.path == "/say":
                call.say(body.get("text", ""))
            elif self.path == "/monitor":                      # 통화 중 AI 목소리를 내 스피커로도 들을지 (앱의 스피커 단추)
                s = getattr(call, "live_session", None)
                if s:
                    s.set_hear(body.get("on"))
            elif self.path == "/end":
                call.cancel(body.get("outcome", "success"), body.get("summary", ""))
            else:
                return self.reply({"error": "unknown"}, 404)
            self.reply({"ok": True})

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("number"); ap.add_argument("task")
    ap.add_argument("--practice", action="store_true", help="전화 없이 맥 마이크·스피커로 음성 대화 연습");
    ap.add_argument("--speak", action="store_true"); ap.add_argument("--handoff", action="store_true")
    ap.add_argument("--brain", default="auto", choices=["auto", "external"]); ap.add_argument("--extra", default="")
    ap.add_argument("--request-id", default="", help=argparse.SUPPRESS)
    ap.add_argument("--selftest", action="store_true", help="전화 없이 소리 캡처만 4초 시험")
    ap.add_argument("--replay", help="전화 없이 이벤트 파일(.jsonl)을 재생해 판단·입력 로직만 시험한다")
    a = ap.parse_args()
    a.speak = a.speak or a.practice
    if a.selftest:                                 # 전화 없이: 실통화와 같은 경로(화면 소리 캡처)로 시험 소리가 들리는지
        ear = subprocess.Popen([BIN("arsear"), "8", "ALL"], stdout=subprocess.PIPE, text=True,
                               env={**os.environ, "DEEPGRAM_API_KEY": DEEPGRAM})
        time.sleep(2.5); subprocess.run(["say", "-v", "Yuna", "수신 거부를 원하시면 일 번을 눌러 주십시오"])
        try:
            o, _ = ear.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            ear.kill(); o = "TIMEOUT"
        peak = max([float(l[2:]) for l in o.splitlines() if l.startswith("L|")] or [0])
        heard = [l[2:] for l in o.splitlines() if l.startswith("F|")]
        res = f"SELFTEST 소리크기={peak:.3f} 인식={heard}"
        print(res, flush=True); open(os.path.join(DATA, "selftest.txt"), "w").write(res + "\n" + o)
        return 0
    cfgp = os.path.join(DATA, "config.json")
    cfg = {**DEFAULTS, **(json.load(open(cfgp)) if os.path.exists(cfgp) else {})}
    call = Call(a, cfg)
    # 앱의 '끊기'는 SIGTERM으로 온다. 바로 죽으면 전화가 그대로 남으므로 정상 종료 경로로 보낸다.
    signal.signal(signal.SIGTERM, lambda *_: call.cancel())
    port = serve(call)
    state = os.path.join(DATA, "state.json")
    json.dump({"port": port, "pid": os.getpid(), "number": call.num, "brain": a.brain, "request_id": a.request_id, "log": os.path.join(DATA, call.logp)}, open(state, "w"))
    atexit.register(lambda: os.path.exists(state) and os.remove(state))
    call.emit("시작", f"{call.num} · 판단={'내장 ' + cfg['llm'] if a.brain == 'auto' else '외부 에이전트'} · 음성={cfg['tts']} · 제어포트 {port}")

    # 사전 점검: 하나라도 실패하면 전화를 걸지 않는다
    t = time.time()
    try:
        r = openai("chat/completions", {"model": cfg["llm"].partition(":")[2] or "gpt-6-luna", "reasoning_effort": "none",
                                        "messages": [{"role": "user", "content": "ok라고만 답해"}]})
        call.emit("점검", f"LLM 응답 {time.time() - t:.1f}s")
    except Exception as e:  # noqa: BLE001
        call.emit("오류", f"사전점검 실패: LLM 연결 ({str(e)[:60]})")
        return finish(call, "failed", "사전점검 실패: LLM 연결")

    if call.done.is_set():
        return finish(call, call.outcome, call.summary)

    if a.speak and a.brain == "auto" and not a.replay:      # 사람과 대화: GPT-Live 통합 음성 세션
        import live
        return live.run_call(call, a, cfg, OPENAI, openai, BIN("arsear"), finish, cfgp)

    q = queue.Queue()
    if a.replay:                                   # 오프라인 재생: 파일의 (지연, 종류, 문장)을 실시간 간격으로 흘려보낸다
        def feed():
            q.put("S|replay")
            for line in open(a.replay):
                if not line.strip():
                    continue
                e = json.loads(line)
                time.sleep(e.get("dt", 0.3)); q.put(f"{e['k']}|{e['t']}")
            time.sleep(9); call.done.set() if not call.done.is_set() else None
        threading.Thread(target=feed, daemon=True).start()
        call.emit("재생", a.replay); q.get()
    else:
        def start_ear():
            mic_arg = f'-t coreaudio "{cfg["mic"]}"' if cfg.get("mic") else "-d"   # 연습 입력 장치 (config.json의 mic, 없으면 시스템 기본)
            cmd = (["/bin/sh", "-c", f'exec sox -q {mic_arg} -r 16000 -c 1 -b 16 -e signed -t raw - | "{BIN("arsear")}" {MAX_CALL + 15} STDIN'] if a.practice
                   else [BIN("arsear"), str(MAX_CALL + 15), "TAP"])   # 통화 중계 데몬 소리만 탭으로 듣는다 (듣기·말하기 공통)
            e = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, start_new_session=True,
                                 env={**os.environ, "DEEPGRAM_API_KEY": DEEPGRAM, **({"AICALL_PCM": call.logp[:-3] + ".pcm"} if cfg.get("record") else {})})
            call.audio = e
            return e
        ear = start_ear()
        atexit.register(lambda: os.killpg(call.audio.pid, 15))
        q = queue.Queue()

        def pump():
            restarts = 0
            while True:
                for l in ear_cur[0].stdout:
                    q.put(l.rstrip("\n"))
                if call.done.is_set() or restarts >= 3:
                    return
                restarts += 1                          # 소리 캡처가 죽었다 → 바로 다시 연다 (통화는 계속)
                q.put(f"E|소리 캡처 종료 — 재시작 {restarts}/3")
                ear_cur[0] = start_ear()
        ear_cur = [ear]
        threading.Thread(target=pump, daemon=True).start()
        try:
            first = q.get(timeout=12)
        except queue.Empty:
            first = "E|timeout"
        if not first.startswith("S|"):
            call.emit("오류", f"통화 오디오 시작 실패 ({first})")
            return finish(call, "failed", "소리 캡처 시작 실패")

        if a.speak and not a.practice:
            ok, msg = phone.set_mic(PHONE_MIC); call.emit("마이크", msg)
            atexit.register(lambda: phone.set_mic("시스템 설정값 사용"))
            if not ok:
                return finish(call, "failed", "전화 앱 마이크 설정 실패")
        if call.done.is_set():
            return finish(call, call.outcome, call.summary)
        ok, msg = (True, "연습 모드: 전화 없음") if a.practice else phone.dial(call.num)
        call.emit("발신", msg)
        if not ok:
            return finish(call, "failed", f"발신 실패: {msg[:80]}")
        if not a.practice:
            # 이후 예외로 엔진이 종료돼도 발신한 전화가 남지 않게 한다.
            atexit.register(lambda: phone.hangup() if not call.finished.is_set() else None)
        if call.done.is_set():
            if not a.practice:
                phone.hangup()
            return finish(call, call.outcome, call.summary)

    if a.brain == "auto":
        threading.Thread(target=call.decider, daemon=True).start()
    t0 = time.time()
    heard_any, silent_n, idle_n, last_state_t = False, 0, 0, 0.0
    while time.time() - t0 < MAX_CALL and not call.done.is_set():
        if not (a.replay or a.practice) and time.time() - t0 > 12 and time.time() - last_state_t > 3:     # 상대가 끊었으면 통화 종료를 알아챈다
            last_state_t = time.time()
            idle_n = idle_n + 1 if phone.state() == "idle" else 0
            if idle_n >= 2:
                call.emit("종료", "통화가 끊김")
                if call.outcome == "timeout":
                    call.outcome, call.summary = "failed", "상대가 통화를 끊음 — 통화 기록 확인"
                break
        try:
            kind, _, text = q.get(timeout=0.1).partition("|")
        except queue.Empty:
            continue
        if kind == "E":
            call.emit("오류", text); continue
        if kind == "L":                            # 한 번도 못 들었을 때만 경고 (ARS가 입력을 기다리는 침묵은 정상)
            if float(text or 0) >= 0.002:
                heard_any = True
            elif not heard_any and time.time() - t0 > 15:
                silent_n += 1
                if silent_n == 3:
                    call.emit("오류", "통화 소리가 계속 무음 — 소리 경로 확인")
            continue
        if time.time() < call.speaking_until:
            continue                               # 내 목소리가 나가는 동안 들린 건 무시 (에코)
        if kind == "F" and text.strip():
            call.emit("상대", text)
            call.on_final(text)
        elif kind == "I" and text.strip():
            call.on_interim(text)
    time.sleep(1)
    if not (a.replay or a.practice):
        phone.hangup()
    return finish(call, call.outcome, call.summary)


def finish(call, outcome, summary):
    with call.end_lock:
        if call.done.is_set() and call.outcome != "timeout":
            outcome, summary = call.outcome, call.summary
        call.outcome, call.summary = outcome, summary
        call.done.set()
    call.emit("결과", f"{outcome} — {summary}")
    with call.log_lock:
        call.logf.write(f"\n결과: {outcome} — {summary}\n"); call.logf.close()
    with call.cv:
        call.finished.set()
        call.cv.notify_all()
    print(json.dumps({"outcome": outcome, "summary": summary, "pressed": call.presses, "log": os.path.join(DATA, call.logp)}, ensure_ascii=False), flush=True)
    time.sleep(1.5)                                # 외부 에이전트가 마지막 이벤트를 받아갈 시간
    return 0 if outcome == "success" else 1


if __name__ == "__main__":
    sys.exit(main())
