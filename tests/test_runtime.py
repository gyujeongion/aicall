"""통화 수명·취소·CLI 회귀 시험. 네트워크·실제 전화 없음."""
import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
TEST_DATA = tempfile.TemporaryDirectory(prefix='aicall-runtime-')
os.environ['AICALL_DATA'] = TEST_DATA.name
os.environ['OPENAI_API_KEY'] = 'offline-test-only'
os.environ['DEEPGRAM_API_KEY'] = 'offline-test-only'
import agent
import live
import mcp_server
loader = importlib.machinery.SourceFileLoader('aicall_cli', str(ROOT / 'aicall'))
spec = importlib.util.spec_from_loader(loader.name, loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)

class RuntimeTests(unittest.TestCase):
    def call(self, **kw):
        args = dict(number='000', task='시험', extra='', speak=True, handoff=True,
                    brain='auto', practice=False, replay=None, request_id='test-request')
        args.update(kw)
        c = agent.Call(argparse.Namespace(**args), dict(agent.DEFAULTS, owner_name="사용자", owner_phone="01012345678"))
        self.addCleanup(c.logf.close)
        return c

    def test_cancel_blocks_late_actions(self):
        c = self.call()
        c.end('failed', '직접 끊었어요')
        with patch.object(agent.phone, 'dtmf', return_value=(True, 'OK')) as dtmf, \
             patch.object(agent.subprocess, 'run') as run:
            c.press('1')
            c.say('늦은 말')
            c.handoff('늦은 요청')
        dtmf.assert_not_called()
        run.assert_not_called()

    def test_first_terminal_result_wins(self):
        c = self.call()
        c.end('failed', '직접 끊었어요')
        c.end('success', '늦게 도착한 판정')
        self.assertEqual((c.outcome, c.summary), ('failed', '직접 끊었어요'))

    def test_cleanup_failure_does_not_replace_user_cancel(self):
        c = self.call()
        c.cancel()
        with patch.object(agent.time, 'sleep'):
            agent.finish(c, 'failed', '늦게 도착한 준비 오류')
        self.assertEqual(c.summary, '직접 끊었어요')

    def test_user_cancel_silences_live_session(self):
        c = self.call()
        s = live.Session(c, '', 'm', 'v', 'b', [], {}, [], False, None)
        c.live_session = s
        s._play(b'\x00\x40' * 2400)
        c.cancel()
        self.assertTrue(s.cut)
        self.assertTrue(s.out_q.empty())
        self.assertTrue(c.cancelled)

    def test_handoff_off_ends_needs_user(self):
        c = self.call(handoff=False)
        with patch.object(agent.subprocess, 'run') as run:
            c.handoff('민감정보 입력 필요')
        run.assert_not_called()
        self.assertTrue(c.done.is_set())
        self.assertEqual(c.outcome, 'needs_user')

    def test_cancel_before_voice_setup_never_dials(self):
        c = self.call()
        c.end('failed', '직접 끊었어요')
        with patch.object(live.phone, 'dial') as dial, \
             patch.object(live, 'ensure_voice', return_value='voice_mock'), \
             patch.object(live.phone, 'set_mic', return_value=(True, 'OK')), \
             patch.object(live.asyncio, 'run') as run:
            def finish(call, outcome, summary): return outcome
            self.assertEqual(live.run_call(c, c.a, c.cfg, '', None, 'unused', finish, 'unused'), 'failed')
        dial.assert_not_called()
        run.assert_not_called()

    def test_cli_pid_zero_is_not_live_engine(self):
        self.assertFalse(cli.alive(0))
        self.assertFalse(cli.alive(-1))

    def test_stale_judge_rejected_after_user_was_flushed(self):
        c = self.call()
        s = live.Session(c, '', 'm', 'v', 'b', [], {}, [], False, None)
        def judge(*a, **kw):
            s.heard = '아직 이야기 중입니다'
            s.heard_at = time.time() + .01
            s.flush('user')
            return {'outcome': 'success', 'summary': '이전 발화 기준 판정'}
        s._ask_judge = judge
        s._judge()
        self.assertFalse(c.done.is_set())

    def test_cli_waits_for_its_own_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'state.json'
            path.write_text(json.dumps({'pid': os.getpid(), 'request_id': 'other'}))
            with patch.object(cli, 'STATE', str(path)):
                self.assertIsNone(cli.state(request_id='mine'))
                self.assertEqual(cli.state(request_id='other')['request_id'], 'other')

    def test_mcp_bad_tool_does_not_kill_server(self):
        bad = mcp_server.handle({'id': 1, 'method': 'tools/call', 'params': {'name': 'call_start', 'arguments': {}}})
        self.assertTrue(bad['result']['isError'])
        good = mcp_server.handle({'id': 2, 'method': 'tools/list'})
        self.assertEqual(len(good['result']['tools']), 6)

    def test_mcp_cli_timeout_becomes_tool_error(self):
        import subprocess
        with patch.object(mcp_server, 'run', side_effect=subprocess.TimeoutExpired('test', 120)):
            result = mcp_server.handle({'id': 1, 'method': 'tools/call', 'params': {'name': 'call_status'}})
        self.assertTrue(result['result']['isError'])

    def test_stale_audio_dropped_even_after_caller_quiet(self):
        c = self.call()
        s = live.Session(c, '', 'm', 'v', 'b', [], {}, [], False, None)
        s.gate = True
        c.human = True
        s.held = bytearray(b'\x00\x40' * 2400)
        s.held_at = time.time() - live.MAX_HOLD - 1
        s.last_voice = 0
        s._release()
        self.assertTrue(s.out_q.empty())
        self.assertFalse(s.held)

    def test_cleanup_after_partial_start(self):
        c = self.call()
        s = live.Session(c, '', 'm', 'v', 'b', [], {}, [], False, None)
        s.cleanup()

    def test_events_waits_for_final_result_not_stop_request(self):
        import urllib.request
        c = self.call()
        port = agent.serve(c)
        c.end('failed', '직접 끊었어요')
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/events?since=0&wait=0') as response:
            result = json.load(response)
        self.assertFalse(result['ended'])
        with patch.object(agent.time, 'sleep'):
            agent.finish(c, c.outcome, c.summary)
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/events?since=0&wait=0') as response:
            result = json.load(response)
        self.assertTrue(result['ended'])
        self.assertEqual(result['events'][-1]['tag'], '결과')

if __name__ == '__main__':
    unittest.main(verbosity=2)
