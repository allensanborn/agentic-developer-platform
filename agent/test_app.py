import io
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
