import io
import urllib.error
import json
from unittest import mock

import app


def test_chat_sends_identity_and_alias_and_reports_real_model(tmp_path, monkeypatch):
    token = tmp_path / "token"
    token.write_text("tok-1\n")
    monkeypatch.setattr(app, "TOKEN_FILE", str(token))
    reply = {"model": "llama3.2:3b", "usage": {"total_tokens": 7}, "choices": [{"message": {"content": "hi"}}]}
    with mock.patch("urllib.request.urlopen", side_effect=lambda *a, **k: io.BytesIO(json.dumps(reply).encode())) as urlopen:
        out = app.chat("smart", "hello")
        token.write_text("tok-2\n")  # rotated
        app.chat("smart", "hello")

    first, second = (c.args[0] for c in urlopen.call_args_list)
    assert first.get_header("Authorization") == "Bearer tok-1"
    assert second.get_header("Authorization") == "Bearer tok-2"
    assert json.loads(first.data)["model"] == "smart"
    assert out == {"alias": "smart", "model": "llama3.2:3b", "tokens": 7, "text": "hi"}


def test_mcp_message_reads_sse_and_plain_json():
    assert app.mcp_message(b'event: message\ndata: {"id": 2, "result": {}}\n\n') == {"id": 2, "result": {}}
    assert app.mcp_message(b'{"id": 2, "error": {"message": "unknown resource"}}')["error"]["message"] == "unknown resource"


class _Resp(io.BytesIO):
    def __init__(self, body: bytes, headers: dict | None = None):
        super().__init__(body)
        self.headers = headers or {}


def test_tool_sends_identity_and_session_and_reports_hidden_tools(tmp_path, monkeypatch):
    token = tmp_path / "token"
    token.write_text("tok\n")
    monkeypatch.setattr(app, "TOKEN_FILE", str(token))
    record = {"order_id": "ORD-1001", "status": "shipped"}
    found = b'data: {"result": {"content": [{"type": "text", "text": ' + json.dumps(json.dumps(record)).encode() + b"}]}}\n"
    hidden = urllib.error.HTTPError("u", 400, "Bad Request", {}, io.BytesIO(b'{"error": {"message": "unknown resource"}}'))
    replies = [_Resp(b"", {"mcp-session-id": "s1"}), _Resp(b""), _Resp(found),
               _Resp(b"", {"mcp-session-id": "s2"}), _Resp(b""), hidden]

    def urlopen(req, timeout):
        r = replies.pop(0)
        if isinstance(r, Exception):
            raise r
        return r

    with mock.patch("urllib.request.urlopen", side_effect=urlopen) as sent:
        assert app.tool("lookup_order", {"order_id": "ORD-1001"}) == {"tool": "lookup_order", "result": record}
        assert app.tool("initiate_return", {"order_id": "ORD-1001"}) == {"tool": "initiate_return", "error": "unknown resource"}

    reqs = [c.args[0] for c in sent.call_args_list]
    assert all(r.get_header("Authorization") == "Bearer tok" for r in reqs)
    assert reqs[0].get_header("Mcp-session-id") is None and reqs[2].get_header("Mcp-session-id") == "s1"
    assert json.loads(reqs[2].data)["params"] == {"name": "lookup_order", "arguments": {"order_id": "ORD-1001"}}
