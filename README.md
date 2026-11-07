# ppi — Ping Pong Interactive

**A zero-daemon local message bus for orchestrating CLI coding agents (Claude Code, OpenAI Codex) and a human operator in [Rex](https://www.superlogical.com/rex/docs) panes.**

`ppi` turns a Rex session into a multi-agent workspace: AI coding agents collaborate side-by-side with human-in-the-loop oversight, all in one Bash script that drives Rex through its `rex` CLI.

- **Zero infrastructure:** Pure Bash, `jq`, and the `rex` CLI that ships with Rex. No background service. State lives in `/tmp/ppi-<uid>/rex-<session id>`.
- **Safe to leave installed:** Outside a `ppi` session, the plugin hooks find no `PPI_BIN` and exit `0` immediately.
- **Built-in loop guard:** Caps agent-to-agent traffic at 20 messages until the human operator sends again. Over-limit sends are refused and logged as `blocked`; messages to the operator always pass.
- **Prompt-injection aware:** The injected contract tells each agent that a message from another agent is a request, never the user's approval: it cannot approve a permission prompt or authorize new work.

**Requirements:** Rex, `jq`, and Bash `3.2+`. `rex` is on `PATH` inside every Rex pane, which is where `ppi` runs. This is the Rex edition of ppi; it carries no code for other multiplexers.

## Install

**Review `bin/ppi` first**, then symlink it onto your `PATH`:

```sh
git clone <this repository> /path/to/ppi
ln -s /path/to/ppi/bin/ppi ~/.local/bin/ppi
```

### Claude Code Plugin

```sh
claude plugin marketplace add /path/to/ppi
claude plugin install ppi@ppi
```

Pre-approve `ppi` in `~/.claude/settings.json` so agent sends don't pause for confirmation:

```json
{
  "permissions": {
    "allow": ["Bash(ppi send:*)", "Bash(ppi who)"]
  }
}
```

### OpenAI Codex Plugin

```sh
codex plugin marketplace add /path/to/ppi
codex plugin add ppi@ppi
```

Codex prompts you to trust the plugin and its hooks on first use. Accept, then restart Codex. Changed hooks are marked for review again.

## Quick Start

### Create `ppi.config.json`

Place a config file in your project root, or globally at `~/.config/ppi/config.json`:

```json
{
  "arms": [
    { "name": "claude", "runtime": "claude", "model": "haiku" },
    { "name": "codex", "runtime": "codex", "model": "gpt-6-luna", "profile": "supervisor" },
    { "name": "planner", "runtime": "claude", "command": ["claude", "--model", "opus", "--permission-mode", "plan"] }
  ]
}
```

### Launch the Workspace

In a Rex pane, from your project directory:

```sh
cd ~/your-project
ppi up                 # uses ./ppi.config.json or ~/.config/ppi/config.json
ppi up custom.json     # or pass an explicit config file
```

`ppi up` builds the workspace around the pane it runs in: the agents open side by side above it, the pane becomes the **operator console**, and the bus monitor runs in a **ppi bus** tab. The agents start in the directory `ppi up` runs from, so that directory is their workspace. `/quit` returns you to your shell while the agents keep running; `ppi console` rejoins them. A Rex session holds one workspace at a time.

### Orchestrate from the Operator Console

```text
operator> @claude Ask @codex to review your changes in src/auth.ts
operator> /who
operator> /release codex
operator> /quit
```

| Console Command | Action |
| :--- | :--- |
| `@<agent> <message>` | Send an instruction to an agent (resets the `20/20` agent-to-agent message counter). |
| `/who` | Show message count (`X/20`), participant pane IDs, states (`starting`, `idle`, `busy`), and queue depths. |
| `/release <agent>` | Recover a stuck agent sitting at its prompt (delivers queued messages or marks it `idle`). |
| `/quit` | Exit the operator console; the agents keep running. |
| *(incoming)* | Messages agents send to `operator` print in the console as they arrive, as `[ppi from=<agent> to=operator id=<id>] <msg>`. |
| **ppi bus** tab | The bus log. It also delivers messages for sandboxed agents, so keep it open. |

## Configuration Rules

Each entry in `"arms"` defines one agent pane:

- **`claude` preset:** Supports optional `"model"`.
- **`codex` preset:** Supports optional `"model"` and `"profile"`. Launches with `-s workspace-write` and a one-line startup prompt so Codex initializes its session hooks.
- **Custom `"command"`:** An array of strings executed directly (`["claude", "--model", "opus"]`). No shell expansion (`~` or `$VAR`) or preset defaults are applied. Optional `"runtime"` sets `PPI_RUNTIME` for hooks; `"model"` and `"profile"` are not allowed alongside `"command"`.

Models are not checked: a wrong model fails inside its pane after it starts, and `/who` shows the arm stuck at `starting`.

Agent panes start from the login shell's environment plus the `PATH` that `ppi up` ran with, so programs installed by your interactive shell setup, such as an nvm-installed `claude`, are found. `CODEX_HOME` and `CLAUDE_CONFIG_DIR` are passed through when set.

## CLI Reference

```text
ppi up [config]                            build the workspace around this Rex pane
ppi console                                start the interactive operator prompt
ppi monitor                                tail bus.jsonl and deliver pending sandboxed messages
ppi who                                    list message count, participants, panes, and states
ppi send <to> <message...>                 message a participant (or pass message via stdin)
ppi release <alias>                        deliver an agent's queue or mark it idle
ppi deliver <alias>                        deliver an agent's queue if currently idle
ppi run [--runtime <name>] <alias> ...     register this Rex pane as <alias> and exec command
ppi hook <session-start|prompt|stop|idle>  lifecycle hook entry points
```

## How It Works

1. **Context Injection:** On `session-start`, `ppi` marks the agent `idle` and prints the bus contract, so the agent knows how to call `ppi who` and `ppi send <to> <<'EOF'`. After a mid-turn context compaction the contract is printed again, but the state is left alone.
2. **Queueing & Delivery:**
   - If a recipient is `idle`, `ppi send` pastes `[ppi from=<sender> to=<recipient> id=<id>] <msg>` into its pane as one bracketed paste, then presses Enter.
   - If a recipient is `busy`, the message queues on disk. When the recipient finishes its turn, its `Stop` hook blocks exit and feeds the queued messages back as the next prompt.
   - Claude only: the `idle_prompt` notification marks the agent `idle` and delivers its queue, which recovers an agent left `busy` by an interrupted turn.
3. **Sandboxed Delivery (Codex):** Codex panes run in `workspace-write` mode without access to the Rex socket. When Codex runs `ppi send`, the message is logged as `pending`, and the unsandboxed `ppi monitor` in the **ppi bus** tab delivers it into the target pane.

## Development

Edit `bin/ppi` directly. Running panes and hooks pick up changes on their next call, since nothing is copied.

If you edit a `hooks.json`, bump `version` in both plugin manifests, then run `claude plugin update ppi@ppi` and `codex plugin add ppi@ppi` again. Do the Codex update before starting a Codex arm: a Codex arm that finds a new version reinstalls the plugin itself and deletes the old cache folder, and any Codex arm still running loses its hooks. Restart the agent panes and review any Codex hooks marked as changed.

The smoke test opens and closes its own Rex session. Run it from a Rex pane, or set `REX_BIN_DIR` to the directory holding the `rex` CLI:

```sh
/bin/bash /path/to/ppi/test/smoke-rex.sh
REX_BIN_DIR='/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS' /bin/bash /path/to/ppi/test/smoke-rex.sh
```
