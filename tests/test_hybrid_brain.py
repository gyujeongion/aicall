"""하이브리드 판단 시험: 실제 판단 모델이 상대 종류와 행동을 맞게 고르는지 본다 (API 호출, 전화 없음)."""
import argparse, os, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import agent

TASK = "SKT 고객센터. 말로 하는 AI 상담을 고르고 말씀해 달라고 하면 이번 달 요금이라고 말한다. 생년월일을 물으면 end_call(needs_user)로 끝낸다."
BOOK = "우오하나에 전화해 토요일 저녁 일곱 시 두 명 예약을 잡는다."
CASES = [
    ("메뉴", TASK, ["안녕하세요. SK텔레콤입니다. 말로 하는 AI 상담은 일 번, 버튼식 ARS는 이 번, 보이는 ARS는 삼 번을 눌러 주세요."], {"press"}),
    ("음성봇", TASK, ["안녕하세요 AI 상담사입니다. 원하는 상담을, 선택 약정 가입, 이번 달 요금과 같이 말씀해 주세요."], {"say"}),
    ("본인확인", TASK, ["고객 확인을 위해 가입 시 등록하신 생년월일 여섯 자리를 눌러 주세요."], {"end"}),
    ("수신거부", "광고 문자 수신거부", ["수신거부를 원하시면 일 번을 눌러주세요."], {"press"}),
    ("여보세요", BOOK, ["여보세요?"], {"human"}),
    ("가게받음", BOOK, ["네 우오하나입니다."], {"human"}),
    ("예약응대", BOOK, ["감사합니다 스시코우지입니다. 어떻게 도와드릴까요?"], {"human"}),
    ("연결대기", BOOK, ["잠시만 기다려 주세요. 상담원을 연결해 드리겠습니다."], {"wait"}),
    ("상담원", BOOK, ["잠시만 기다려 주세요. 상담원을 연결해 드리겠습니다.", "네 전화 받았습니다 상담원 김민지입니다."], {"human"}),
    ("인사만", "광고 문자 수신거부", ["안녕하십니까?"], {"wait"}),
]


def run(c):
    name, task, lines, want = c
    d = tempfile.mkdtemp(); os.makedirs(d + "/calls", exist_ok=True); os.chdir(d)
    a = argparse.Namespace(number="114", task=task, extra="", speak=True, handoff=False, brain="auto", practice=False, replay=None)
    call = agent.Call(a, dict(agent.DEFAULTS, owner_name="홍길동", owner_phone="010-1234-5678"))
    for l in lines:
        call.convo.append(f"상대: {l}")
    got = call.decide()
    return name, got["action"] in want, got


with ThreadPoolExecutor(5) as ex:
    res = list(ex.map(run, CASES * 2))
ok = sum(r[1] for r in res)
for name, good, got in res:
    print("PASS" if good else "FAIL", name, {k: v for k, v in got.items() if k != "heard"})
print(f"{ok}/{len(res)} 통과")
sys.exit(0 if ok == len(res) else 1)
