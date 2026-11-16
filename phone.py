"""macOS 27 전화 앱 조작 — phonectl(접근성 기반 Swift 도구)을 부르는 얇은 래퍼.
화면 좌표·마우스 이벤트 없이 전화 앱 키패드로 발신하고, 통화 중 배너 버튼으로 키패드·종료를 누른다."""
import os, subprocess, time

HERE = os.path.dirname(os.path.abspath(__file__))
CTL = os.path.join(HERE, "phonectl")


def _run(*args, timeout=30):
    r = subprocess.run([CTL, *args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout or "").strip(), (r.stderr or "").strip()


def dial(number):
    """전화 앱 키패드에 번호를 넣고 통화를 누른다. 입력값이 다르면 걸지 않는다. (성공, 메시지)"""
    rc, out, err = _run("dial", number, timeout=40)
    if rc != 0 and "통화 누르기" not in err:   # 직전 통화 화면이 남아 있으면 키패드가 늦게 뜬다. 통화 버튼을 누르기 전 실패만 다시 시도한다
        time.sleep(2.5)
        rc, out, err = _run("dial", number, timeout=40)
    return rc == 0, out if rc == 0 else err


def dtmf(keys):
    """통화 중 키패드 숫자 입력. (성공, 메시지)"""
    rc, out, err = _run("dtmf", keys)
    return rc == 0, out if rc == 0 else err


def hangup():
    rc, out, err = _run("hangup")
    return rc == 0, out if rc == 0 else err


def set_mic(device):
    """전화 앱 오디오 메뉴의 마이크 장치 선택. (성공, 메시지)"""
    rc, out, err = _run("mic", device)
    return rc == 0, out if rc == 0 else err


def state():
    """'incall' 또는 'idle'"""
    rc, out, _ = _run("state")
    return out.split(" ", 1)[0] if rc == 0 else "unknown"
