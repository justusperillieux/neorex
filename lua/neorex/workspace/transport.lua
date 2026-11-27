-- Neovim-side access to the existing Rex CLI. No helper process of our own.
local T = {}

function T.exec(argv, callback, options)
  local opts = vim.tbl_extend('force', { text = true, timeout = 25000 }, options or {})
  local ok, result = pcall(vim.system, argv, opts, vim.schedule_wrap(callback))
  if not ok then vim.schedule(function() callback({ code = 127, stdout = '', stderr = tostring(result) }) end) end
end

function T.rex(state, method, args, callback)
  local argv = { state.rex_bin }
  if state.server then vim.list_extend(argv, { '-S', state.server }) end
  vim.list_extend(argv, { 'api', 'call', '-s', state.session, method,
    vim.json.encode(next(args or {}) and args or vim.empty_dict()) })
  T.exec(argv, function(result)
    if result.code ~= 0 then callback(nil, result.stderr); return end
    local ok, value = pcall(vim.json.decode, result.stdout)
    callback(ok and value or nil, not ok and 'Rex returned invalid JSON' or nil)
  end)
end

function T.agents(state, callback)
  T.rex(state, 'session.list_blocks', {}, function(list, err)
    if not list then callback(nil, err); return end
    local blocks, agents = list.blocks or {}, {}
    local function next_block(index)
      local block = blocks[index]
      if not block then callback(agents); return end
      if block.window_id ~= state.window or block.block_id == state.block then next_block(index + 1); return end
      T.rex(state, 'com.superlogical.terminal.process', { block_id = block.block_id, args = vim.empty_dict() }, function(process)
        local foreground = process and process.foreground or {}
        local name = foreground.name or ''
        for _, agent in ipairs({ 'codex', 'claude', 'pi', 'aider', 'opencode', 'gemini', 'goose', 'amp' }) do
          if name:find(agent, 1, true) then
            agents[#agents + 1] = { block = block.block_id, name = name, label = block.label, pid = foreground.pid }
            break
          end
        end
        next_block(index + 1)
      end)
    end
    next_block(1)
  end)
end

function T.send(state, block, submit, text, callback)
  T.agents(state, function(agents, err)
    if not agents then callback(nil, err); return end
    local present = false
    for _, agent in ipairs(agents) do if agent.block == block then present = true end end
    if not present then callback(nil, 'The selected agent is no longer running in this tab'); return end
    T.exec({ state.rex_bin, 'send', '-s', state.session, '-b', block }, function(result)
      if result.code ~= 0 then callback(nil, result.stderr); return end
      local function focus()
        T.rex(state, 'session.focus_block', { block_id = block }, function(_, focus_error)
          callback(not focus_error, focus_error)
        end)
      end
      if submit then
        T.exec({ state.rex_bin, 'send-key', '-s', state.session, '-b', block, 'enter' }, function(sent)
          if sent.code ~= 0 then callback(nil, sent.stderr) else focus() end
        end)
      else focus() end
    end, { stdin = text })
  end)
end

return T
