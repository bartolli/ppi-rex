-- ppi lifecycle probe: record the Rex side of the evidence.
--
--   rex do trace.lua trace=FILE home=PPI_HOME arms=claude,codex
--
-- Appends one JSON line per event to FILE, in receipt order, for the session the
-- script hears. Hooks append to the same file, so the file order is the common-host
-- order of everything the probe saw. Each line carries the local receipt time (hr,
-- Unix seconds with milliseconds) next to whatever the event itself says.
local trace = assert(rex.args.trace, "trace=FILE is required")
local home = rex.args.home
local arms = {}
for name in tostring(rex.args.arms or ""):gmatch("[^,]+") do arms[#arms + 1] = name end

local seq = 0

local function hr()
  local r = rex.exec({ "perl", "-MTime::HiRes=time", "-e", 'printf "%.3f", time' })
  if r and r.ok then return tonumber(r.stdout) end
  return os.time()
end

-- The alias registered for a block, read from the bus directory on every event:
-- blocks register after the tracer starts.
local function alias_of(block_id)
  if not home then return nil end
  for _, name in ipairs(arms) do
    local f = io.open(home .. "/panes/" .. name, "r")
    if f then
      local id = f:read("*l")
      f:close()
      if id == block_id then return name end
    end
  end
  return nil
end

local function emit(line)
  seq = seq + 1
  line.src = "rex"
  line.seq = seq
  line.hr = hr()
  local f = assert(io.open(trace, "a"))
  f:write(rex.json.encode(line), "\n")
  f:close()
end

local function block_line(ctx, ev, event)
  return {
    event = event,
    block = ctx.block_id,
    alias = alias_of(ctx.block_id),
    session = ctx.session_id,
  }
end

-- What a read returns right after the event: the design must not depend on a brief
-- record surviving until the dispatcher looks.
local function snapshot(ctx)
  local r, err = rex.call("com.superlogical.terminal.program_status",
    { session_id = ctx.session_id, block_id = ctx.block_id, args = {} })
  if r == nil then return { error = err } end
  return r.records
end

rex.on("terminal.program_status_changed", function(ctx, ev)
  local line = block_line(ctx, ev, "program_status_changed")
  line.id = ev.id
  line.record = ev.record
  line.reason = ev.reason
  line.snapshot = snapshot(ctx)
  emit(line)
end)

rex.on("terminal.program_status_removed", function(ctx, ev)
  local line = block_line(ctx, ev, "program_status_removed")
  line.ids = ev.ids
  line.reason = ev.reason
  line.snapshot = snapshot(ctx)
  emit(line)
end)

rex.on("terminal.child_exited", function(ctx, ev)
  local line = block_line(ctx, ev, "child_exited")
  line.exit_code = ev.exit_code
  line.error = ev.error
  line.snapshot = snapshot(ctx)
  emit(line)
end)

rex.on("terminal.process_changed", function(ctx, ev)
  local line = block_line(ctx, ev, "process_changed")
  line.generation = ev.generation
  if ev.foreground then
    line.foreground = { pid = ev.foreground.pid, name = ev.foreground.name }
  end
  emit(line)
end)

rex.on("block_created", function(ctx, ev)
  emit({ event = "block_created", block = ev.block_id, session = ctx.session_id })
end)

rex.on("block_closed", function(ctx, ev)
  emit({ event = "block_closed", block = ev.block_id, alias = alias_of(ev.block_id), session = ctx.session_id })
end)

local v = rex.call("server.version") or {}
emit({ event = "start", session = rex.session_id, server_version = v.version, api_revision = v.api_revision })
