#!/usr/bin/env python3
"""Hermetic, concurrent JSONL app-server used by Elixir provider tests."""

import json
import os
import sys
import threading
import time


sys.stderr = open(os.devnull, "w", encoding="utf-8")


MODE = sys.argv[1] if len(sys.argv) > 1 else "echo"
EXTRAS = sys.argv[2:-1] if sys.argv[-1:] == ["app-server"] else sys.argv[2:]
WRITE_LOCK = threading.Lock()
COUNTER_LOCK = threading.Lock()
THREAD_NUMBER = 0
TURN_NUMBER = 0


def emit(value):
    with WRITE_LOCK:
        print(json.dumps(value, separators=(",", ":")), flush=True)


def emit_raw(value):
    with WRITE_LOCK:
        print(value, flush=True)


def response(request_id, result):
    emit({"id": request_id, "result": result})


def append_line(path, value):
    with open(path, "a", encoding="utf-8") as output_file:
        output_file.write(f"{value}\n")


def next_id(kind):
    global THREAD_NUMBER, TURN_NUMBER
    with COUNTER_LOCK:
        if kind == "thread":
            THREAD_NUMBER += 1
            return f"t{THREAD_NUMBER}"
        TURN_NUMBER += 1
        return f"turn-{TURN_NUMBER}"


def prompt_text(params):
    return next(
        (
            item.get("text", "")
            for item in params.get("input", [])
            if item.get("type") == "text"
        ),
        "",
    )


def terminal(thread_id, turn_id, status="completed", error=None):
    emit(
        {
            "method": "turn/completed",
            "params": {
                "threadId": thread_id,
                "turn": {"id": turn_id, "status": status, "error": error},
            },
        }
    )


def usage(thread_id, turn_id, input_tokens=1, output_tokens=1):
    total = input_tokens + output_tokens
    emit(
        {
            "method": "thread/tokenUsage/updated",
            "params": {
                "threadId": thread_id,
                "turnId": turn_id,
                "tokenUsage": {
                    "total": {
                        "inputTokens": input_tokens,
                        "outputTokens": output_tokens,
                        "totalTokens": total,
                    },
                    "last": {
                        "inputTokens": input_tokens,
                        "outputTokens": output_tokens,
                        "totalTokens": total,
                    },
                },
            },
        }
    )


def item(thread_id, turn_id, value):
    emit(
        {
            "method": "item/completed",
            "params": {"threadId": thread_id, "turnId": turn_id, "item": value},
        }
    )


def assistant(thread_id, turn_id, text, phase="final_answer"):
    item(
        thread_id,
        turn_id,
        {
            "id": f"message-{turn_id}-{phase}",
            "type": "agentMessage",
            "text": text,
            "phase": phase,
        },
    )


def output_for(prompt, params):
    valid = {"bugs": [{"file": "lib/a.ex", "line": 3}]}
    invalid = {"bugs": "nope"}
    schema = params.get("outputSchema")

    if MODE in ("echo", "activity", "server_count", "concurrent", "capture"):
        return prompt
    if MODE == "live_proof":
        return "LIVE-MCP-PROOF-OK"
    if MODE == "schema_file":
        return json.dumps(schema, separators=(",", ":"))
    if MODE == "schema_prompt_contract":
        return json.dumps(
            {"prompt": prompt, "hasSchemaFile": schema is not None},
            separators=(",", ":"),
        )
    if MODE == "large_schema_output":
        return json.dumps({"body": "x" * 500 + "tail"}, separators=(",", ":"))
    if MODE == "always_invalid":
        return json.dumps(invalid, separators=(",", ":"))
    if MODE == "retry":
        counter = EXTRAS[0]
        first = not os.path.exists(counter)
        with open(counter, "w", encoding="utf-8") as counter_file:
            counter_file.write("seen")
        return json.dumps(invalid if first else valid, separators=(",", ":"))
    return "partial assistant output" if MODE.startswith("turn_failed") else prompt


def run_turn(thread_id, turn_id, params):
    prompt = prompt_text(params)

    if MODE in ("timeout", "timeout_unsubscribe", "ignore_interrupt"):
        return
    if MODE == "crash_after_accept":
        time.sleep(0.02)
        os._exit(17)
    if MODE == "malformed":
        emit_raw("{not-json")
        return
    if MODE == "oversize":
        emit_raw("{" + "x" * 2_000_000)
        return
    if MODE == "approval":
        emit(
            {
                "id": 900_000 + int(turn_id.split("-")[-1]),
                "method": "item/commandExecution/requestApproval",
                "params": {
                    "threadId": thread_id,
                    "turnId": turn_id,
                    "itemId": "command-1",
                    "command": "rm -rf /",
                },
            }
        )
        return
    if MODE == "concurrent":
        time.sleep(0.05)
    if MODE in ("unsubscribe_error_concurrent", "unsubscribe_hang_concurrent"):
        if prompt == "slow":
            time.sleep(0.2)

    if MODE in ("error_nonretry", "error_retry"):
        emit(
            {
                "method": "error",
                "params": {
                    "threadId": thread_id,
                    "turnId": turn_id,
                    "willRetry": MODE == "error_retry",
                    "error": {"message": "transient backend error"},
                },
            }
        )

    if MODE == "realtime":
        item(
            thread_id,
            turn_id,
            {
                "id": "reason-1",
                "type": "reasoning",
                "summary": ["read the acceptance criteria"],
            },
        )
        item(
            thread_id,
            turn_id,
            {
                "id": "tool-1",
                "type": "toolCall",
                "name": "shell",
                "input": {"cmd": "mix test test/workflow/web/run_live_test.exs"},
            },
        )
        assistant(thread_id, turn_id, "codex final draft")
        release = os.environ["CODEX_LOOPS_STUB_RELEASE"]
        while not os.path.exists(release):
            time.sleep(0.05)
        usage(thread_id, turn_id, 7, 11)
        terminal(thread_id, turn_id)
        return

    if MODE == "activity":
        item(
            thread_id,
            turn_id,
            {
                "id": "r1",
                "type": "reasoning",
                "summary": ["Read the failing test"],
            },
        )
        item(
            thread_id,
            turn_id,
            {
                "id": "c1",
                "type": "toolCall",
                "name": "shell",
                "input": {"cmd": "mix test test/workflow/codex_provider_test.exs"},
            },
        )

    if MODE == "event_flood":
        for number in range(20):
            item(
                thread_id,
                turn_id,
                {
                    "id": f"flood-{number}",
                    "type": "reasoning",
                    "summary": [f"event {number}"],
                },
            )

    if MODE == "commentary_then_final":
        assistant(thread_id, turn_id, "interim", "commentary")
        assistant(thread_id, turn_id, "final", "final_answer")
    else:
        assistant(thread_id, turn_id, output_for(prompt, params))

    if MODE.startswith("turn_failed") or (
        MODE == "unsubscribe_capture" and prompt == "fail"
    ):
        terminal(
            thread_id,
            turn_id,
            "failed",
            {"message": "codex backend exploded"},
        )
    elif MODE.startswith("stream_error"):
        terminal(
            thread_id,
            turn_id,
            "failed",
            {"message": "codex stream failed"},
        )
    else:
        if MODE == "echo":
            usage(thread_id, turn_id, 3, 5)
        elif MODE == "live_proof":
            usage(thread_id, turn_id, 7, 11)
        else:
            usage(thread_id, turn_id)
        terminal(thread_id, turn_id)

    if MODE in ("turn_failed_exit", "stream_error_exit", "completed_exit"):
        time.sleep(0.01)
        os._exit(1)


def main():
    if MODE in (
        "server_count",
        "thread_hang",
        "unsubscribe_error_concurrent",
        "unsubscribe_hang_concurrent",
    ) and EXTRAS:
        append_line(EXTRAS[0], "started")

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params", {})

        if MODE == "capture" and EXTRAS:
            with open(EXTRAS[0], "a", encoding="utf-8") as capture_file:
                capture_file.write(json.dumps({"method": method, "params": params}) + "\n")

        if method == "initialize" and request_id is not None:
            if MODE != "initialize_hang":
                response(request_id, {"serverInfo": {"name": "test-stub", "version": "1"}})
        elif method == "initialized":
            continue
        elif method == "thread/start" and request_id is not None:
            if MODE == "crash_before_turn":
                os._exit(127)
            if MODE == "thread_hang":
                continue
            thread_id = next_id("thread")
            response(request_id, {"thread": {"id": thread_id}})
        elif method == "turn/start" and request_id is not None:
            if MODE == "turn_start_hang":
                continue
            turn_id = next_id("turn")

            if MODE == "approval_before_turn_response":
                emit(
                    {
                        "id": 990_001,
                        "method": "item/commandExecution/requestApproval",
                        "params": {
                            "threadId": params["threadId"],
                            "itemId": "command-before-turn-response",
                            "command": "echo must-be-cancelled",
                        },
                    }
                )
                time.sleep(0.05)

            response(
                request_id,
                {"turn": {"id": turn_id, "status": "inProgress", "error": None}},
            )

            if MODE != "approval_before_turn_response":
                threading.Thread(
                    target=run_turn,
                    args=(params["threadId"], turn_id, params),
                    daemon=True,
                ).start()
        elif method == "turn/interrupt" and request_id is not None:
            if MODE != "ignore_interrupt":
                if MODE == "approval_before_turn_response" and EXTRAS:
                    append_line(EXTRAS[0], "interrupt")
                response(request_id, {})
                terminal(params["threadId"], params["turnId"], "interrupted")
        elif method == "thread/unsubscribe" and request_id is not None:
            if MODE in ("unsubscribe_capture", "timeout_unsubscribe") and EXTRAS:
                append_line(EXTRAS[0], params["threadId"])
            if MODE == "approval_before_turn_response" and EXTRAS:
                append_line(EXTRAS[0], "unsubscribe")

            if MODE == "unsubscribe_error_concurrent":
                emit(
                    {
                        "id": request_id,
                        "error": {
                            "code": -32603,
                            "message": "unsubscribe failed",
                        },
                    }
                )
            elif MODE == "unsubscribe_hang_concurrent":
                continue
            else:
                response(request_id, {"status": "unsubscribed"})
        elif request_id is not None and method is not None:
            emit(
                {
                    "id": request_id,
                    "error": {"code": -32601, "message": f"unsupported: {method}"},
                }
            )


if __name__ == "__main__":
    main()
