"""live.Session 출구 게이트 단위 시험 (네트워크·전화 없음)."""
import os, sys, time, threading

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import live

R = live.RATE * 2
VOICE = (b"\x00\x40" * (R // 20))[: R // 10]   # 0.1초 말소리
QUIET = bytes(R // 10)                         # 0.1초 무음


class Call:
    def __init__(self, num="0212345678"):           # 기본은 유선 번호(예전 판별 경로). 휴대폰 경로는 따로 시험
        self.events, self.human, self.ars, self.convo, self.num = [], False, False, [], num
        self.done = threading.Event()
    def on_interim(self, t): pass
    def emit(self, k, v): self.events.append((k, v))


def session():
    s = live.Session(Call(), "", "m", "v", "b", [], {}, [], False, None)
    s.gate = True
    return s


def played(s):
    n = 0
    while not s.out_q.empty():
        n += len(s.out_q.get())
    return n


def test_holds_while_caller_speaks():
    s = session(); s.call.human = True; s.last_voice = time.time()
    s._route(VOICE); s._release()
    assert played(s) == 0 and len(s.held) == len(VOICE)


def test_releases_whole_utterance_after_quiet():
    s = session(); s.call.human = True; s.last_voice = time.time()
    for b in (QUIET, VOICE, VOICE):
        s._route(b)
    assert len(s.held) == 2 * len(VOICE), "말 시작 전 무음은 버린다"
    s.last_voice = time.time() - live.QUIET_SEC - 0.01; s._release()
    assert played(s) == 2 * len(VOICE) and s.talking and not s.held


def test_started_speech_is_not_cut_by_caller():
    s = session(); s.call.human = True; s.talking = True; s.last_voice = time.time()
    s._route(VOICE); assert played(s) == len(VOICE)


def test_talking_ends_after_silence():
    s = session(); s.call.human = True; s.talking = True
    for _ in range(int(live.END_SILENCE * 10) + 2):
        s._route(QUIET)
    assert not s.talking


def test_stale_speech_dropped():
    s = session(); s.call.human = True; s.last_voice = time.time(); s._route(VOICE)
    s.held_at = time.time() - live.MAX_HOLD - 1; s._release()
    assert not s.held and played(s) == 0


def test_gate_off_passes_through():
    s = session(); s.gate = False; s.last_voice = time.time()
    s._route(VOICE); assert played(s) == len(VOICE)


def test_monitor_gets_same_audio():
    import queue
    s = session(); s.gate = False; s.mon_q = queue.Queue(); s.mon_on = True
    s._route(VOICE); assert s.mon_q.get_nowait() == VOICE
    s.mon_on = False                          # 통화 중 앱에서 스피커를 끄면 더 보내지 않는다
    s._route(VOICE); assert s.mon_q.empty()


def test_ars_drops_all_ai_voice():
    s = session(); s.call.ars = True; s.last_voice = 0.0
    s._route(VOICE); s._release()
    assert not s.held and played(s) == 0


def test_unknown_holds_until_human():
    s = session(); s.last_voice = 0.0
    s._route(VOICE); s._release()
    assert played(s) == 0 and s.held
    s.call.human = True; s._release()
    assert played(s) == len(VOICE)


def test_ars_ignores_voice_model_tools():
    import asyncio
    s = session(); s.call.ars = True; sent = []
    async def send(o): sent.append(o)
    s.send = send
    asyncio.run(s.tool({"name": "press_keypad", "call_id": "c", "arguments": '{"keys": "1"}'}))
    assert len(sent) == 1 and "시스템" in sent[0]["item"]["output"] and "presses" not in s.call.__dict__


def test_utterance_goes_to_engine():
    s = session(); got = []
    s.call.on_final = got.append; s.call.convo = ["x"]
    s.heard = "일 번을 눌러주세요"; s.last_voice = 0.0; s.heard_at = 0.0; s._utterance()
    assert got == ["일 번을 눌러주세요"]


def test_fast_human_pickup():
    s = session(); acts = []
    s.call.act = acts.append; s.call.convo = []
    s.heard = "여보세요?"; s.last_voice = 0.0; s.heard_at = 0.0; s._utterance()
    assert acts == [{"action": "human"}]


def test_looks_human():
    for x in ("여보세요?", "네 우오하나입니다.", "감사합니다 스시코우지입니다. 어떻게 도와드릴까요?", "네"):
        assert live.looks_human(x), x
    for x in ("안녕하십니까?", "안녕하세요 SK텔레콤입니다", "고객센터입니다", "수신거부를 원하시면 일 번을 눌러주세요"):
        assert not live.looks_human(x), x


def test_unanswered_ends_failed():
    for x in ("성사섬으로 연결되며,띠 소리 후 통화료가 부과됩니다", "음성 녹음은 1번, 연락 번호를 남기시려면 2번", "전원이 꺼져 있습니다", "지금은 통화 중입니다"):
        s = session(); ended = []
        s.call.end = lambda o, m, e=ended: e.append(o); s.call.convo = []
        s.heard = x; s.last_voice = 0.0; s.heard_at = 0.0; s._utterance()
        assert ended == ["failed"], x
    for x in ("여보세요", "네 사무실입니다", "아 제가 지금 통화 중이라서요", "지금 전화를 받을 수 없어서요"):
        assert not live.unanswered(x), x
    assert live.unanswered("고객이 전화를 받지 않아 소리샘으로 연결됩니다")


def test_judge_waits_for_new_reply_to_finish():
    """새 대답의 첫 글자가 음성보다 먼저 와도 '말을 마쳤다'로 보지 않는다 (11-13 끝인사 잘림의 원인)."""
    s = session(); now = time.time()
    s.speech_until = now - 5                  # 직전 발화는 오래전에 끝났다
    s.said_at, s.audio_at = now, 0.0          # 방금 새 대답 첫 글자 도착
    assert not s.ai_idle(now)
    assert s.ai_idle(now + 1.5)


def test_judge_result_dropped_if_ai_spoke_meanwhile():
    s = session(); ended = []
    s.call.end = lambda o, m: ended.append(o); s.call.a = type("A", (), {"task": "t"})()
    def llm(path, body):
        s.said_at, s.ai_pending = time.time() + 0.01, True    # 판정하는 사이 AI가 다시 말함
        return {"choices": [{"message": {"tool_calls": [{"function": {"name": "end_call", "arguments": '{"outcome":"success","summary":"x"}'}}]}}]}
    s.llm = llm
    s._judge()
    assert ended == [] and ("판정", "새 발화가 있어 종료 보류") in s.call.events


def test_hangup_by_caller_is_judged_from_record():
    s = session(); s.call.a = type("A", (), {"task": "t"})()
    s.call.convo = ["AI말함: 안녕하세요", "상대: 네 알겠습니다 감사합니다"]
    s.llm = lambda p, b: {"choices": [{"message": {"tool_calls": [{"function": {"name": "end_call", "arguments": '{"outcome":"success","summary":"전달했어요."}'}}]}}]}
    assert s._verdict_after_hangup() == ("success", "상대가 먼저 끊음 — 전달했어요.")
    s.call.convo = ["AI말함: 안녕하세요"]                     # 상대 말이 없으면 판정 없이 실패
    assert s._verdict_after_hangup()[0] == "failed"



def test_hangup_silences_queued_voice():
    """상대가 끊으면 쌓아 둔 AI 음성을 버리고 더 내보내지 않는다 (11-14 끊긴 뒤에도 말이 이어짐)."""
    s = session(); s.call.human = True; s.out = s.mon = None
    for _ in range(30):
        s._play(VOICE)
    s._silence(); s._play(VOICE)
    assert played(s) == 0


if __name__ == "__main__":
    fns = [v for k, v in list(globals().items()) if k.startswith("test_")]
    for f in fns:
        f(); print("PASS", f.__name__)
    print(f"{len(fns)}/{len(fns)} 통과")
