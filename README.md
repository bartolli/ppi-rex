# ppi

Local message bus for Claude Code and Codex agents plus one operator, each in a [Rex](https://www.superlogical.com/rex/docs) pane. `ppi send` queues to disk, and a dispatcher in its own Rex tab pastes an agent's queue only when that agent is at its prompt.

## Requirements

- macOS Rex, Bash 3.2+, `jq`, and the system perl. Nothing runs outside Rex.
- Tested with Rex `0.0.1793981048-g01d6c4` (API 11), Claude Code 2.1.319, and Codex CLI 0.167.0.

## How it works

1. The SessionStart hook prints the bus contract. It tells the agent to reply only with `"$PPI_BIN" send` and never to treat another agent's message as operator approval.
2. `ppi send` appends to the recipient's queue. It never types into a pane.
3. The dispatcher, a supervised `rex do` Lua script, pastes an agent's queue as one **batch**. It pastes only while the agent is validated, at its prompt, and has nothing outstanding. Until then the agent is **held**.
4. Hooks record prompts and turn ends. The Stop matching the batch's prompt releases the batch. Anything else leaves it **uncertain** until the operator resolves it (see [Recovery](#recovery)).

Agent-to-agent sends stop at 20 per operator message. Sends to the operator always pass.

State lives in `/tmp/ppi-<uid>/rex-<session-id>`. The [internals doc](docs/documentation.md) covers the state model and every failure case.

## Install

1. Clone and link the CLI. `ppi` resolves its symlink, so agents and hooks run the clone, and `git pull` updates it.

   ```sh
   git clone https://github.com/bartolli/ppi-rex ~/src/ppi-rex
   mkdir -p ~/.local/bin && ln -sf ~/src/ppi-rex/bin/ppi ~/.local/bin/ppi
   ls -l "$(command -v ppi)"   # must point into ~/src/ppi-rex; otherwise fix PATH or an older ppi
   ```

2. Install the plugin in each harness you use. Its hooks are no-ops outside a ppi pane (no `PPI_BIN`).

   ```sh
   claude plugin marketplace add ~/src/ppi-rex && claude plugin install ppi@ppi
   codex plugin marketplace add ~/src/ppi-rex && codex plugin add ppi@ppi
   ```

3. Trust the Codex plugin hooks before the first `ppi up`. Run `codex` in the project, choose **Trust all**, then `/quit`. Trust is per profile, so add `-p <profile>` if the arm uses one.
4. Allow agents to run `"$PPI_BIN" send` and `"$PPI_BIN" who`, or approve each on prompt.

## Usage

1. Write the arms config. `ppi up` reads the path you pass, else `ppi.config.json` in the project, else `$XDG_CONFIG_HOME/ppi/config.json` (default `~/.config/ppi/config.json`). [Config](#config) lists the arm keys.

   ```json
   { "arms": [
     { "name": "claude", "runtime": "claude", "model": "haiku" },
     { "name": "codex",  "runtime": "codex",  "model": "gpt-6-luna" }
   ] }
   ```

2. From a Rex pane in the project, run `ppi up [config]`.
   - Agents open side by side above this pane.
   - This pane becomes the operator console.
   - The dispatcher runs in a `ppi bus` tab.
   - An arm receives nothing until its startup prompt's turn has ended.

### Console

| Command | Effect |
| :--- | :--- |
| `@<alias> <msg>` | Send. Resets the agent-to-agent count. |
| `/who` | Turn count, participants, queues, holds, batches, dispatcher, stale locks. |
| `/requeue <batch>` | Queue an uncertain batch's messages again, in a new batch. |
| `/dismiss <batch>` | Close an uncertain batch without a retry. |
| `/ready <alias>` | Confirm the agent is at a clean prompt and lift its hold. |
| `/quit` | Leave. Agents keep running; `ppi console` rejoins. |

Incoming messages print as `[ppi from=<alias> to=operator id=<id>] …`, and ppi's notices as `[ppi] …`. A message to the operator, an uncertain batch, or a stopped or unresponsive dispatcher sets the console pane's Rex status to Blocked until your next input line.

## Recovery

| Situation | Action |
| :--- | :--- |
| Uncertain batch (interrupted turn, blocked prompt, no Stop, agent exit, restart mid-delivery) | Inspect the agent, then `/requeue <batch>` or `/dismiss <batch>`. If ppi says the agent is still held, clear its input and `/ready <alias>`. |
| Prompt typed into an agent pane, then cancelled | The agent stays held until `/ready <alias>`. |
| Dispatcher stopped | `/who` prints `restart from a shell: <cmd>`. Run it in a new tab of the same Rex window, then close the old `ppi bus` pane, which is inert. A crashed script restarts by itself, at most 5 times a minute. |
| Stale lock | `/who` reports locks held 10 s or more, with removal steps. |

[Transitions](docs/documentation.md#transitions) in the internals doc lists every way a batch becomes uncertain.

## Config

Each arm uses the `claude` preset, the `codex` preset, or its own `command`.

| Key | Arm | Meaning |
| :--- | :--- | :--- |
| `name` | All | The alias the arm registers under. Unique, using `a-z`, `0-9`, `_`, and `-`. `operator` is reserved. |
| `runtime` | All | `claude` or `codex` for the presets. A `command` arm requires it too, set to `claude`, `codex`, or the app it reports to Rex. |
| `model` | `claude`, `codex` presets | Model to run. |
| `profile` | `codex` preset | Codex profile. `$CODEX_HOME/<profile>.config.toml` must exist (default `~/.codex`). |
| `command` | Command | argv array, with no shell expansion and no preset defaults. Put any model or profile flags in it. It has no startup prompt, so type the first prompt into its pane to validate it. |

- Unknown keys are rejected.
- The `codex` preset runs with `-s workspace-write`.
- Panes get the login-shell environment plus `ppi up`'s `PATH`. `CODEX_HOME` and `CLAUDE_CONFIG_DIR` pass through.

## CLI

```text
ppi up [config]                      build the workspace around this Rex pane
ppi console                          operator console
ppi who                              participants, holds, batches, dispatcher
ppi send <to> <message...>           queue a message (or stdin)
ppi ready <alias>                    the agent is at a clean prompt
ppi run --runtime <name> <alias> <command> [args...]
                                     register this pane as <alias>, then exec the agent
ppi dispatch                         dispatcher; the ppi bus tab's own program
ppi batch <operation> ...            queue operations for the dispatcher and console
ppi hook <session-start|prompt|stop|interrupt>
                                     plugin hook entry points
```

## Development

- `bin/ppi` is live. Panes and hooks run it on their next call.
- After changing a `hooks.json`, follow these steps.
  1. Bump `version` in both plugin manifests.
  2. Run `claude plugin update ppi@ppi` and `codex plugin add ppi@ppi`.
  3. Restart the agents.
  4. Re-trust the Codex hooks.
- The smoke test takes about 2 min in its own Rex session and needs BSD `script` and perl `MIME::Base64`. Set `REX_BIN_DIR` only outside a Rex pane.

  ```sh
  REX_BIN_DIR='/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS' /bin/bash test/smoke-rex.sh
  ```

- Design and internals are in [docs/documentation.md](docs/documentation.md).

## License

MIT
