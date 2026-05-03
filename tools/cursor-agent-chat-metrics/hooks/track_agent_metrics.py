#!/usr/bin/env python3
"""
Cursor Agent chat metrics — hook script.

Persists per-conversation_id stats in ~/.cursor/agent-chat-metrics/state.json
and mirrors the active chat to current.json for the VS Code extension.

Uses hook common fields (Cursor docs): conversation_id, model, transcript_path.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATE_DIR = Path.home() / ".cursor" / "agent-chat-metrics"
STATE_FILE = STATE_DIR / "state.json"
CURRENT_FILE = STATE_DIR / "current.json"
CONFIG_FILE = STATE_DIR / "config.json"

DEFAULT_CONFIG: dict[str, Any] = {
    "warn_turn_min": 10,
    "warn_turn_max": 15,
    "notify_macos": True,
    "track_only_composer_modes": ["agent"],
    "price_per_million_input_usd": 1.25,
    "price_per_million_output_usd": 6.0,
    "chars_per_token": 4.0,
    "include_thinking_as_output": False,
    "resync_from_transcript_on_session_start": True,
    "model_price_overrides": [
        {"substring": "opus", "input_per_million": 5.0, "output_per_million": 25.0},
        {"substring": "sonnet", "input_per_million": 3.0, "output_per_million": 15.0},
        {"substring": "gpt-5.5", "input_per_million": 5.0, "output_per_million": 30.0},
        {"substring": "gpt-5", "input_per_million": 1.25, "output_per_million": 10.0},
        {"substring": "composer", "input_per_million": 0.5, "output_per_million": 2.5},
        {"substring": "auto", "input_per_million": 1.25, "output_per_million": 6.0},
    ],
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return default


def save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def load_config() -> dict[str, Any]:
    merged = dict(DEFAULT_CONFIG)
    user_cfg = load_json(CONFIG_FILE, {})
    if isinstance(user_cfg, dict):
        merged.update(user_cfg)
    return merged


def resolve_prices(model: str | None, config: dict[str, Any]) -> tuple[float, float]:
    default_in = float(config.get("price_per_million_input_usd", 1.25))
    default_out = float(config.get("price_per_million_output_usd", 6.0))
    if not model:
        return default_in, default_out
    ml = model.lower()
    overrides = config.get("model_price_overrides") or []
    if isinstance(overrides, list):
        for row in overrides:
            if not isinstance(row, dict):
                continue
            sub = str(row.get("substring", "")).lower()
            if sub and sub in ml:
                return (
                    float(row.get("input_per_million", default_in)),
                    float(row.get("output_per_million", default_out)),
                )
    return default_in, default_out


def recompute_cost_from_char_totals(
    user_chars: int,
    agent_chars: int,
    model: str | None,
    config: dict[str, Any],
) -> float:
    chars_per_tok = float(config.get("chars_per_token", 4.0))
    denom = max(chars_per_tok, 0.1)
    in_price, out_price = resolve_prices(model, config)
    in_tok = user_chars / denom
    out_tok = agent_chars / denom
    return in_tok * (in_price / 1_000_000.0) + out_tok * (out_price / 1_000_000.0)


def extract_message_text(obj: dict[str, Any]) -> str:
    parts: list[str] = []
    msg = obj.get("message")
    if isinstance(msg, str):
        parts.append(msg)
    elif isinstance(msg, dict):
        content = msg.get("content")
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    t = block.get("text")
                    if isinstance(t, str):
                        parts.append(t)
                    elif block.get("type") == "text" and isinstance(block.get("value"), str):
                        parts.append(block["value"])
                elif isinstance(block, str):
                    parts.append(block)
        txt = msg.get("text")
        if isinstance(txt, str):
            parts.append(txt)
    top = obj.get("content")
    if isinstance(top, str):
        parts.append(top)
    return "".join(parts)


def parse_cursor_transcript_jsonl(path: Path) -> dict[str, int] | None:
    if not path.is_file():
        return None
    user_msgs = 0
    agent_msgs = 0
    user_chars = 0
    agent_chars = 0
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        role = str(obj.get("role") or obj.get("type") or "").lower()
        text = extract_message_text(obj)
        if role == "user":
            user_msgs += 1
            user_chars += len(text)
        elif role in ("assistant", "agent", "model"):
            agent_msgs += 1
            agent_chars += len(text)
    return {
        "user_prompts": user_msgs,
        "agent_messages": agent_msgs,
        "cumulative_user_chars": user_chars,
        "cumulative_agent_chars": agent_chars,
    }


def notify_macos(title: str, message: str) -> None:
    if sys.platform != "darwin":
        return
    safe_title = title.replace('"', "'")
    safe_msg = message.replace('"', "'")[:200]
    script = f'display notification "{safe_msg}" with title "{safe_title}"'
    try:
        subprocess.run(
            ["osascript", "-e", script],
            check=False,
            capture_output=True,
            timeout=5,
        )
    except OSError:
        pass


def conversation_id_from(data: dict[str, Any]) -> str:
    return (
        str(data.get("conversation_id") or "")
        or str(data.get("session_id") or "")
        or str(data.get("generation_id") or "")
        or "unknown-session"
    )


def fresh_conversation() -> dict[str, Any]:
    return {
        "user_prompts": 0,
        "agent_messages": 0,
        "cumulative_user_chars": 0,
        "cumulative_agent_chars": 0,
        "cumulative_thinking_chars": 0,
        "estimated_cumulative_cost_usd": 0.0,
        "proxy_tokens_cumulative": 0,
        "notified_milestones": [],
        "composer_mode": None,
        "last_model": None,
        "models_seen": [],
        "transcript_path_last": None,
        "started_at": utc_now(),
        "last_updated": utc_now(),
    }


def ensure_conversation(state: dict[str, Any], conv_id: str) -> dict[str, Any]:
    convs = state.setdefault("conversations", {})
    if conv_id not in convs:
        convs[conv_id] = fresh_conversation()
    return convs[conv_id]


def record_model(c: dict[str, Any], model: str | None) -> None:
    if not model:
        return
    c["last_model"] = model
    seen = c.setdefault("models_seen", [])
    if model not in seen:
        seen.append(model)


def write_current(conv_id: str, c: dict[str, Any], config: dict[str, Any]) -> None:
    chars_per_tok = float(config.get("chars_per_token", 4.0))
    proxy_tokens = int(
        (c.get("cumulative_user_chars", 0) + c.get("cumulative_agent_chars", 0))
        / max(chars_per_tok, 0.1)
    )
    in_p, out_p = resolve_prices(c.get("last_model"), config)
    payload = {
        "session_id": conv_id,
        "user_prompts": c.get("user_prompts", 0),
        "agent_messages": c.get("agent_messages", 0),
        "cumulative_user_chars": c.get("cumulative_user_chars", 0),
        "cumulative_agent_chars": c.get("cumulative_agent_chars", 0),
        "cumulative_thinking_chars": c.get("cumulative_thinking_chars", 0),
        "proxy_tokens_cumulative": proxy_tokens,
        "estimated_cumulative_cost_usd": round(
            float(c.get("estimated_cumulative_cost_usd", 0.0)), 6
        ),
        "last_model": c.get("last_model"),
        "models_seen": c.get("models_seen", []),
        "transcript_path_last": c.get("transcript_path_last"),
        "composer_mode": c.get("composer_mode"),
        "last_updated": c.get("last_updated"),
        "pricing_note": (
            f"Heuristic $ using last_model={c.get('last_model')!r} "
            f"→ ${in_p}/M in, ${out_p}/M out (override by substring in config.json)."
        ),
        "context_window_note": (
            "Cursor does not expose real context % to extensions. "
            "Use the meter in the chat UI. Proxy tokens = dialogue text only."
        ),
    }
    save_json(CURRENT_FILE, payload)


def maybe_notify_turn_warning(c: dict[str, Any], config: dict[str, Any]) -> None:
    if not config.get("notify_macos", True):
        return
    n = int(c.get("user_prompts", 0))
    lo = int(config.get("warn_turn_min", 10))
    hi = int(config.get("warn_turn_max", 15))
    milestones = c.setdefault("notified_milestones", [])
    to_fire: list[tuple[str, str]] = []
    if lo <= n <= hi:
        key = f"range-{n}"
        if key not in milestones:
            milestones.append(key)
            to_fire.append(
                (
                    "Cursor agent — turn budget",
                    f"You have sent {n} prompts in this chat. "
                    f"Consider a fresh chat before ~{hi} to limit context cost.",
                )
            )
    elif n == hi + 1:
        key = "over-max"
        if key not in milestones:
            milestones.append(key)
            to_fire.append(
                (
                    "Cursor agent — strong nudge",
                    f"{n} prompts — starting a new chat usually saves tokens.",
                )
            )
    for title, msg in to_fire:
        notify_macos(title, msg)


def should_track_session(
    config: dict[str, Any], composer_mode: str | None
) -> bool:
    modes = config.get("track_only_composer_modes")
    if not modes:
        return True
    if composer_mode is None:
        return True
    return composer_mode in modes


def try_resync_transcript(
    transcript_path: str | None,
    c: dict[str, Any],
    model_hint: str | None,
    config: dict[str, Any],
) -> None:
    if not transcript_path or not config.get(
        "resync_from_transcript_on_session_start", True
    ):
        return
    p = Path(transcript_path).expanduser()
    stats = parse_cursor_transcript_jsonl(p)
    if not stats:
        return
    c["transcript_path_last"] = str(p)
    c["user_prompts"] = stats["user_prompts"]
    c["agent_messages"] = stats["agent_messages"]
    c["cumulative_user_chars"] = stats["cumulative_user_chars"]
    c["cumulative_agent_chars"] = stats["cumulative_agent_chars"]
    if model_hint:
        record_model(c, model_hint)
    m = c.get("last_model")
    c["estimated_cumulative_cost_usd"] = recompute_cost_from_char_totals(
        int(c["cumulative_user_chars"]),
        int(c["cumulative_agent_chars"]),
        str(m) if m else None,
        config,
    )
    c["last_updated"] = utc_now()


def handle_session_start(data: dict[str, Any], state: dict[str, Any], config: dict[str, Any]) -> None:
    sid = str(data.get("session_id") or uuid.uuid4())
    composer_mode = data.get("composer_mode")
    model = data.get("model")
    transcript_path = data.get("transcript_path")
    state["active_session_id"] = sid
    convs = state.setdefault("conversations", {})
    is_new = sid not in convs
    if is_new:
        convs[sid] = fresh_conversation()
    c = convs[sid]
    if composer_mode:
        c["composer_mode"] = composer_mode
    record_model(c, str(model) if model else None)
    if not should_track_session(config, composer_mode or c.get("composer_mode")):
        c["_skipped_mode"] = True
    else:
        c.pop("_skipped_mode", None)
    # Resync when returning to an existing tab, or when a new session already has a transcript file.
    if transcript_path:
        try_resync_transcript(
            str(transcript_path),
            c,
            str(model) if model else None,
            config,
        )
    save_json(STATE_FILE, state)
    write_current(sid, c, config)


def handle_before_submit(
    data: dict[str, Any], state: dict[str, Any], config: dict[str, Any]
) -> None:
    conv_id = conversation_id_from(data)
    active = state.get("active_session_id")
    if active and conv_id == "unknown-session":
        conv_id = str(active)
    c = ensure_conversation(state, conv_id)
    if c.get("_skipped_mode"):
        print(json.dumps({"continue": True}))
        return

    model = data.get("model")
    record_model(c, str(model) if model else None)
    transcript_path = data.get("transcript_path")
    if transcript_path:
        c["transcript_path_last"] = str(Path(transcript_path).expanduser())

    prompt = str(data.get("prompt") or "")
    c["user_prompts"] = int(c.get("user_prompts", 0)) + 1
    c["cumulative_user_chars"] = int(c.get("cumulative_user_chars", 0)) + len(prompt)
    in_price, _out_price = resolve_prices(c.get("last_model"), config)
    chars_per_tok = float(config.get("chars_per_token", 4.0))
    est_in_tok = len(prompt) / max(chars_per_tok, 0.1)
    c["estimated_cumulative_cost_usd"] = float(
        c.get("estimated_cumulative_cost_usd", 0.0)
    ) + (est_in_tok * (in_price / 1_000_000.0))
    c["last_updated"] = utc_now()
    state["active_session_id"] = conv_id
    save_json(STATE_FILE, state)
    write_current(conv_id, c, config)
    maybe_notify_turn_warning(c, config)
    print(json.dumps({"continue": True}))


def handle_after_agent_response(
    data: dict[str, Any], state: dict[str, Any], config: dict[str, Any]
) -> None:
    conv_id = conversation_id_from(data)
    active = state.get("active_session_id")
    if active and conv_id == "unknown-session":
        conv_id = str(active)
    c = ensure_conversation(state, conv_id)
    if c.get("_skipped_mode"):
        return

    model = data.get("model")
    record_model(c, str(model) if model else None)

    text = str(data.get("text") or "")
    c["agent_messages"] = int(c.get("agent_messages", 0)) + 1
    c["cumulative_agent_chars"] = int(c.get("cumulative_agent_chars", 0)) + len(text)
    _in_price, out_price = resolve_prices(c.get("last_model"), config)
    chars_per_tok = float(config.get("chars_per_token", 4.0))
    est_out_tok = len(text) / max(chars_per_tok, 0.1)
    c["estimated_cumulative_cost_usd"] = float(
        c.get("estimated_cumulative_cost_usd", 0.0)
    ) + (est_out_tok * (out_price / 1_000_000.0))
    c["last_updated"] = utc_now()
    state["active_session_id"] = conv_id
    save_json(STATE_FILE, state)
    write_current(conv_id, c, config)


def handle_after_agent_thought(
    data: dict[str, Any], state: dict[str, Any], config: dict[str, Any]
) -> None:
    if not config.get("include_thinking_as_output", False):
        return
    conv_id = conversation_id_from(data)
    active = state.get("active_session_id")
    if active and conv_id == "unknown-session":
        conv_id = str(active)
    c = ensure_conversation(state, conv_id)
    if c.get("_skipped_mode"):
        return
    model = data.get("model")
    record_model(c, str(model) if model else None)
    text = str(data.get("text") or "")
    c["cumulative_thinking_chars"] = int(c.get("cumulative_thinking_chars", 0)) + len(
        text
    )
    _in_price, out_price = resolve_prices(c.get("last_model"), config)
    chars_per_tok = float(config.get("chars_per_token", 4.0))
    est_out_tok = len(text) / max(chars_per_tok, 0.1)
    c["estimated_cumulative_cost_usd"] = float(
        c.get("estimated_cumulative_cost_usd", 0.0)
    ) + (est_out_tok * (out_price / 1_000_000.0))
    c["last_updated"] = utc_now()
    save_json(STATE_FILE, state)
    write_current(conv_id, c, config)


def handle_session_end(data: dict[str, Any], state: dict[str, Any], _config: dict[str, Any]) -> None:
    sid = data.get("session_id")
    if sid and state.get("active_session_id") == sid:
        state["active_session_id"] = None
    save_json(STATE_FILE, state)


def main() -> int:
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        print(json.dumps({"continue": True}))
        return 0

    event = (
        os.environ.get("CURSOR_AGENT_METRICS_EVENT", "").strip()
        or str(data.get("hook_event_name") or "")
    )
    config = load_config()
    state = load_json(STATE_FILE, {"conversations": {}})
    if not isinstance(state, dict):
        state = {"conversations": {}}

    try:
        if event == "sessionStart":
            handle_session_start(data, state, config)
            print(json.dumps({}))
        elif event == "sessionEnd":
            handle_session_end(data, state, config)
            print(json.dumps({}))
        elif event == "beforeSubmitPrompt":
            handle_before_submit(data, state, config)
        elif event == "afterAgentResponse":
            handle_after_agent_response(data, state, config)
            print(json.dumps({}))
        elif event == "afterAgentThought":
            handle_after_agent_thought(data, state, config)
            print(json.dumps({}))
        else:
            print(json.dumps({}))
    except Exception as exc:
        sys.stderr.write(f"[track_agent_metrics] error: {exc}\n")
        if event == "beforeSubmitPrompt":
            print(json.dumps({"continue": True}))
        else:
            print(json.dumps({}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
