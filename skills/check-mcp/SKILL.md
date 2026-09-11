---
name: check-mcp
description: MuLiN Creator 에 왜 붙지 못하는지 진단한다 — 잠금 파일·포트·응답·인스턴스 선택 (실행 중인 PLC 가 아니라 Creator 쪽 연결 진단) / Diagnoses why the session cannot attach to MuLiN Creator — lock file, port, response, instance selection (this checks the Creator-side connection, not a running PLC)
allowed-tools: Bash(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Start-McpBridge.ps1" *)
---

# Why the session cannot attach to Creator

Run the bridge's diagnostic mode and **interpret the result** — do not paste the raw
output. Say first **what is blocked and what to do about it**, in the language the
user is writing in. If it reports everything is fine, end in one line.

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<plugin folder>/scripts/Start-McpBridge.ps1" -Doctor
```

In Claude Code, write `${CLAUDE_PLUGIN_ROOT}` for `<plugin folder>`. In other clients,
use the folder this skill was loaded from.

## The two states a person has to resolve

Everything else settles itself: the bridge waits for Creator to appear and reattaches
on its own, so **"Creator isn't running yet" is not a problem to solve** — say so and
stop.

- **Several windows are running and none can be chosen.** The bridge never guesses,
  because changing the ladder in a window nobody is watching is the most expensive
  accident in this family of tools. Tell the user to put one of the ports the
  diagnostic listed into `MULIN_MCP_PORT` and start a new session. **Do not pick for
  them.**
- **A lock file that does not answer.** Left behind by an abnormal exit. Relaunching
  Creator clears it on startup.

## What this does not cover

`creator.instance_changed` on every tool call. That means the bridge did attach earlier
and then lost that window — call `use_creator_instance` with a port from the error (or
from `list_creator_instances`). No restart, and this diagnostic has nothing to add.
