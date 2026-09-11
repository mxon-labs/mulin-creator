# MuLiN Creator — Connecting an AI Client

*한국어: [README.ko.md](README.ko.md)*

This is the distribution that lets AI tools drive a running MuLiN Creator. Creator has an
MCP (Model Context Protocol) server built in, and this folder holds the client side that
connects to it.

- This repository **is** the plugin — the tools, a connection diagnostic skill, and an
  engineering skill. Claude Code and Codex both install it from here.
- `scripts/Start-McpBridge.ps1` — the bridge. **It doesn't care which client
  points at it** — any other MCP client points at this same script.

Windows only. Because Creator itself is Windows only.

**You get it from GitHub** — `https://github.com/mxon-labs/mulin-creator`. It does not ship
inside the Creator installer. It's released separately, so a new Creator installer doesn't
refresh it — this side updates on its own schedule.

## First — Creator has to be running

The thing you're connecting to is a running Creator window. If it isn't up, nothing connects.

Launching Creator automatically starts the MCP server. It picks the first free port starting
from 29500, and the connection details are recorded in

```
%LOCALAPPDATA%\MXOn Corporation\MuLiN Creator\mcp\<port>.lock
```

**You never need to look at this file yourself** — the bridge reads it and finds everything
on its own. There's no need to type in the port by hand or copy a token.

**Creator's install path is never written down anywhere.** The bridge doesn't launch
Creator — it only finds and connects to a window a person already started. So the only
path that ever goes into configuration is the bridge script itself.

The lock directory is **one per PC** (under the user's AppData). So even with several
Creator instances running, the lock files all collect in the same place — what determines
which one you connect to is **whichever window happens to be running**. If more than one
is up, see "When more than one Creator window is running" below.

## Claude Code

Register the marketplace and install the plugin. Two lines.

```
/plugin marketplace add mxon-labs/mulin-creator
/plugin install mulin-creator@mxon
```

`mxon-labs/mulin-creator` is this distribution's GitHub repository. It's public, so no
account is needed. Claude Code fetches the repository itself — **you don't need to download
anything up front.**

What installing gives you:

- **Tools** — project, POU, ladder, variables, tasks, build, download. Their names read
  as `mcp__plugin_mulin-creator_mulin-creator__*`.
- **`/mulin-creator:check-mcp`** — pinpoints why a connection isn't working.
- **`/mulin-creator:engineering`** — the operating sequence. The AI automatically consults
  it for things like the fact that a ladder is a graph, or what to do when a dialog pops up.

Check whether it's connected with `/mcp`. If `mulin-creator` shows `✔ Connected`, you're
done — in the install id `mulin-creator@mxon`, the trailing `mxon` is the **marketplace**
(publisher) name, while the `mulin-creator` shown in `/mcp` is the name of the **server**
this plugin starts.

**Tool names differ depending on how you connect.** Installed as a Claude Code plugin they
read as `mcp__plugin_mulin-creator_mulin-creator__*`; other clients spell them their own
way, always carrying the server name `mulin-creator`.

### When a new version comes out

[CHANGELOG.md](CHANGELOG.md) records what changed in each version and which Creator it
needs. Read the entry before you upgrade — the two ship separately, so it is your call
whether Creator has to move too.

Installing **copies** the plugin into `~/.claude/plugins/cache/`. So even after a new version
lands in the repository, the copy doesn't follow along automatically. Two lines — refetch the
marketplace, then update the plugin.

```
/plugin marketplace update mxon
/plugin update mulin-creator@mxon
```

**Skip the first line and you won't even learn a new version exists** — Claude Code reads
the copy it fetched when you registered.

**The update only takes effect if the version number has actually changed.** If you run
the update and it reports *"already at the latest version"*, nothing was copied over even
though the files changed. In that case, uninstall and reinstall.

```
claude plugin uninstall mulin-creator@mxon
claude plugin install mulin-creator@mxon
```

**If you registered it through project configuration, you must specify the scope** — the
update's default scope is `user`, so an install registered via project configuration needs
to be targeted explicitly.

```
claude plugin update mulin-creator@mxon --scope project
```

### Order matters — start Creator first

Claude Code starts the bridge **when the session starts.** If Creator isn't up at that
moment, the server is left in a failed state, and the session remembers that failure —
starting Creator afterward doesn't make the next tool call reconnect on its own. How you
reconnect depends on the client.

- **`claude` in a terminal** — pick `mulin-creator` in `/mcp` and Reconnect.
- **A client without an `/mcp` panel** (the Code tab in the desktop app, for instance) —
  start Creator, then **start a new session.** There's no reconnect handle on that side.

So the safest order is **to start Creator first, then launch Claude Code.**

**Restarting Creator mid-session is a different story — you don't have to do anything.**
The bridge stays alive, and on the next tool call it re-reads the lock file and connects
to the newly opened window by itself. This holds even if the port changed. Even if the
display still shows "disconnected," a single tool call is enough.

## Codex

Codex installs from this same repository. Two lines, as on Claude Code.

```
codex plugin marketplace add mxon-labs/mulin-creator
codex plugin add mulin-creator@mxon
```

You get the tools and both skills. `codex mcp list` should show `mulin-creator` as enabled.

**Start Creator first, then the session** — the bridge is launched when the session starts,
the same as on Claude Code.

### When a new version comes out

Installing **copies** the plugin into `~/.codex/plugins/cache/`, so the copy doesn't follow
the repository on its own. Refresh the marketplace, then install again.

```
codex plugin marketplace upgrade mxon
codex plugin add mulin-creator@mxon
```

Then **start a new session** — that is where the updated tools and skills are picked up.

Codex's HTTP approach (`url` + `bearer_token_env_var`) isn't used — the URL is static, so it
breaks the moment the port changes. The bridge exists to eliminate exactly that problem.

## Other MCP clients

Clone the repository and launch the bridge over stdio. Call wherever you cloned it
`<repo path>`.

```
git clone https://github.com/mxon-labs/mulin-creator.git
```

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<repo path>\scripts\Start-McpBridge.ps1"
```

**Don't use a client's plugin cache as the clone** — those paths get rewritten on reinstall.
Pick up new versions with `git pull`.

## When more than one Creator window is running

The bridge **never guesses which window you mean.** If the open project doesn't
disambiguate either, it refuses to connect and lists the candidates instead — because
having the ladder change in a window you're not even looking at is the most expensive
kind of accident in this family of tools.

To pin down exactly which window to operate on, put that window's port into an
environment variable.

```powershell
$env:MULIN_MCP_PORT = 29501
```

You can find the port from the `mulin-creator:check-mcp` skill or from the lock file's name.

**On Codex the open project never disambiguates** — the bridge runs from the plugin folder
there, so it has no project folder to compare against. Pick the port whenever more than one
window is up.

## If the attached window disappears mid-session

The bridge pins itself to the first Creator window it connects to, and keeps talking to
that exact process for the rest of the session — it does **not** silently switch to a
different window if that one closes. If a different Creator answers when it reconnects,
the tool call fails with `creator.instance_changed` instead of being applied somewhere you
didn't choose.

The fix doesn't need a restart: the AI calls `use_creator_instance` with the port of the
window it should be talking to (listed in the error, or from `list_creator_instances`),
then retries. This is also how a window stuck behind a dialog — for example after a
crash-recovery prompt, which shows up with no project open — gets found and unstuck.

## When it doesn't work

In Claude Code, `/mulin-creator:check-mcp` diagnoses this for you. To check directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<repo path>\scripts\Start-McpBridge.ps1" -Doctor
```

It reports the lock directory, the list of lock files, whether each window responds, and
which window it would pick and why.
