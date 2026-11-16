#!/usr/bin/env python3
"""전화 없이 판단·입력 로직을 합격 시험한다 (실제 LLM 호출, 키패드는 기록만).
실통화 기록(모니모·쏘카·KB)에서 뽑은 ARS 안내를 실시간 간격으로 재생하고, 눌린 키·결과가 기대와 같은지 본다.
  python3 tests/test_offline.py            # 전부
  python3 tests/test_offline.py kb_wrong   # 이름에 포함된 것만
"""
import json, os, re, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OPT = "광고 문자 수신거부 080 ARS. 내 번호로 광고성 문자 수신거부를 등록하고, 처리 완료 안내를 들으면 end(success)."
ME = "0 1 0 1 2 3 4 5 6 7 8"   # 시험용 가상 사용자 번호(config 01012345678)
OTHER = "0 1 0 9 8 7 6 5 4 3 2"

def F(t, dt=0.6): return {"k": "F", "t": t, "dt": dt}
def I(t, dt=0.35): return {"k": "I", "t": t, "dt": dt}

CASES = {
 "monimo_early_press": dict(events=[
    F("문자 메시지 수신 거부 등록 시스템입니다."),
    I("휴대폰 번호로"), I("휴대폰 번호로 마케팅 문자메시지"), I("휴대폰 번호로 마케팅 문자메시지 수신 거부를 원하시면"),
    I("휴대폰 번호로 마케팅 문자메시지 수신 거부를 원하시면 한 번을 눌러"),
    F("휴대폰 번호로 마케팅 문자메시지 수신 거부를 원하시면 일 번을 눌러 주십시오."),
    F("요청하신 모니모 마케팅 문자 메시지 수신 거부가 정상적으로 처리되었습니다. 감사합니다.", 5)],
    presses=["1"], outcome="success", early_before="일 번을 눌러 주십시오"),
 "misheard_keobeu_press": dict(events=[           # 실통화 전사에서 '수신 거부'가 '수신 커브'로 들린 사례
    I("수신가부를"), I("수신 커브를 원하시면"), I("수신 커브를 원하시면 한 번을 눌러"),
    F("수신 커브를 원하시면 한 번을 눌러 주십시오."),
    F("정상적으로 처리되었습니다.", 5)],
    presses=["1"], outcome="success", early_before="한 번을 눌러 주십시오"),
 "socar_press": dict(events=[
    F("쏘카 광고성 문자 수신거부 서비스입니다."),
    F("수신 거부를 원하시면 일 번을 눌러주시기 바랍니다."),
    F("귀하가 요청하신 쏘카 수신거부가 정상 처리되었습니다.", 5)],
    presses=["1"], outcome="success"),
 "kb_number_is_mine": dict(events=[
    F("국민의 평생 금융 파트너 KB국민은행입니다."),
    F("광고성 SMS 수신 거부를 위한 무료 전화 서비스입니다."),
    F(f"수신거부를 원하시는 휴대전화 번호가 {ME} 번이 맞으면 1 번 틀리면 2 번을 눌러주십시오."),
    F("수신거부가 정상적으로 처리되었습니다. 감사합니다.", 5)],
    presses=["1"], outcome="success"),
 "kb_number_is_NOT_mine": dict(events=[
    F(f"수신거부를 원하시는 휴대전화 번호가 {OTHER} 번이 맞으면 1 번 틀리면 2 번을 눌러주십시오.", 0.6)],
    presses=[], outcome=None, presses_ok=([], ["2"])),   # 남의 번호에 1을 누르면 실패 (틀리면 2번은 안전한 선택)
 "kb_pii_handoff": dict(handoff=True, events=[
    F("국민의 평생 금융 파트너 KB국민은행입니다."),
    F("고객님의 주민등록번호 앞 6 자리를 눌러주십시오.", 0.6)],
    presses=[], outcome=None, handoff_event=True),   # 누르지 않고 사용자에게 넘긴다
 "kb_pii_no_handoff": dict(events=[
    F("고객님의 주민등록번호 앞 6 자리를 눌러주십시오.", 0.6)],
    presses=[], outcome="needs_user"),
 "intro_only_wait": dict(events=[
    F("국민의 평생 금융 파트너 KB국민은행입니다."),
    F("본 ARS 서비스는 정보통신망 이용 촉진 및 정보 보호 등에 관한 법률에 따라 운영됩니다.")],
    presses=[], outcome=None),
 "nh_menu_full_list": dict(events=[                 # 2026-11-09 NH투자증권 실통화 안내. 조각만 듣고 1(조회)을 누르면 실패
    F("NH투자증권 SMS 수신거부 서비스입니다."),
    I("수신거부 등록 조회는 일 번"), I("수신거부 등록 조회는 1 번 수신거부 등록은"),
    F("수신거부 등록조회는 1 번 수신거부 등록은 2 번", 0.4),
    F("수신거부 등록해지는 3 번 nh 멤버스 정보 제0 동의 철회는 4 번", 0.8),
    F("방문 판매거부 등록 및 해지는 오 번을 눌러주십시오.", 0.8)],
    presses=["2"], outcome=None),
 "readback_hangul_digits": dict(events=[            # NH 실통화: 숫자를 한글로 읽어줌
    F("입력하신 번호는 공일공에 일이삼사에 오육칠팔 번입니다."),
    F("맞으면 1 번 틀리면 이 번을 눌러주십시오.", 0.6)],
    presses=["1"], outcome=None),
 "enter_own_number": dict(events=[
    F("수신거부를 원하시는 휴대폰 번호를 입력하시고 우물 정자를 눌러 주십시오.")],
    presses=["01012345678#"], outcome=None),
 "wrong_number_ends": dict(events=[
    F("내신 번호는 없는 번호이오니"), F("확인하시고 다시 걸어주시기 바랍니다.", 0.8)],
    presses=[], outcome="failed"),
 "menu_picks_optout_digit": dict(events=[
    F("상담원 연결은 1 번, 수신거부는 2 번, 서비스 안내는 3 번을 눌러주십시오.")],
    presses=["2"], outcome=None),
}

def run(name, c):
    d = tempfile.mkdtemp(prefix="aicall_t_")
    ev = os.path.join(d, "ev.jsonl")
    json.dump({"owner_name": "사용자", "owner_phone": "01012345678"}, open(os.path.join(d, "config.json"), "w"), ensure_ascii=False)   # 시험용 가상 사용자
    open(ev, "w").write("\n".join(json.dumps(e, ensure_ascii=False) for e in c["events"]))
    cmd = [sys.executable, os.path.join(HERE, "agent.py"), "0000000000", OPT, "--replay", ev] + (["--handoff"] if c.get("handoff") else [])
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=90, env={**os.environ, "AICALL_DATA": d})
    out = r.stdout
    presses = re.findall(r"AI누름: (\S+)", out)
    m = re.search(r"결과: (\w+)", out)
    outcome = m.group(1) if m else None
    errs = [l for l in out.splitlines() if "오류" in l]
    ok = (presses == c["presses"] or presses in [list(x) for x in c.get("presses_ok", ())]) and (c["outcome"] is None or outcome == c["outcome"]) and not errs
    if c.get("handoff_event"): ok = ok and "넘겨받기" in out
    if c.get("early_before"):                       # 안내를 끝까지 들은 뒤 3초 안에는 눌러야 한다 (LLM 판단 지연 허용치)
        def sec(l):
            h, m_, s_ = l.split()[0].split(":"); return int(h) * 3600 + int(m_) * 60 + int(s_)
        lines = out.splitlines()
        p_line = next((l for l in lines if "AI누름" in l), None)
        f_line = next((l for l in lines if "상대:" in l and c["early_before"] in l), None)
        ok = ok and bool(p_line and f_line) and sec(p_line) - sec(f_line) <= 3
    # 누르기까지 걸린 시간: 첫 '상대' 줄 ~ 첫 'AI누름' 줄
    t = [l.split()[0] for l in out.splitlines() if "AI누름" in l]
    return name, ok, presses, outcome, errs[:1], t[:1]

if __name__ == "__main__":
    pick = [a for a in sys.argv[1:]]
    cases = {k: v for k, v in CASES.items() if not pick or any(p in k for p in pick)}
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda kv: run(*kv), cases.items()))
    bad = 0
    for name, ok, presses, outcome, errs, t in res:
        print(("PASS" if ok else "FAIL"), name, "| 눌림:", presses, "| 결과:", outcome, "|", errs or "")
        bad += not ok
    print(f"\n{len(res) - bad}/{len(res)} 통과")
    sys.exit(1 if bad else 0)
