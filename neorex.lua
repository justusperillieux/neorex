-- Rex entrypoint. The Neovim runtime lives beside this file in lua/.
local M = {}
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local checkout = source:match("^(.*)/[^/]+$") or "."
local function quote(value) return string.format("%q", value) end
local function join(a, b) return a:gsub("/$", "") .. "/" .. b end
local function exists(path)
  local file = io.open(path, "r")
  if file then file:close(); return true end
  return false
end
local function pane_title(root)
  local project = (root:gsub("/+$", ""):match("([^/]+)$") or "/"):gsub("%c", " ")
  local title, count = "Neorex · ", 0
  for character in project:gmatch("[^\128-\191][\128-\191]*") do
    count = count + 1
    if count > 118 then return title .. "…" end
    title = title .. character
  end
  return title
end

function M.setup(options)
  local opts = options or {}
  local home = assert(os.getenv("HOME"), "HOME is required")
  local runtime = opts.runtime or checkout
  local directory = join(os.getenv("XDG_STATE_HOME") or join(home, ".local/state"), "neorex/workspaces")
  local path = (opts.nvim_bin and opts.nvim_bin:match("^(.*)/") or "/opt/homebrew/bin")
    .. ":" .. join(home, ".local/bin") .. ":/opt/homebrew/bin:/usr/local/bin:" .. (os.getenv("PATH") or "/usr/bin:/bin")
  local nvim = opts.nvim_bin or (exists("/opt/homebrew/bin/nvim") and "/opt/homebrew/bin/nvim")
    or (exists("/usr/local/bin/nvim") and "/usr/local/bin/nvim") or "nvim"
  local bundled_rex = join(home, "Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex")
  local rex_bin = opts.rex_bin or (os.getenv("REX_BIN_DIR") and join(os.getenv("REX_BIN_DIR"), "rex"))
    or (exists(bundled_rex) and bundled_rex) or "rex"
  local busy = {}
  local function execute(argv, extra)
    local command = { "/usr/bin/env", "PATH=" .. path }
    for _, value in ipairs(argv) do command[#command + 1] = value end
    local result, err = rex.exec(command, extra or { timeout = 20 })
    if not result then error(err, 0) end
    return result
  end
  local identity = execute({ "/usr/bin/id", "-u" }, { timeout = 2 })
  assert(identity.ok and identity.stdout:match("^%d+%s*$"), "Cannot determine the local user ID")
  local sockets = "/tmp/neorex-" .. identity.stdout:match("%d+")
  for _, folder in ipairs({ directory, sockets }) do
    local made = execute({ "/bin/mkdir", "-p", folder }, { timeout = 2 })
    assert(made.ok, made.stderr)
    local private = execute({ "/bin/chmod", "700", folder }, { timeout = 2 })
    assert(private.ok, private.stderr)
  end
  assert(exists(join(runtime, "scripts/start.lua")), "Neorex runtime is missing scripts/start.lua")

  local function call(method, args)
    local result, err = rex.call(method, args)
    if err then error(err, 0) end
    return result
  end
  local function read_state(file)
    local stream = io.open(file, "r")
    if not stream then return {} end
    local data = stream:read("*a"); stream:close()
    return rex.json.decode(data) or {}
  end
  local function save(state)
    local stream = assert(io.open(state.state .. ".new", "w"))
    stream:write(assert(rex.json.encode(state))); stream:close()
    assert(os.rename(state.state .. ".new", state.state))
  end
  local function alive(state)
    local socket = state.socket
    if not socket then return false end
    local response = execute({ nvim, "--server", socket, "--remote-expr", "1" }, { timeout = 2 })
    if not response.ok and state.mode == "native" and type(state.pid) == "number"
      and execute({ "/bin/kill", "-0", tostring(state.pid) }, { timeout = 2 }).ok then
      error("Neovim is still running but is busy or starting; retry when it is responsive", 0)
    end
    return response.ok
  end
  local function evaluate(state, code)
    local expression = "luaeval('" .. ("vim.json.encode(" .. code .. ")"):gsub("'", "''") .. "')"
    local result = execute({ nvim, "--server", assert(state.socket), "--remote-expr", expression })
    if not result.ok then error(result.stderr, 0) end
    local value, err = rex.json.decode(result.stdout)
    if err then error(err, 0) end
    return value
  end
  local function dispatch(state, action, args)
    local encoded = assert(rex.json.encode(args or {}))
    local value = evaluate(state, "(_G.neorex_workspace == nil and {starting=true} or _G.neorex_workspace.dispatch("
      .. quote(action) .. "," .. quote(encoded) .. "))")
    if type(value) == "table" and value.starting then error("The editor is still starting", 0) end
    return value
  end
  local function context(ctx)
    assert(ctx.session_id and ctx.block_id, "Focus a Rex terminal first")
    local view = call("session.view", { session_id = ctx.session_id })
    for _, window in ipairs(view.windows or {}) do
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if block.block_id == ctx.block_id then
            local server = call("server.status", {})
            assert(not block.host_id or block.host_id == server.host_id, "Editing currently requires a terminal on this machine")
            return window
          end
        end
      end
    end
    error("The focused block is not in a Rex tab", 0)
  end
  local function location(file, root)
    local function absolute(name) return name:sub(1, 1) == "/" and name or join(root, name) end
    if exists(absolute(file)) then return { path = absolute(file), line = 1, column = 1 } end
    local name, line, col = file:match("^(.*):(%d+):(%d+)$")
    if not name then name, line = file:match("^(.*):(%d+)$") end
    return { path = absolute(name or file), line = math.max(1, tonumber(line) or 1), column = math.max(1, tonumber(col) or 1) }
  end

  function M.perform(ctx, action, args)
    args = args or {}
    local window = context(ctx)
    local id = window.window_id:gsub("[^%w]", "")
    if busy[id] then error("An editor action is already running in this tab", 0) end
    busy[id] = true
    local ok, result = pcall(function()
      local file = join(directory, id .. ".json")
      local state, existing = read_state(file), nil
      local listed = call("session.list_blocks", { session_id = ctx.session_id })
      for _, block in ipairs(listed.blocks or {}) do
        if block.block_id == state.block then existing = block; break end
      end
      if action == "status" then
        return { workspace = state, block = existing, running = alive(state), socket = state.socket }
      end
      if action == "close" then
        if alive(state) then
          if dispatch(state, "dirty") then error("Save or discard unsaved buffers before closing the editor", 0) end
          evaluate(state, "(function() vim.schedule(function() vim.cmd('qa') end); return true end)()")
        elseif existing then
          call("block.close", { session_id = ctx.session_id, block_id = existing.block_id })
        end
        return
      end
      if not existing then
        local running = alive(state)
        if not running then
          local process = call("com.superlogical.terminal.process", { session_id = ctx.session_id, block_id = ctx.block_id, args = {} })
          local cwd = process.foreground and process.foreground.cwd
            or process.ancestors and process.ancestors[1] and process.ancestors[1].cwd
          assert(cwd, "The terminal has no working directory")
          local git = execute({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
          local root = git.ok and git.stdout:gsub("[\r\n]+$", "") or cwd
          state = {
            mode = "native", session = ctx.session_id, window = window.window_id,
            source = ctx.block_id, root = root, state = file, runtime = runtime,
            socket = join(sockets, "lua-" .. id:sub(-24) .. ".sock"), nvim = nvim,
            apply_rex_theme = opts.apply_rex_theme == true,
            rex_bin = rex_bin, server = os.getenv("REX_SERVER"),
          }
          if action ~= "toggle" then
            state.initial = { action = action, args = args.file and { file = location(args.file, root) } or {} }
          end
          save(state)
          local started = execute({ nvim, "--headless", "-u", "NONE", "-i", "NONE", "-l", join(runtime, "scripts/start.lua"), file })
          if not started.ok then error(started.stderr, 0) end
          local launch = assert(rex.json.decode(started.stdout))
          state.pid = launch.pid
        end
        local split = call("session.new_split", {
          session_id = ctx.session_id, anchor_id = ctx.block_id,
          direction = "horizontal", side = "after", ratio = 0.42, focus = true,
          layout = { block = { flavor = "com.superlogical.terminal.shell", label = pane_title(state.root),
            options = { shell = "none", cwd = state.root, command = {
              "/usr/bin/env", "-u", "NVIM", "-u", "NEOREX", "PATH=" .. path,
              nvim, "--server", state.socket, "--remote-ui",
            } } } },
        })
        state.block = assert(split.block_ids and split.block_ids[1], "Rex did not create the editor")
        state.initial = nil
        save(state)
        existing = { block_id = state.block, placement = "placed" }
        if running and action ~= "toggle" then dispatch(state, action, args.file and { file = location(args.file, state.root) } or {}) end
      elseif existing.placement == "placed" and action == "toggle" then
        local others = false
        for _, block in ipairs(listed.blocks or {}) do
          if block.window_id == window.window_id and block.block_id ~= existing.block_id then others = true end
        end
        assert(others, "Keep another terminal in the tab before hiding its editor")
        call("session.detach_block", { session_id = ctx.session_id, block_id = existing.block_id })
        return { shown = false, block = existing.block_id }
      else
        if existing.placement ~= "placed" then
          call("session.move_block", { session_id = ctx.session_id, block_id = existing.block_id,
            anchor_block_id = ctx.block_id, direction = "horizontal", side = "after", ratio = 0.42 })
        end
        if action ~= "toggle" then dispatch(state, action, args.file and { file = location(args.file, state.root) } or {}) end
      end
      call("session.focus_block", { session_id = ctx.session_id, block_id = existing.block_id })
      return { shown = true, block = existing.block_id, root = state.root }
    end)
    busy[id] = nil
    if not ok then error(result, 0) end
    return result
  end

  for _, entry in ipairs({
    { "toggle", "Toggle editor" }, { "files", "Reveal file tree" }, { "pick", "Find file" },
    { "recent", "Agent files and changes" }, { "preview", "Preview current file" }, { "notes", "Review comments" },
    { "open", "Open file in editor" }, { "close", "Close editor" }, { "status", "Editor status" },
  }) do
    local action, title = entry[1], entry[2]
    rex.action { name = "neorex_" .. action, title = "Neorex: " .. title, category = "Editor",
      args = action == "open" and { file = "string" } or nil,
      run = function(ctx, args) return M.perform(ctx, action, args) end }
  end
  rex.action { name = "neorex_list", title = "Neorex: List editors", category = "Editor", run = function()
    local result = execute({ nvim, "--headless", "-u", "NONE", "-i", "NONE", "-l", join(runtime, "scripts/list.lua"), directory })
    if not result.ok then error(result.stderr, 0) end
    return assert(rex.json.decode(result.stdout))
  end }
  for _, entry in ipairs({ { "cmd+e", "toggle" }, { "cmd+o", "recent" }, { "shift+cmd+e", "files" } }) do
    if #rex.bindings { key = entry[1] } == 0 then rex.bind(entry[1], "neorex_" .. entry[2]) end
  end
  return M
end
return M
