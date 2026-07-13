#!/usr/bin/env python3
"""Deterministic Codex JSONL stub for packaged workflow conformance proofs."""

import json
import sys
import time


HOLD_LEASE_MARKER = "CODEX_LOOPS_CONFORMANCE_HOLD_LEASE"


def schema_path(arguments):
    try:
        return arguments[arguments.index("--output-schema") + 1]
    except (ValueError, IndexError):
        return None


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

    if schema_type == "integer":
        return max(schema.get("minimum", 1), 1)

    if schema_type == "number":
        return max(schema.get("minimum", 1), 1)

    if schema_type == "null":
        return None

    return "conformance-ok"


def emit(event):
    print(json.dumps(event, separators=(",", ":")), flush=True)


def main():
    prompt = sys.stdin.read()
    path = schema_path(sys.argv[1:])

    if HOLD_LEASE_MARKER in prompt:
        time.sleep(2)

    if path:
        with open(path, encoding="utf-8") as schema_file:
            message = json.dumps(example(json.load(schema_file)), separators=(",", ":"))
    else:
        message = "CONFORMANCE-OK"

    emit({"type": "thread.started", "thread_id": "conformance-stub"})
    emit({"type": "turn.started"})
    emit(
        {
            "type": "item.completed",
            "item": {
                "id": "reasoning-1",
                "type": "reasoning",
                "text": "Generated deterministic conformance output",
            },
        }
    )
    emit(
        {
            "type": "item.completed",
            "item": {"id": "message-1", "type": "agent_message", "text": message},
        }
    )
    emit(
        {
            "type": "turn.completed",
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }
    )


if __name__ == "__main__":
    main()
