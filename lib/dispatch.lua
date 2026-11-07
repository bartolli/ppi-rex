-- The ppi dispatcher: delivers each agent's queue as one paste while the agent is at its prompt.
-- `ppi dispatch` owns the bus's dispatcher lock and runs this under rex do --fail-fast, restarting
-- it when it fails. Every decision is a ppi subcommand; this script holds no state that matters.
local PPI, BASH, HOME = rex.args.ppi, rex.args.bash, rex.args.home
assert(PPI and BASH and HOME, "ppi, bash, and home are required")
local SESSION = rex.session_id
local ENV = { PPI_HOME = HOME, REX_SESSION = SESSION }

local function say(msg) print(os.date("%H:%M:%S") .. " ppi: " .. msg) end

-- Ends the script. Used when a command that may have changed bus state failed without a result to
-- go on: the supervisor's restart reconciliation then holds anything it may have reserved.
local function fatal(msg) error(msg, 0) end

-- One ppi subcommand: its JSON result, or nil and why it failed.
local function ppi(...)
  local argv = { BASH, PPI, ... }
  local r, err = rex.exec(argv, { env = ENV, timeout = 20 })
  if not r then return nil, "ppi " .. argv[3] .. " " .. argv[4] .. " did not run: " .. tostring(err) end
  if not r.ok then
    local why = r.stderr:gsub("%s+$", "")
    if why == "" then why = r.timed_out and "timed out" or ("exit " .. tostring(r.code)) end
    return nil, "ppi " .. argv[3] .. " " .. argv[4] .. ": " .. why
  end
  local ok, v = pcall(rex.json.decode, r.stdout)
  if not ok or type(v) ~= "table" then return nil, "ppi " .. argv[3] .. " " .. argv[4] .. " printed: " .. r.stdout end
  return v
end

local function aliases()
  local r, err = rex.exec({ "ls", HOME .. "/panes" }, { timeout = 5 })
  if not r or not r.ok then fatal("cannot list participants: " .. tostring(err or r.stderr)) end
  local list = {}
  for a in r.stdout:gmatch("[^\n]+") do list[#list + 1] = a end
  return list
end

local function block_of(a)
  local f = io.open(HOME .. "/panes/" .. a, "r")
  if not f then return nil end
  local id = f:read("*l")
  f:close()
  return id
end

local function put(path, text)
  local tmp = path:gsub("([^/]+)$", ".%1.tmp")
  local f = assert(io.open(tmp, "w"))
  f:write(text, "\n")
  f:close()
  assert(os.rename(tmp, path))
end

-- Pinned to Rex 0.0.1793981048-g01d6c4: a block that no longer exists fails with code=not_found,
-- which the CLI reports as exit 3. Any other failure is unknown, never proof the agent is gone.
local function read_failed(err)
  if tostring(err):find("code=not_found", 1, true) then return { "--gone" } end
  return { "--unknown" }
end

local function snapshot(block)
  local p, perr = rex.call("com.superlogical.terminal.process", { session_id = SESSION, block_id = block, args = {} })
  if p == nil then return read_failed(perr) end
  local s, serr = rex.call("com.superlogical.terminal.program_status", { session_id = SESSION, block_id = block, args = {} })
  if s == nil then return read_failed(serr) end
  return { "--status", rex.json.encode(s), "--process", rex.json.encode(p) }
end

local function tick(a, snap)
  local d, err = ppi("batch", "tick", a, unpack(snap or {}))
  if not d then fatal(err) end
  return d
end

-- The guarded transition for an attempt whose delivery failed. If even that fails, end the script:
-- restart reconciliation holds the attempt instead.
local function hold(b, reason)
  local _, err = ppi("batch", "uncertain", tostring(b), reason)
  if err then fatal(string.format("batch %d left unresolved: %s", b, err)) end
end

-- One protected delivery step for batch b. The step returns true to go on, false to stop quietly
-- (check refused the batch and recorded why), or a reason and a message, which hold the batch;
-- an error inside the step holds it with reason error.
local function step(b, fn)
  local ok, res, msg = pcall(fn)
  if ok and type(res) == "boolean" then return res end
  local reason = ok and res or "error"
  say(string.format("batch %d: %s", b, tostring(ok and msg or res)))
  hold(b, reason)
  return false
end

local function checked(b, block)
  return function()
    local r, err = ppi("batch", "check", tostring(b), unpack(snapshot(block)))
    if not r then return "error", err end
    return r.result == "ok"
  end
end

local function deliver(d)
  local b, block, text = d.batch, d.block, d.text
  if not step(b, checked(b, block)) then return end
  if not step(b, function()
    local r, err = rex.call("block.event",
      { session_id = SESSION, block_id = block, event = { type = "paste", payload = { text = text } } })
    if r == nil then return "transport", "paste: " .. tostring(err) end
    return true
  end) then return end
  -- Paste and Enter go out as separate writes; the gap keeps a TUI from reading Enter as part of the paste.
  rex.after(0.3, function()
    if not step(b, checked(b, block)) then return end
    if not step(b, function()
      local w, err = rex.call("com.superlogical.terminal.write", { session_id = SESSION, block_id = block, args = { data = "\r" } })
      if w == nil or w.bytes_written ~= 1 then return "transport", "enter: " .. tostring(err or (w and w.bytes_written)) end
      return true
    end) then return end
    step(b, function()
      -- stale is an outcome, not a failure: a fast agent's Stop may already have released the batch.
      local r, err = ppi("batch", "submitted", tostring(b))
      if not r then return "error", err end
      return true
    end)
  end)
end

local function pass()
  for _, a in ipairs(aliases()) do
    local d = tick(a)
    if d.action == "status" then
      d = tick(a, snapshot(block_of(a) or fatal("no block recorded for " .. a)))
    end
    if d.action == "paste" then deliver(d) end
  end
  local f = io.open(HOME .. "/heartbeat", "w")
  if f then f:close() end
end

local waking = false
local function wake()
  if waking then return end
  waking = true
  rex.after(0.05, function()
    waking = false
    pass()
  end)
end

local colors = {
  delivered = "32", released = "32", ready = "32",
  queued = "33", reserved = "33", submitted = "33", observed = "33",
  failed = "31", blocked = "31", uncertain = "31", ["hook-failure"] = "31",
}
local function text_of(v)
  if type(v) == "string" then return v end
  if type(v) == "number" then return tostring(v) end
  return ""
end
local function show(line)
  local ok, e = pcall(rex.json.decode, line)
  if not ok or type(e) ~= "table" then return end
  local ref = ""
  if type(e.batch) == "number" then ref = "batch " .. e.batch .. " " elseif type(e.id) == "number" then ref = "#" .. e.id .. " " end
  print(string.format("%s %s → %s \27[%sm%s\27[0m %s%s", text_of(e.ts), text_of(e.from), text_of(e.to),
    colors[e.status] or "0", text_of(e.status), ref, text_of(e.msg)))
end

-- The bus log is a wake-up: a send, a hook's observation, an operator's resolution. The reader ends
-- itself within a second of this script's end, so a script killed before it records the reader
-- below leaves nothing running: the subshell watches this script ($PPID) and the reader ($$).
local partial = ""
local reader, rerr = rex.exec.start({ "/bin/sh", "-c",
  '(while sleep 1; do kill -0 $$ || exit 0; kill -0 $PPID || { kill $$; exit 0; }; done) >/dev/null 2>&1 &'
    .. ' exec tail -n 0 -F "$1"',
  "sh", HOME .. "/bus.jsonl" }, {
  stdout = function(chunk)
    partial = partial .. chunk
    for line in partial:gmatch("([^\n]*)\n") do show(line) end
    partial = partial:match("[^\n]*$")
    wake()
  end,
})
if not reader then fatal("cannot follow the bus log: " .. tostring(rerr)) end
-- The supervisor stops this reader if the script is killed; the start time tells it apart from
-- a later process with the same pid.
local started = rex.exec({ "ps", "-o", "lstart=", "-p", tostring(reader.pid) }, { timeout = 5 })
if not started or not started.ok then fatal("cannot read the bus reader's start time") end
put(HOME .. "/dispatcher.lock/reader", rex.json.encode({
  pid = reader.pid, start = (started.stdout:gsub("^%s+", ""):gsub("%s+$", "")),
}))

for _, a in ipairs(aliases()) do
  local _, err = ppi("batch", "restart", a)
  if err then fatal(err) end
end

rex.on("terminal.program_status_changed", wake)
rex.on("terminal.program_status_removed", wake)
rex.on("terminal.child_exited", wake)
rex.on("block_closed", function(_, ev)
  for _, a in ipairs(aliases()) do
    if block_of(a) == ev.block_id then tick(a, { "--closed" }) end
  end
end)
rex.every(1, pass)
pass()
