#!/usr/bin/env python3
"""AICall MCP 서버 (stdio) — aicall CLI를 MCP 도구로 노출한다. 클로드 코드·Codex 등에서 쓴다.
도구: call_start, call_events, call_press, call_say, call_end, call_status
"""
import json, os, subprocess, sys, threading
from concurrent.futures import ThreadPoolExecutor

AICALL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "aicall")
TOOLS = [
    {"name": "call_start", "description": "사용자 본인 휴대폰 번호로 전화를 건다. brain=auto면 앱 내장 LLM이 ARS·대화를 판단하고, external이면 call_events로 듣고 call_press/call_say/call_end로 직접 조종한다.",
     "inputSchema": {"type": "object", "properties": {
         "number": {"type": "string", "description": "전화번호(형식 자유) 또는 맥 연락처 이름"}, "purpose": {"type": "string", "description": "이번 전화의 목적·조건(날짜·인원 등)"},
         "speak": {"type": "boolean", "description": "자동 통화는 하이브리드. external에서 말하기가 필요하면 true"},
         "brain": {"type": "string", "enum": ["auto", "external"]},
         "handoff": {"type": "boolean", "description": "주민번호 등 본인 입력은 사용자에게 넘김 (기본 true)"}},
         "required": ["number", "purpose"]}},
    {"name": "call_events", "description": "통화 이벤트(상대 발화, AI 발화·키입력, 결과)를 가져온다. since는 이전 응답의 next. wait초 동안 새 이벤트를 기다린다.",
     "inputSchema": {"type": "object", "properties": {"since": {"type": "integer"}, "wait": {"type": "number"}}}},
    {"name": "call_press", "description": "통화 키패드(DTMF) 입력. ARS는 안내 도중에도 입력을 받는다.",
     "inputSchema": {"type": "object", "properties": {"keys": {"type": "string"}}, "required": ["keys"]}},
    {"name": "call_say", "description": "AI 음성으로 상대에게 말한다. external 통화는 speak=true 필요.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
    {"name": "call_end", "description": "통화를 끝내고 결과를 남긴다.",
     "inputSchema": {"type": "object", "properties": {"outcome": {"type": "string", "enum": ["success", "failed", "needs_user"]}, "summary": {"type": "string"}}, "required": ["outcome"]}},
    {"name": "call_status", "description": "진행 중인 통화 상태.", "inputSchema": {"type": "object", "properties": {}}},
]


def run(args):
    r = subprocess.run([sys.executable, AICALL, *args], capture_output=True, text=True, timeout=120)
    text = (r.stdout or r.stderr).strip()
    if r.returncode:
        raise RuntimeError(text or "CLI 요청 실패")
    return text


def call_tool(name, a):
    if name == "call_start":
        args = ["call", a["number"], a["purpose"], "--brain", a.get("brain", "auto")]
        if a.get("speak"): args.append("--speak")
        if a.get("handoff") is False: args.append("--no-handoff")
        return run(args)
    if name == "call_events":
        wait = min(20, max(0, float(a.get("wait", 10))))
        return run(["events", "--since", str(max(0, int(a.get("since", 0)))), "--wait", str(wait)])
    if name == "call_press":
        return run(["press", a["keys"]])
    if name == "call_say":
        return run(["say", a["text"]])
    if name == "call_end":
        return run(["end", a.get("outcome", "success"), a.get("summary", "")])
    if name == "call_status":
        return run(["status"])
    raise ValueError("알 수 없는 도구")


def handle(m):
    if not isinstance(m, dict):
        return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}}
    mid, method = m.get("id"), m.get("method")
    if mid is None:
        return None
    if method == "initialize":
        res = {"protocolVersion": m.get("params", {}).get("protocolVersion", "2025-06-18"),
               "capabilities": {"tools": {}}, "serverInfo": {"name": "aicall", "version": "0.1"}}
    elif method == "tools/list":
        res = {"tools": TOOLS}
    elif method == "tools/call":
        try:
            p = m["params"]
            args = p.get("arguments", {})
            if not isinstance(args, dict):
                raise ValueError("arguments는 객체여야 합니다")
            text = call_tool(p["name"], args)
            res = {"content": [{"type": "text", "text": text}]}
        except (KeyError, TypeError, ValueError, RuntimeError, OSError, subprocess.SubprocessError) as e:
            res = {"isError": True, "content": [{"type": "text", "text": str(e)}]}
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}}
    return {"jsonrpc": "2.0", "id": mid, "result": res}


def main():
    output_lock = threading.Lock()
    def respond(message):
        try:
            result = handle(message)
        except Exception:
            result = {"jsonrpc": "2.0", "id": message.get("id") if isinstance(message, dict) else None,
                      "error": {"code": -32603, "message": "Internal error"}}
        if result is not None:
            with output_lock:
                sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
                sys.stdout.flush()
    with ThreadPoolExecutor(max_workers=8) as executor:
        for line in sys.stdin:
            try:
                message = json.loads(line)
            except ValueError:
                with output_lock:
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}) + "\n")
                    sys.stdout.flush()
                continue
            executor.submit(respond, message)


if __name__ == "__main__":
    main()
