#!/usr/bin/env python3
"""A scripted Agent Client Protocol agent for tests: newline-delimited JSON-RPC on stdio.

Behaviour is chosen by the prompt text: `write` asks permission then writes a file through the
client; `read` reads a file through the client; `hang` never answers (for cancellation); anything
else just streams a reply."""
import json, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()

def update(session, payload):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": payload}})

next_id = 1000
def call(method, params):
    global next_id
    next_id += 1
    send({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params})
    while True:
        line = sys.stdin.readline()
        if not line:
            sys.exit(0)
        msg = json.loads(line)
        if msg.get("id") == next_id and "method" not in msg:
            return msg

cancelled = False
while True:
    line = sys.stdin.readline()
    if not line:
        break
    msg = json.loads(line)
    method = msg.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1, "agentCapabilities": {"promptCapabilities": {}}, "authMethods": []}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "sess_fake"}})
    elif method == "session/cancel":
        cancelled = True
    elif method == "session/prompt":
        session = msg["params"]["sessionId"]
        text = "".join(b.get("text", "") for b in msg["params"]["prompt"])
        cancelled = False
        if "hang" in text:
            update(session, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "working..."}})
            while not cancelled:
                l = sys.stdin.readline()
                if not l: sys.exit(0)
                m = json.loads(l)
                if m.get("method") == "session/cancel":
                    cancelled = True
            send({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": "cancelled"}})
            continue
        update(session, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "thinking"}})
        update(session, {"sessionUpdate": "plan", "entries": [{"content": "step one", "priority": "high", "status": "in_progress"}]})
        if "write" in text:
            update(session, {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Write notes.txt", "kind": "edit", "status": "pending", "locations": [{"path": sys.argv[1] + "/notes.txt"}]})
            reply = call("session/request_permission", {"sessionId": session, "toolCall": {"toolCallId": "t1", "title": "Write notes.txt", "kind": "edit", "locations": [{"path": sys.argv[1] + "/notes.txt"}]},
                          "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"}, {"optionId": "no", "name": "Reject", "kind": "reject_once"}]})
            chosen = reply["result"]["outcome"].get("optionId")
            if chosen == "yes":
                w = call("fs/write_text_file", {"sessionId": session, "path": sys.argv[1] + "/notes.txt", "content": "hello from acp\n"})
                ok = "error" not in w
                update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed" if ok else "failed",
                                 "content": [{"type": "diff", "path": sys.argv[1] + "/notes.txt", "oldText": None, "newText": "hello from acp\n"}]})
                update(session, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "wrote it" if ok else "write failed: " + w["error"]["message"]}})
            else:
                update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "failed"})
                update(session, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "not allowed"}})
        elif "read" in text:
            r = call("fs/read_text_file", {"sessionId": session, "path": sys.argv[1] + "/secret.txt"})
            update(session, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "read: " + (r["result"]["content"] if "result" in r else "ERROR " + r["error"]["message"])}})
        else:
            update(session, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hello "}})
            update(session, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "from the fake agent"}})
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": "end_turn"}})
