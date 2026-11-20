"""GPT-Live 통합 음성 통화 — 사람과 대화하는 통화(--speak, --practice) 전용.
듣기·생각·말하기를 한 세션이 하고, 키패드·종료·넘겨받기는 도구 호출로만 실행한다.
금지 정보(주민번호·카드 등)는 모델에게 아예 주지 않는다. GPT-Live는 발화를 내보내기 전에 막을 수 없기 때문이다."""
import array, asyncio, base64, json, os, queue, re, signal, subprocess, threading, time, urllib.error, urllib.request

import websockets

import phone

URL = "wss://api.openai.com/v1/live/sessions"
RATE = 24000
CHUNK = RATE * 2 // 20                     # 50ms
MAX_CALL = 300
SPEAK_DEV = "AICall Speaker"   # AI 음성을 내보내는 가상 장치 (vmic/AICall.driver). 여기 쓴 소리가 AICall Mic로 나온다
PHONE_MIC = "AICall Mic"       # 전화 앱 마이크. 입력 전용 1채널 (BlackHole 16ch는 통화 엔진이 상대에게 보내지 않았다, 11-13 실측)
QUIET_SEC = 0.35                           # 상대가 이만큼 조용해야 붙잡아 둔 AI 음성을 내보낸다 (GPT-Live가 이미 턴 끝을 판단한 뒤라 짧게, 11-16 0.7→0.35)
KEYPAD_CUE = re.compile(r"눌러\s*(주십|주세|주시|줘)|누르(세요|십시오|시기)|입력(해|하여|하시고)?\s*(주십|주세)|번을\s*누르")   # 사람으로 보고 대화하다가 이 말이 들리면 ARS로 바꾼다
NOT_PERSON = re.compile(r"고객|가입자|십시오|바랍니다|안녕하십니까|환영|연결|잠시|기다려|녹음|\d")   # 휴대폰에 걸었어도 이 말이 섞인 첫마디는 바로 사람으로 보지 않는다
YOUNG_SEC = 8.0                            # 사람으로 본 뒤 이 시간 안에 사서함·꺼짐 안내가 들리면 실패로 끊는다
END_SILENCE = 0.6                          # AI 음성에 이만큼 무음이 이어지면 한 발화가 끝난 것으로 본다
UTTER_END = 0.35                           # 상대 소리가 이만큼 끊기면 ARS 판단 엔진에 문장을 넘긴다
ARS_WORDS = re.compile(r"고객|센터|안내|서비스|상담|번을|눌러|수신|거부|텔레콤|카드|은행|보험|증권|시스템|자동|ARS|에이알에스")
MAX_HOLD = 20.0                            # 이보다 오래 못 내보낸 음성은 이미 늦은 말이라 버린다
RAW = ["-t", "raw", "-r", str(RATE), "-e", "signed", "-b", "16", "-c", "1"]

INSTRUCTIONS = """너는 {owner_name}의 AI 전화 비서다. {owner_name} 본인 휴대폰 번호로 상대에게 전화를 건 상태다.
한국어로 자연스러운 전화 말투로 짧게, 한 번에 한두 문장만 말한다. 질문은 한 번에 하나만 한다.
상대 목소리가 들리기 전에는 말하지 않는다. 신호음이 들리면 기다린다.
사람이 받으면 첫 마디에서 {owner_name} 님을 대신해 전화한 AI 비서라고 밝히고 바로 용건을 말한다.
사람이 번호를 누르라고 하면 press_keypad 도구로 누른다. 말로 번호를 말하지 않는다.
상대가 통화를 마무리하거나 진행할 수 없으면 짧게 한 마디로 인사한다. 키패드는 반드시 도구로 누른다.
녹음된 ARS 안내는 별도 시스템이 처리하니 ARS에게는 아무 말도 하지 않고 도구도 부르지 않는다.
Interruption policy: 상대가 말을 시작하면 말을 멈추고 듣는다.
네가 아는 개인정보는 아래 '알려도 되는 정보'뿐이다. 그 밖의 정보(주민번호·생년월일·카드·계좌·주소·비밀번호)는 모른다고 말하고, 상대가 요구하면 handoff 도구를 부른다.
결제·선결제·위약금 동의·계약 확정은 하지 않는다. 조건이 목적과 다르면 내용을 확인한 뒤 end_call(needs_user)로 끝낸다.
숫자는 한국어 읽는 법으로 말한다. 날짜는 한자어(십일월 십사일), 시각은 고유어 시와 한자어 분(일곱 시 삼십 분), 사람 수는 고유어(두 명)다. 14일을 "열네 일", "열넷"으로 말하지 않는다. 전화번호는 숫자 하나씩 읽는다.
목적: {task}
알려도 되는 정보: 이름 {owner_name}, 연락처 {owner_phone_ko}(키패드로 누를 때는 {owner_digits}) {extra}"""

TOOLS = [
    {"type": "function", "name": "press_keypad", "description": "통화 중 키패드를 누른다. ARS가 번호 입력을 요구할 때 쓴다.",
     "parameters": {"type": "object", "properties": {"keys": {"type": "string", "description": "누를 숫자·*·#"}}, "required": ["keys"]}},
    {"type": "function", "name": "end_call", "description": "통화를 끝낸다. 인사를 마친 뒤 부른다.",
     "parameters": {"type": "object", "properties": {"outcome": {"type": "string", "enum": ["success", "failed", "needs_user"]},
                                                     "summary": {"type": "string", "description": "결과를 사용자에게 알리는 한 문장. 해요체. 예: 예약이 잡혔어요."}}, "required": ["outcome", "summary"]}},
    {"type": "function", "name": "handoff", "description": "본인만 할 수 있는 입력·판단을 요구받았을 때 사용자에게 넘긴다.",
     "parameters": {"type": "object", "properties": {"reason": {"type": "string"}}, "required": ["reason"]}},
]


JUDGE = """통화 기록을 보고 지금 통화를 끝내도 되는지 판단해 도구를 하나 부른다.
AI가 작별 인사를 했거나, 용건이 끝났고 더 할 말이 없으면 end_call. 대화가 이어지는 중이면 continue_call. 확신이 없으면 continue_call.
결과: success=용건 달성(ARS가 처리 완료 안내, 예약 확정 등), needs_user=조건이 달라 사람 판단 필요, failed=진행 불가.
통화 목적: {task}"""
JUDGE_TOOLS = [
    {"type": "function", "function": {"name": "end_call", "description": "통화 종료", "parameters": {"type": "object", "properties": {
        "outcome": {"type": "string", "enum": ["success", "failed", "needs_user"]}, "summary": {"type": "string", "description": "결과를 사용자에게 알리는 한 문장. 해요체. 예: 예약이 잡혔어요."}}, "required": ["outcome", "summary"]}}},
    {"type": "function", "function": {"name": "continue_call", "description": "통화 계속", "parameters": {"type": "object", "properties": {}}}},
]


SINO = "영 일 이 삼 사 오 육 칠 팔 구".split()
NATIVE = {1: "한", 2: "두", 3: "세", 4: "네", 5: "다섯", 6: "여섯", 7: "일곱", 8: "여덟", 9: "아홉", 10: "열", 11: "열한", 12: "열두", 20: "스무"}
TENS = {10: "열", 20: "스물", 30: "서른", 40: "마흔", 50: "쉰"}


def sino(n):
    if n == 0:
        return "영"
    out = ""
    for unit, name in ((1000, "천"), (100, "백"), (10, "십")):
        d, n = divmod(n, unit)
        if d:
            out += ("" if d == 1 else SINO[d]) + name
    return out + (SINO[n] if n else "")


def native(n):
    if n in NATIVE:
        return NATIVE[n]
    t, u = n - n % 10, n % 10
    return (TENS.get(t, sino(t)) + (NATIVE[u] if u else "")) if t in TENS else sino(n)


def ko_numbers(text):
    """목적 문장의 날짜·시각·인원을 한국어 읽는 방식 그대로 글자로 바꾼다 (GPT-Live가 14일을 '열네 일'로 읽는 문제)."""
    month = {6: "유월", 10: "시월"}
    text = re.sub(r"(\d{1,2})\s*월", lambda m: month.get(int(m[1]), sino(int(m[1])) + "월"), text)
    text = re.sub(r"(\d{1,2})\s*일", lambda m: sino(int(m[1])) + "일", text)
    text = re.sub(r"(\d{1,2})\s*시(?!간)", lambda m: native(int(m[1])) + " 시", text)
    text = re.sub(r"(\d{1,2})\s*분", lambda m: sino(int(m[1])) + " 분", text)
    return re.sub(r"(\d{1,3})\s*(명|사람|개|장|잔|병)", lambda m: native(int(m[1])) + " " + m[2], text)


# 사람이 받지 못한 통화(음성사서함·꺼짐·거절·통화중·없는 번호). 받아쓰기가 "사서함"을 "사섬"으로 깨뜨리는 일이 있어 낱말을 느슨하게 잡는다.
UNANSWERED = re.compile(r"사서함|사섬|소리샘|삐\s*소리|띠\s*소리|통화료가\s*부과|음성\s*녹음은|연락\s*번호를\s*남기|전원이\s*꺼|연결이\s*되지\s*않|연결할\s*수\s*없|없는\s*번호|서비스\s*지역을\s*벗어")
# 사람도 하는 말("제가 지금 통화 중이라서요"). 안내 방송 말투가 함께 있을 때만 미응답으로 본다
UNANSWERED_WEAK = re.compile(r"전화를\s*받을\s*수\s*없|받지\s*않|통화\s*중|잠시\s*후\s*다시\s*(걸|이용)")
ANNOUNCE = re.compile(r"고객|가입자|지금은|오니|으니|므로|십시오|바랍니다|습니다|입니다")


def unanswered(text):
    return bool(UNANSWERED.search(text) or (UNANSWERED_WEAK.search(text) and ANNOUNCE.search(text)))


def personalize(text, owner):
    """지시문의 {owner_name} 같은 자리를 설정의 사용자 정보로 채운다 (agent.owner_fields가 만든 값)."""
    for k, v in owner.items():
        text = text.replace("{" + k + "}", v)
    return text


def looks_human(text):
    """전화를 받는 사람의 첫마디(여보세요, 네 ○○입니다)는 LLM을 기다리지 않고 바로 판별한다. 기관 안내 낱말이 있으면 판단 모델에 맡긴다."""
    t = text.strip()
    if ARS_WORDS.search(t) or len(t) > 40:
        return False
    if t.rstrip("?.! ") in ("네", "예") or re.search(r"여보세요|입니다|예요|이에요", t):
        return True
    # 아는 사람이 받는 짧은 첫마디("어, 누구야", "응", "왜")는 판단 엔진(약 2초)을 기다리지 않는다. 안내 방송의 첫 조각처럼 보이는 말은 제외
    return len(t) <= 12 and not re.search(r"안녕|환영|감사|잠시|기다려|연결|연락|\d", t)


def loud(b):
    return max(map(abs, array.array("h", b[:len(b) & ~1])), default=0) > 800


class Session:
    def __init__(self, call, api_key, model, voice, backend, src_cmd, src_env, out_cmd, echo_gate, llm):
        self.call, self.key, self.model, self.voice, self.backend = call, api_key, model, voice, backend
        self.src_cmd, self.src_env, self.out_cmd, self.echo_gate = src_cmd, src_env, out_cmd, echo_gate
        self.heard, self.said = "", ""
        self.llm, self.judging = llm, False
        self.voice_prompt = ""                 # 설명문으로 만든 목소리는 세션 지시에 그 설명을 함께 넣어야 한다
        self.prebuffer = 0.2 if echo_gate else 0.0
        self.playing_until, self.speech_until, self.last_voice, self.wait_reply = 0.0, 0.0, 0.0, False
        self.out_q = queue.Queue()
        self.gate, self.held, self.held_at, self.talking, self.quiet_bytes = False, bytearray(), 0.0, False, 0   # 상대가 말하는 동안 AI 음성을 붙잡는 출구
        self.said_held = ""                    # 상대가 사람인지 모르는 동안 만들어진 AI 말
        self.record, self.rec_rx, self.rec_tx = None, None, None
        self.rec_t0, self.rec_tx_bytes = 0.0, 0
        self.heard_at = 0.0
        self.marks = {}                        # 첫 응답 지연 분석용: 단계별 첫 시각
        self.said_at, self.audio_at = 0.0, 0.0  # AI 대사 글자·말소리가 마지막으로 도착한 시각 (재생 시각이 아니다)
        self.ai_pending = False                # 아직 종료 판정을 받지 않은 AI 발화가 있다
        self.cut = False                       # 상대가 끊었다: 쌓인 AI 음성을 버리고 재생을 멈춘다
        self.monitor, self.mon, self.mon_q = None, None, None   # monitor: AI 음성을 사용자 스피커로도 내보내는 명령
        self.mon_on = False                    # 지금 스피커로도 내보내는가 (통화 중 앱에서 바꿀 수 있다)
        self.src = self.out = None
        self.ready = self.closed = None        # run()에서 만든다: 파이썬 3.9는 Event를 만든 시점의 루프에 묶는다

    # ---- 재생: 받은 음성을 순서대로 내보낸다 (실제 재생 끝 시각을 스스로 계산한다)
    def _writer(self):
        if self.prebuffer:                         # 연습(스피커): 도착 간격 흔들림으로 재생이 비지 않게 조금 모아서 시작
            while not self.cut and self.out_q.qsize() * 0.1 < self.prebuffer:
                time.sleep(0.02)
            if self.cut:
                return
        while True:
            b = self.out_q.get()
            if b is None:
                return
            try:
                self.out.stdin.write(b); self.out.stdin.flush()
            except (BrokenPipeError, OSError):
                return

    def _play(self, b):
        """AI 음성을 재생 줄에 넣는다. 재생이 언제 끝나는지는 여기서 계산한다."""
        if self.cut:                               # 통화가 끊겼다 → 더 내보내지 않는다
            return
        self.out_q.put(b)
        if self.mon_q and self.mon_on:
            self.mon_q.put(b)
        if self.rec_tx:                            # 실제 재생 시각에 맞춰 앞 공백을 채워 쓴다 (받은 소리 파일과 시간축을 맞추려고)
            start = max(self.playing_until, time.time())
            gap = int((start - self.rec_t0) * RATE) * 2 - self.rec_tx_bytes
            if gap > 0:
                self.rec_tx.write(bytes(gap)); self.rec_tx_bytes += gap
            self.rec_tx.write(b); self.rec_tx_bytes += len(b)
        if loud(b):
            self.mark("AI 음성 첫 출력")
        now = time.time()
        self.playing_until = max(self.playing_until, now) + len(b) / (RATE * 2)
        if loud(b):                                # GPT-Live는 말이 없어도 무음을 계속 보낸다 → 실제 말소리 끝만 따로 잰다
            self.speech_until = self.playing_until
            if self.wait_reply and now - self.last_voice > 0.15:
                self.wait_reply = False
                self.call.emit("지연", f"말 끝 → AI 음성 시작 {now - self.last_voice:.2f}초")

    def set_hear(self, on):
        """통화 소리를 내 스피커로 들을지. AI 목소리(mon_on)와 상대 목소리(통화 탭의 음소거)를 함께 바꾼다. 받아쓰기는 그대로."""
        self.mon_on = bool(on)
        if self.gate and self.src and self.src.poll() is None:      # 전화일 때만: src가 통화 탭(arsear)이다
            try:
                os.kill(self.src.pid, signal.SIGUSR2 if on else signal.SIGUSR1)
            except OSError:
                pass

    def mark(self, key):
        """단계별 첫 시각을 1/1000초로 남긴다 (받은 뒤 첫 대사까지 어디서 늦는지 보려고)."""
        if key not in self.marks:
            t = self.marks[key] = time.time()
            self.call.emit("시각", f"{key} {time.strftime('%H:%M:%S', time.localtime(t))}.{int(t % 1 * 1000):03d}")

    def line(self):
        """상대 종류. human=GPT-Live가 대화, ars=판단 엔진이 키패드·짧은 음성 처리(GPT-Live 음성은 버림), unknown=판단 전(음성을 붙잡아 둠)."""
        if not self.gate or self.call.human:
            return "human"
        return "ars" if self.call.ars else "unknown"

    def _route(self, b):
        """모델이 만든 음성을 상대가 말을 마친 뒤에만 내보낸다. GPT-Live는 턴을 서버가 정하므로 클라이언트 출구에서 막는다."""
        if not self.gate:
            return self._play(b)
        line = self.line()
        if line == "ars":
            self.held.clear()
            return
        if self.talking and line == "human":                           # 이미 나가기 시작한 발화는 끝까지 내보낸다
            self._play(b)
            self.quiet_bytes = 0 if loud(b) else self.quiet_bytes + len(b)
            if self.quiet_bytes > END_SILENCE * RATE * 2:
                self.talking = False
        elif self.held or loud(b):
            if not self.held:
                self.held_at = time.time()
            self.held += b

    def _release(self):
        """상대가 조용해졌으면 붙잡아 둔 음성을 한 번에 내보낸다."""
        if not self.held:
            return
        now = time.time()
        line = self.line()
        if now - self.held_at > MAX_HOLD:
            self.call.emit("게이트", f"늦은 음성 {len(self.held) / (RATE * 2):.1f}초 버림")
            self.held.clear(); self.said_held = ""
        elif line == "ars":
            self.held.clear(); self.said_held = ""
        elif line == "human" and now - self.last_voice >= QUIET_SEC:
            self._play(bytes(self.held))
            self.held.clear()
            self.talking, self.quiet_bytes = True, 0
            if self.said_held:
                self.said, self.said_held = self.said + self.said_held, ""
                self.said_at, self.ai_pending = now, True

    def _utterance(self):
        """상대 말이 끊기면 문장을 ARS 판단 엔진에 넘긴다. 사람이 받으면 그때부터 GPT-Live가 대화한다."""
        if not self.gate or not self.heard.strip():
            return
        now, text = time.time(), self.heard.strip()
        if self.call.human:
            return self._recheck(now, text)
        if not self.call.convo and self.call.num.startswith("01") and now - self.heard_at >= 0.1 \
                and not (NOT_PERSON.search(text) or ARS_WORDS.search(text) or unanswered(text)):
            # 휴대폰 번호는 사람이 받는다고 먼저 본다: 받아쓰기 첫 조각만 와도 바로 대화를 시작한다 (말이 끝나길·판단 엔진을 기다리지 않음)
            self.mark("사람 판별")
            return self.call.act({"action": "human"})
        if now - self.last_voice < UTTER_END:
            return
        if not self.call.convo and unanswered(text):    # 사람이 받지 않았다 → 사서함에 말하거나 기다리지 않고 바로 실패로 끊는다
            self.flush("user")
            self.call.emit("판정", "상대가 받지 못함(사서함·꺼짐·거절 등)")
            self.call.end("failed", "전화를 받지 않았어요(음성사서함·꺼짐·거절·통화중 중 하나) — 통화 기록 확인")
            return
        if not self.call.convo and now - self.heard_at >= 0.3 and looks_human(text):
            self.flush("user")
            self.mark("사람 판별")
            self.call.act({"action": "human"})
        elif now - self.heard_at >= 0.6:           # 받아쓰기는 조각으로 늦게 온다. 조각 문장으로 판단하지 않는다
            self.flush("user")
            self.call.on_final(text)

    def _recheck(self, now, text):
        """사람으로 본 뒤에도 듣는다: 초반의 사서함·꺼짐 안내면 실패로 끊고, 번호를 누르라는 말이 들리면 ARS로 바꾼다."""
        if now - self.last_voice < UTTER_END:
            return
        young = now - self.marks.get("사람 판별", 0) < YOUNG_SEC
        if young and unanswered(text):
            self.flush("user"); self._silence()
            self.call.emit("판정", "상대가 받지 못함(사서함·꺼짐·거절 등)")
            self.call.end("failed", "전화를 받지 않았어요(음성사서함·꺼짐·거절·통화중 중 하나) — 통화 기록 확인")
        elif KEYPAD_CUE.search(text):
            self.flush("user")
            self.held.clear(); self.said_held = ""; self.talking = False
            self.call.human, self.call.ars = False, True
            self.call.emit("상대구분", "자동 안내예요 (번호 입력 요구를 듣고 바꿈)")
            self.call.on_final(text)
            threading.Thread(target=self.call.decider, daemon=True).start()

    def _monitor_writer(self):
        """사용자 스피커로 들려주는 줄. 전화로 나가는 음성이 이 장치 때문에 밀리지 않게 따로 쓴다."""
        while True:
            b = self.mon_q.get()
            if b is None:
                return
            try:
                self.mon.stdin.write(b); self.mon.stdin.flush()
            except (BrokenPipeError, OSError):
                return

    def flush(self, who):
        if who == "user" and self.heard.strip():
            self.call.emit("상대", self.heard.strip())
            self.heard = ""
        if who == "ai" and self.said.strip():
            self.call.emit("AI말함", self.said.strip())
            self.said = ""

    def ai_idle(self, now=None):
        """AI가 한 발화를 다 마쳤는가. 대사 글자는 음성보다 먼저 오고 speech_until은 직전 발화 값일 수 있어 셋 다 본다."""
        now = now or time.time()
        return now - self.said_at > 1.0 and now - self.audio_at > 1.0 and now > self.speech_until + 0.8

    def _ask_judge(self, extra="", force=False):
        r = self.llm("chat/completions", {"model": self.backend, "reasoning_effort": "none", "tools": JUDGE_TOOLS,
                                          "tool_choice": {"type": "function", "function": {"name": "end_call"}} if force else "required",
                                          "messages": [{"role": "system", "content": JUDGE.replace("{task}", self.call.a.task) + extra},
                                                       {"role": "user", "content": "\n".join(self.call.convo[-20:])}]})
        c = (r["choices"][0]["message"].get("tool_calls") or [{}])[0].get("function", {})
        return json.loads(c.get("arguments") or "{}") if c.get("name") == "end_call" else None

    def _judge(self):
        """AI가 말을 마칠 때마다 종료 여부를 따로 판단한다 (GPT-Live가 종료 도구를 빠뜨리는 일이 잦다)."""
        started = time.time()
        try:
            args = self._ask_judge()
            if args is not None:
                if self.call.done.is_set() or self.heard.strip() or self.ai_pending or self.said_at > started or self.heard_at > started:   # 판정 중에 누가 다시 말했다 → 그 말이 끝난 뒤 다시 판정
                    self.call.emit("판정", "새 발화가 있어 종료 보류")
                else:
                    self.call.emit("판정", f"통화 종료 {args.get('outcome')}")
                    self.call.end(args.get("outcome", "?"), args.get("summary", ""))
        except Exception as e:  # noqa: BLE001
            self.call.emit("오류", f"종료 판정 {repr(e)[:100]}")
        self.judging = False

    def _verdict_after_hangup(self):
        """상대가 먼저 끊었을 때: 대화가 있었으면 기록으로 결과를 매긴다. 대화가 없거나 판정이 안 되면 실패."""
        if not any(x.startswith("상대:") for x in self.call.convo) or not self.llm:
            return "failed", "상대가 통화를 끊음 — 통화 기록 확인"
        try:
            args = self._ask_judge("\n상대가 먼저 전화를 끊었다. 통화는 이미 끝났으니 기록만으로 결과를 매긴다. 용건 달성 근거가 기록에 없으면 failed.", force=True) or {}
            return args.get("outcome", "failed"), "상대가 먼저 끊음 — " + args.get("summary", "통화 기록 확인")
        except Exception as e:  # noqa: BLE001
            self.call.emit("오류", f"끊김 판정 {repr(e)[:100]}")
            return "failed", "상대가 통화를 끊음 — 통화 기록 확인"

    async def send(self, obj):
        await self.ws.send(json.dumps(obj))

    async def tool(self, item):
        if self.call.done.is_set():
            return
        name, call_id = item.get("name"), item.get("call_id")
        if self.line() != "human":                 # ARS 처리는 판단 엔진의 일이다. 음성 모델의 도구 호출은 실행하지 않는다
            return await self.send({"type": "response.item.create", "item": {"type": "function_call_output", "call_id": call_id, "output": json.dumps({"result": "시스템이 처리합니다"}, ensure_ascii=False)}})
        args = json.loads(item.get("arguments") or "{}")
        self.call.emit("도구호출", f"{name} {json.dumps(args, ensure_ascii=False)}")
        loop = asyncio.get_running_loop()
        result = "완료"
        if name == "press_keypad":
            keys = args.get("keys", "")
            await loop.run_in_executor(None, self.call.press, keys)
            result = "눌렀습니다" if getattr(self.call, "last_keys", None) == keys else "입력 실패"   # 중복이라 건너뛴 입력은 실패가 아니다
        elif name == "handoff":
            await loop.run_in_executor(None, self.call.handoff, args.get("reason", "직접 입력 필요"))
            result = "사용자에게 알렸습니다"
        elif name == "end_call":
            self.call.end(args.get("outcome", "failed"), args.get("summary", ""))
        if self.call.done.is_set():                # 통화가 이미 끝났으면 닫히는 세션에 보내지 않는다
            return
        await self.send({"type": "response.item.create", "item": {"type": "function_call_output", "call_id": call_id, "output": json.dumps({"result": result}, ensure_ascii=False)}})
        await self.send({"type": "response.create"})

    async def rx(self):
        async for m in self.ws:
            j = json.loads(m); t = j.get("type", "")
            if not t.endswith(".delta"):                 # 끼어들기 때 서버가 어떤 신호를 보내는지 확인용 (11-14). 확인 끝나면 줄인다
                sub = j.get("event", {}).get("type", "") if t == "response.event" else ""
                if not sub.endswith(".delta"):
                    self.call.emit("서버", f"{t} {sub} {json.dumps({k: v for k, v in j.items() if k not in ('type', 'event', 'delta', 'audio')}, ensure_ascii=False)[:120]}")
            if t == "session.started":
                self.ready.set()
            elif t == "session.output_audio.delta":
                b = base64.b64decode(j["delta"])
                if loud(b):
                    self.audio_at = time.time()
                self._route(b)
                self._release()
            elif t == "session.input_transcript.delta":
                self.flush("ai"); self.heard += j.get("delta", ""); self.heard_at = time.time()
                self.mark("받아쓰기 첫 글자")
                if self.line() != "human":
                    self.call.on_interim(self.heard)
            elif t == "session.output_transcript.delta":
                line = self.line()                     # 내보내지 않은 말은 기록에도 남기지 않는다
                if line == "human":
                    self.flush("user"); self.said += j.get("delta", "")
                    self.said_at, self.ai_pending = time.time(), True
                elif line == "unknown":
                    self.said_held += j.get("delta", "")
            elif t == "response.event":
                ev = j.get("event", {})
                item = ev.get("item", {})
                if ev.get("type") == "response.output_item.done" and item.get("type") == "function_call":
                    asyncio.create_task(self.tool(item))
            elif t == "session.closed":
                self.call.emit("사용량", json.dumps(j.get("usage") or j.get("session", {}).get("usage") or {}, ensure_ascii=False)[:160])
                self.closed.set()
                return
            elif t == "error":
                self.call.emit("오류", json.dumps(j.get("error", j), ensure_ascii=False)[:200])

    async def tx(self):
        loop = asyncio.get_running_loop()
        while not self.call.done.is_set():
            b = await loop.run_in_executor(None, self.src.stdout.read, CHUNK)
            if not b:
                return
            if self.rec_rx:
                self.rec_rx.write(b)
            now = time.time()
            if self.echo_gate and now < self.speech_until + 0.3:
                b = bytes(len(b))                  # 스피커로 듣는 연습: 내 목소리가 마이크로 되돌아오지 않게 막는다
            elif loud(b):
                self.last_voice, self.wait_reply = now, True
                self.mark("통화 소리 첫 감지")
            await self.send({"type": "session.input_audio.append", "audio": base64.b64encode(b).decode()})

    async def run(self, is_phone):
        if self.call.done.is_set():
            return
        self.ready, self.closed = asyncio.Event(), asyncio.Event()
        self.src = subprocess.Popen(self.src_cmd, stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, env=self.src_env, start_new_session=True)
        self.out = subprocess.Popen(self.out_cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, start_new_session=True)
        threading.Thread(target=self._writer, daemon=True).start()
        if self.monitor:
            self.mon = subprocess.Popen(self.monitor, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            self.mon_q = queue.Queue()
            threading.Thread(target=self._monitor_writer, daemon=True).start()
        if self.record:                            # config.json record=true: 들은 소리(.rx.pcm)와 내보낸 소리(.tx.pcm)를 남긴다
            self.rec_rx, self.rec_tx = open(self.record + ".rx.pcm", "wb"), open(self.record + ".tx.pcm", "wb")
            self.rec_t0 = time.time()
        call = self.call
        start = {"type": "session.start", "session": {
            "model": self.model, "instructions": self.voice_prompt + "\n" + personalize(INSTRUCTIONS, call.owner).replace("{task}", ko_numbers(call.a.task)).replace("{extra}", ko_numbers(call.a.extra)),
            "audio": {"format": {"type": "audio/pcm", "rate": RATE}, "output": {"voice": {"id": self.voice} if self.voice.startswith("voice_") else self.voice}},
            "delegation": {"type": "responses", "responses": {"model": self.backend, "tools": TOOLS, "tool_choice": "auto"}}}}
        async with websockets.connect(URL, additional_headers={"Authorization": f"Bearer {self.key}"}, max_size=None) as self.ws:
            await self.send(start)
            rx = asyncio.create_task(self.rx())
            await asyncio.wait_for(self.ready.wait(), 10)
            call.emit("세션", f"{self.model} · {self.voice} · 백엔드 {self.backend}")
            tx = asyncio.create_task(self.tx())
            if self.gate:
                threading.Thread(target=call.decider, daemon=True).start()
            t0, last_state, idle_n, hung = time.time(), 0.0, 0, False
            while time.time() - t0 < MAX_CALL and not call.done.is_set():
                await asyncio.sleep(0.05)
                self._release()
                self._utterance()
                if is_phone and time.time() - t0 > 12 and time.time() - last_state > 0.5:   # 상태 조회는 0.08초. 끊김을 1초 안에 알아챈다
                    last_state = time.time()
                    state = await asyncio.get_running_loop().run_in_executor(None, phone.state)
                    idle_n = idle_n + 1 if state == "idle" else 0
                    if idle_n >= 2:
                        self._silence()
                        call.emit("종료", "통화가 끊김 — AI 말 중단")
                        hung = True
                        call.done.set()
                if rx.done() or tx.done():
                    if not call.done.is_set():
                        call.end("failed", "음성 연결 또는 소리 입력이 종료됐어요")
                    break
                if self.line() == "human" and self.ai_pending and not self.heard.strip() and not self.held and not self.judging and self.ai_idle():
                    self.flush("ai")                   # AI가 말을 마쳤다 → 끝낼지 판정
                    self.ai_pending, self.judging = False, True
                    threading.Thread(target=self._judge, daemon=True).start()
            self.flush("user"); self.flush("ai")
            self._stop_source()                        # 통화가 끝나면 입력부터 멈춘다 (안 읽는 파이프에 sox가 계속 쓰면 overrun 경고가 쏟아진다)
            deadline = time.time() + 8.0           # 마지막 인사가 끝날 때까지. 종료 판정 뒤에도 남은 대사가 도착할 수 있어 도착이 멈출 때까지 본다
            while not hung and not call.cancelled and time.time() < deadline:
                self._release()
                if self.ai_idle() and not self.held and time.time() > self.speech_until + 0.3:
                    break
                await asyncio.sleep(0.05)
            self.flush("ai")
            if hung and call.outcome == "timeout":
                call.outcome, call.summary = await asyncio.get_running_loop().run_in_executor(None, self._verdict_after_hangup)
                call.emit("판정", f"끊긴 통화 {call.outcome}")
            tx.cancel()
            await asyncio.gather(tx, return_exceptions=True)
            if is_phone:
                await asyncio.get_running_loop().run_in_executor(None, phone.hangup)   # 전화부터 끊고 세션을 닫는다
            try:
                await self.send({"type": "session.close"})
                await asyncio.wait_for(self.closed.wait(), 5)
            except Exception:  # noqa: BLE001
                pass
            rx.cancel()
            await asyncio.gather(rx, return_exceptions=True)

    def _silence(self):
        """상대가 끊으면 이미 쌓아 둔 AI 음성(수 초 분량)까지 즉시 버리고 재생 장치를 닫는다."""
        self.cut = True
        self.held.clear()
        for q in (self.out_q, self.mon_q):
            while q is not None and not q.empty():
                try:
                    q.get_nowait()
                except queue.Empty:
                    break
        for p in (self.out, self.mon):
            try:
                os.killpg(p.pid, 15)
            except Exception:  # noqa: BLE001
                pass

    def _stop_source(self):
        try:
            os.killpg(self.src.pid, 15)
        except Exception:  # noqa: BLE001
            pass

    def cleanup(self):
        self.cut = True
        self.out_q.put(None)
        self._stop_source()
        if self.mon:
            self.mon_q.put(None)
            try:
                os.killpg(self.mon.pid, 15)
            except Exception:  # noqa: BLE001
                pass
        try:
            os.killpg(self.out.pid, 15)
        except Exception:  # noqa: BLE001
            pass
        for p in (self.src, self.out, self.mon):
            if p is not None:
                try:
                    p.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    p.kill(); p.wait(timeout=2)
                for stream in (p.stdin, p.stdout):
                    if stream is not None:
                        stream.close()
        for stream in (self.rec_rx, self.rec_tx):
            if stream is not None:
                stream.close()
        if self.rec_rx is not None:
            self._mix_recording()

    def _mix_recording(self):
        """상대(.rx.pcm, 왼쪽)와 AI(.tx.pcm, 오른쪽)를 스테레오 m4a 한 파일로 합치고 원본 pcm은 지운다. 기록(.md)에 파일 위치를 남긴다."""
        rx, tx, out = self.record + ".rx.pcm", self.record + ".tx.pcm", self.record + ".m4a"
        try:
            sizes = [os.path.getsize(p) for p in (rx, tx)]
            for p, n in zip((rx, tx), sizes):      # 두 줄 길이를 맞춰야 긴 쪽 끝까지 합쳐진다
                if n < max(sizes):
                    with open(p, "ab") as f:
                        f.write(bytes(max(sizes) - n))
            raw = ["-f", "s16le", "-ar", str(RATE), "-ac", "1"]
            r = subprocess.run(["ffmpeg", "-y", "-v", "error", *raw, "-i", rx, *raw, "-i", tx, "-filter_complex", "[0][1]join=inputs=2:channel_layout=stereo", "-c:a", "aac", "-b:a", "64k", out],
                               capture_output=True, timeout=60)
            if r.returncode == 0 and os.path.getsize(out) > 0:
                os.remove(rx); os.remove(tx)
                self.call.emit("녹음", os.path.abspath(out))
            else:
                self.call.emit("오류", f"녹음 합치기 실패 {r.stderr.decode(errors='ignore')[:100]}")
        except Exception as e:  # noqa: BLE001
            self.call.emit("오류", f"녹음 합치기 {repr(e)[:100]}")


def ensure_voice(call, cfg, cfg_path, api_key, voice):
    """커스텀 음성은 API 프로젝트별로 저장된다. 키를 바꿔 음성이 없으면 같은 설명문으로 다시 만들어 설정에 저장한다."""
    hdr = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    try:
        urllib.request.urlopen(urllib.request.Request(f"https://api.openai.com/v1/audio/voices/{voice}", headers=hdr), timeout=15)
        return voice
    except urllib.error.HTTPError as e:
        if e.code != 404:
            return voice
    except OSError:
        return voice
    try:
        body = json.dumps({"type": "prompt", "name": "ko_m_seoul", "prompt": cfg.get("voice_prompt", "")}).encode()
        new = json.load(urllib.request.urlopen(urllib.request.Request("https://api.openai.com/v1/audio/voices", data=body, headers=hdr), timeout=120))["id"]
    except Exception as e:  # noqa: BLE001
        raise RuntimeError("설정한 음성을 만들지 못했어요. 음성을 임의로 바꾸지 않습니다") from e
    saved = json.load(open(cfg_path)) if os.path.exists(cfg_path) else {}
    saved["voice"] = f"live:{cfg['voice'].split(':')[1]}:{new}"
    json.dump(saved, open(cfg_path, "w"), ensure_ascii=False, indent=2)
    call.emit("음성", f"이 API 프로젝트에 음성이 없어 새로 만들었어요 ({new})")
    return new


def run_call(call, a, cfg, api_key, llm, arsear, finish, cfg_path):
    """연습이면 마이크·스피커, 전화면 통화 소리 탭·BlackHole을 연결해 GPT-Live 세션을 돌린다."""
    if call.done.is_set():
        return finish(call, call.outcome, call.summary)
    _, model, voice = (cfg.get("voice") or "live:gpt-live-1:cedar").split(":")
    backend = cfg["llm"].partition(":")[2] or "gpt-6-luna"
    if voice.startswith("voice_"):
        try:
            voice = ensure_voice(call, cfg, cfg_path, api_key, voice)
        except Exception as e:
            call.emit("오류", f"음성 준비 실패: {e}")
            return finish(call, "failed", "설정한 음성을 준비하지 못했어요")
    if call.done.is_set():
        return finish(call, call.outcome, call.summary)
    if a.practice:
        mic = ["-t", "coreaudio", cfg["mic"]] if cfg.get("mic") else ["-d"]
        src = ["sox", "-q", "-V1", *mic, "-r", str(RATE), "-c", "1", "-b", "16", "-e", "signed", "-t", "raw", "-"]
        out = ["sox", "-q", "--buffer", "4096", *RAW, "-", "-r", str(cfg.get("out_rate", 48000)), "-d"]   # 스피커 장치 샘플레이트로 맞춘다
        env = os.environ.copy()
        echo = not cfg.get("headphones")
    else:
        ok, msg = phone.set_mic(PHONE_MIC); call.emit("마이크", msg)
        if not ok:
            return finish(call, "failed", "전화 앱 마이크 설정 실패")
        src = [arsear, str(MAX_CALL + 15), "TAP", "PCMOUT"]
        out = ["sox", "-q", "--buffer", "1024", *RAW, "-", "-t", "coreaudio", SPEAK_DEV]
        env = {**os.environ, "AICALL_RATE": str(RATE), "AICALL_HEAR": "1" if cfg.get("monitor") else "0"}   # 끄면 상대 목소리도 스피커로 안 나간다
        echo = False                           # 통화 소리 탭에는 내 목소리가 섞이지 않는다
        if call.done.is_set():
            phone.set_mic("시스템 설정값 사용")
            return finish(call, call.outcome, call.summary)
        ok, msg = phone.dial(call.num); call.emit("발신", msg)
        if not ok:
            phone.set_mic("시스템 설정값 사용")
            return finish(call, "failed", f"발신 실패: {msg[:80]}")
    s = Session(call, api_key, model, voice, backend, src, env, out, echo, llm)
    s.voice_prompt = cfg.get("voice_prompt", "")
    s.gate = not a.practice and cfg.get("gate", True)
    s.record = call.logp[:-3] if cfg.get("record") else None
    if not a.practice:                        # 연습은 이미 스피커로 나온다. 통화는 늘 열어 두고 앱 단추(mon_on)로 켜고 끈다
        s.monitor = ["sox", "-q", "--buffer", "4096", *RAW, "-", "-r", str(cfg.get("out_rate", 48000)), "-d"]
        s.mon_on = bool(cfg.get("monitor"))
    call.live_session = s                     # 앱 스피커 단추가 이 세션의 mon_on을 바꾼다 (call.live는 받아쓰기 중간 글자라 다른 이름)
    try:
        asyncio.run(s.run(not a.practice))
    except Exception as e:  # noqa: BLE001
        call.emit("오류", f"세션 {repr(e)[:160]}")
        if call.outcome == "timeout":
            call.outcome, call.summary = "failed", "음성 세션 오류"
    finally:
        s.cleanup()
        if not a.practice:
            phone.hangup(); phone.set_mic("시스템 설정값 사용")
    return finish(call, call.outcome, call.summary)
