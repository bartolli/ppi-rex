# ppi

ping pong interactive: a local message bus between coding agents and a human operator in Zellij panes. One shell script. Requires Zellij 0.44 or later, jq, and Bash 3.2 or later. Claude Code and Codex have launch presets; any agent with Claude-style lifecycle hooks can be an arm.

## Layout

```
proto/
├── .claude-plugin/marketplace.json    Claude catalog "ppi" → ./plugins/claude/ppi
├── .agents/plugins/marketplace.json   Codex catalog "ppi"  → ./plugins/codex/ppi
├── ppi.config.json                    sample arms config
├── bin/ppi                            the whole tool: bus, hooks, layout, and the bus contract
├── plugins/claude/ppi/                Claude plugin: hooks.json only
├── plugins/codex/ppi/                 Codex plugin: hooks.json only
└── test/smoke.sh
```

Each plugin is a `hooks.json` whose hooks run the `ppi` that started their pane:

```sh
[ -z "${PPI_BIN:-}" ] || "$PPI_BIN" hook <event>
```

`ppi run` exports `PPI_BIN`, `PPI_ALIAS`, `PPI_HOME`, and `PPI_RUNTIME` to the agent. Outside a ppi pane `PPI_BIN` is unset and the hooks do nothing, so the plugins can stay enabled everywhere. The plugins carry no copy of the script and no skill: the bus contract is printed by `ppi hook session-start` as session context, compaction included.

## Install once

Put `bin/ppi` on PATH, for example:

```sh
ln -s /path/to/ppi/proto/bin/ppi ~/.local/bin/ppi
```

Claude Code:

```sh
claude plugin marketplace add /path/to/ppi/proto
claude plugin install ppi@ppi
```

Pre-approve its commands in `~/.claude/settings.json`, or every send prompts:

```json
{ "permissions": { "allow": ["Bash(ppi send:*)", "Bash(ppi who)"] } }
```

Codex:

```sh
codex plugin marketplace add /path/to/ppi/proto
codex plugin add ppi@ppi
```

Review and trust the three ppi hooks through `/hooks`, then restart Codex. Plugin hooks need their own trust review, and changed hooks are marked for review again.

Upgrading from the a2a prototype: uninstall `a2a@ppi` from both harnesses, remove the old `a2a` link, and rename `a2a.config.json` to `ppi.config.json`.

## Run

```sh
cd ~/some-project
ppi up                 # ./ppi.config.json, else ${XDG_CONFIG_HOME:-~/.config}/ppi/config.json
ppi up other.json      # or an explicit arms config
ppi layout             # print the generated Zellij layout without launching
```

The panes start in the directory `ppi up` runs from, so that directory is the arms' workspace. Each arm has a `name` (its bus alias) and either a runtime preset or a command:

```json
{
  "arms": [
    { "name": "claude", "runtime": "claude", "model": "haiku" },
    { "name": "codex", "runtime": "codex", "model": "gpt-6-luna", "profile": "supervisor" },
    { "name": "planner", "runtime": "claude", "command": ["claude", "--model", "opus", "--permission-mode", "plan"] }
  ]
}
```

- Preset `claude`: optional `model`.
- Preset `codex`: optional `model` and `profile`; the pane always runs with `-s workspace-write` and a one-line startup prompt, because Codex initializes session hooks on its first prompt.
- `command`: the pane's argv as written. No shell is involved, so `~` and `$VAR` are not expanded, and presets' defaults are not added. `runtime` is then an optional label that the arm's hooks receive as `PPI_RUNTIME`; `model` and `profile` are not allowed next to a command.

The config is checked before launch: names unique, `a-z 0-9 _ -`, not `operator`; unknown fields rejected; `profile` only on codex arms, with `~/.codex/<profile>.config.toml` present; `command` a non-empty array of strings. Models are not checked. A wrong model fails inside its pane after Zellij starts, and `/who` shows the arm stuck at `starting`.

The arms sit side by side, and the operator console spans the full width below them. The bus log is a floating pane, hidden at start: `Alt f` shows and hides it. Hide it rather than close it, because it also delivers the messages sandboxed agents leave pending.

Both agents gate themselves through their hooks:

- SessionStart marks the agent idle and prints the bus contract.
- UserPromptSubmit marks it busy.
- Stop hands any queued messages back as the next prompt, or marks it idle.
- Claude only: the `idle_prompt` Notification marks it idle and delivers its queue,
  which recovers an agent left busy by an interrupted turn.

With no `PPI_ALIAS` (any session not started by `ppi run`), the hooks do nothing.

Trusted Codex hooks run outside Codex's workspace sandbox. They only update bus files and print context or a Stop decision. The Codex pane runs workspace-write without Zellij socket access or sandbox/trust bypass flags; its own `ppi send` calls leave messages pending for the bus monitor to deliver.

The bus accepts 20 agent-to-agent messages between operator sends. Further agent sends exit 1, queue nothing, and log `blocked`; messages to the operator still go through. Any operator send resets the count. `/who` shows it.

## Change ppi

Edit `bin/ppi`. Running panes and hooks pick it up on their next call, since nothing is copied. A change to a `hooks.json` needs a `version` bump in both plugin manifests, then `claude plugin update ppi@ppi` and, for Codex, `codex plugin add ppi@ppi` again. Do the Codex update before starting a Codex arm: a Codex arm that finds a new version reinstalls the plugin itself and deletes the old cache folder, and any Codex arm still running loses its hooks. Restart the agent panes, and review any Codex hooks marked as changed.

## Verify

```sh
/bin/bash /path/to/ppi/proto/test/smoke.sh
```

Live check, without `/release`:

- `/who` shows both agents idle once they are at their prompts.
- A message sent while an agent is working shows queued, then delivered when its turn ends.
- After a turn ends with nothing queued, `/who` shows the agent idle.
