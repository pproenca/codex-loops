#!/usr/bin/env python3
"""Deterministic Codex app-server stub for packaged conformance proofs."""

import json
import sys
import threading
import time


HOLD_LEASE_MARKER = "CODEX_LOOPS_CONFORMANCE_HOLD_LEASE"
WRITE_LOCK = threading.Lock()


def example(schema, field=None):
    if "const" in schema:
        return schema["const"]

    if schema.get("enum"):
        return schema["enum"][0]

    schema_type = schema.get("type")
    if isinstance(schema_type, list):
        schema_type = next((item for item in schema_type if item != "null"), "null")

    if schema_type == "object":
        properties = schema.get("properties", {})
        return {
            name: example(properties.get(name, {}), name)
            for name in schema.get("required", [])
        }

    if schema_type == "array":
        count = max(schema.get("minItems", 0), 0)
        return [example(schema.get("items", {}), field) for _ in range(count)]

    if schema_type == "boolean":
        return True

    if schema_type in ("integer", "number"):
        return max(schema.get("minimum", 1), 1)

    if schema_type == "null":
        return None

    return "conformance-ok"


def emit(message):
    with WRITE_LOCK:
        print(json.dumps(message, separators=(",", ":")), flush=True)


def response(request_id, result):
    emit({"id": request_id, "result": result})


def prompt_text(params):
    for item in params.get("input", []):
        if item.get("type") == "text":
            return item.get("text", "")
    return ""


def run_turn(thread_id, turn_id, params):
    prompt = prompt_text(params)
    schema = params.get("outputSchema")

    if HOLD_LEASE_MARKER in prompt:
        time.sleep(2)

    if schema:
        message = json.dumps(example(schema), separators=(",", ":"))
    else:
        message = "CONFORMANCE-OK"

    emit(
        {
            "method": "item/completed",
            "params": {
                "threadId": thread_id,
                "turnId": turn_id,
                "item": {
                    "id": f"reasoning-{turn_id}",
                    "type": "reasoning",
                    "summary": ["Generated deterministic conformance output"],
                },
            },
        }
    )
    emit(
        {
            "method": "item/completed",
            "params": {
                "threadId": thread_id,
                "turnId": turn_id,
                "item": {
                    "id": f"message-{turn_id}",
                    "type": "agentMessage",
                    "text": message,
                },
            },
        }
    )
    emit(
        {
            "method": "thread/tokenUsage/updated",
            "params": {
                "threadId": thread_id,
                "turnId": turn_id,
                "tokenUsage": {
                    "total": {"inputTokens": 1, "outputTokens": 1, "totalTokens": 2},
                    "last": {"inputTokens": 1, "outputTokens": 1, "totalTokens": 2},
                },
            },
        }
    )
    emit(
        {
            "method": "turn/completed",
            "params": {
                "threadId": thread_id,
                "turn": {"id": turn_id, "status": "completed", "error": None},
            },
        }
    )


def main():
    thread_number = 0
    turn_number = 0

    for line in sys.stdin:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params", {})

        if method == "initialize" and request_id is not None:
            response(request_id, {"serverInfo": {"name": "conformance-stub", "version": "1"}})
        elif method == "initialized":
            continue
        elif method == "thread/start" and request_id is not None:
            thread_number += 1
            thread_id = f"conformance-thread-{thread_number}"
            response(
                request_id,
                {
                    "thread": {"id": thread_id},
                    "model": params.get("model") or "conformance-model",
                    "modelProvider": "stub",
                    "cwd": params.get("cwd", "."),
                    "approvalPolicy": params.get("approvalPolicy", "never"),
                    "sandbox": params.get("sandbox", "danger-full-access"),
                },
            )
        elif method == "turn/start" and request_id is not None:
            turn_number += 1
            turn_id = f"turn-{turn_number}"
            thread_id = params["threadId"]
            response(request_id, {"turn": {"id": turn_id, "status": "inProgress", "error": None}})
            threading.Thread(
                target=run_turn, args=(thread_id, turn_id, params), daemon=True
            ).start()
        elif method == "turn/interrupt" and request_id is not None:
            response(request_id, {})
        elif request_id is not None:
            emit(
                {
                    "id": request_id,
                    "error": {"code": -32601, "message": f"unsupported method: {method}"},
                }
            )


if __name__ == "__main__":
    main()
