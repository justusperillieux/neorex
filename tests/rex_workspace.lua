-- Run the Rex entrypoint against a native-API stand-in, with no custom binary.
local root, runtime = vim.env.WORKSPACE_TEST_ROOT, vim.env.WORKSPACE_TEST_RUNTIME
local blocks = {
  { block_id = 'source-one', label = 'Agent', host_id = 'local', window_id = 'window:one', placement = 'placed' },
  { block_id = 'source-two', label = 'Agent', host_id = 'local', window_id = 'window:two', placement = 'placed' },
}
local bindings = { { key = 'cmd+e', action = 'personal' } }
local actions, created, dirty, running, launches, busy = {}, 0, false, {}, 0, false
local function position(argv, value)
  for index, item in ipairs(argv) do if item == value then return index end end
end
local function find(id)
  for _, block in ipairs(blocks) do if block.block_id == id then return block end end
end
rex = {
  json = vim.json,
  exec = function(argv)
    assert(not position(argv, 'status') and not position(argv, 'attach'), 'must not invoke the old Neorex binary')
    if position(argv, '/usr/bin/id') then return { ok = true, stdout = '501\n' } end
    if position(argv, runtime .. '/scripts/probe.lua') then
      return { ok = true, stdout = vim.json.encode(running[argv[#argv]] == true) }
    end
    if position(argv, '-l') then
      local state = vim.json.decode(table.concat(vim.fn.readfile(argv[#argv]), '\n'))
      assert(state.mode == 'native' and state.apply_rex_theme == true)
      launches = launches + 1; running[state.socket] = true
      return { ok = true, stdout = '{"pid":1234}' }
    end
    local server = position(argv, '--server')
    if server then
      local socket, expression = argv[server + 1], argv[#argv]
      if expression == '1' then return { ok = not busy and running[socket] == true, stdout = '1', stderr = 'not running' } end
      if expression:find('nvim_list_uis', 1, true) then
        local attached = 0
        for _, block in ipairs(blocks) do
          if block.socket == socket and (not block.process or block.process == 'nvim') then attached = attached + 1 end
        end
        return { ok = true, stdout = tostring(attached) }
      end
      if expression:find("vim.cmd", 1, true) then
        running[socket] = false
        for index = #blocks, 1, -1 do if blocks[index].socket == socket then table.remove(blocks, index) end end
        return { ok = true, stdout = 'true' }
      end
      return { ok = true, stdout = vim.json.encode(dirty) }
    end
    if position(argv, 'git') then return { ok = true, stdout = root .. '\n' } end
    return { ok = true, stdout = '', stderr = '' }
  end,
  action = function(def) actions[def.name] = def end,
  bindings = function(filter)
    local result = {}
    for _, binding in ipairs(bindings) do if binding.key == filter.key then result[#result + 1] = binding end end
    return result
  end,
  bind = function(key, action) bindings[#bindings + 1] = { key = key, action = action } end,
  call = function(method, args)
    if method == 'server.status' then return { host_id = 'local' }
    elseif method == 'session.view' then
      local windows = {}
      for _, id in ipairs({ 'window:one', 'window:two' }) do
        local placed = {}
        for _, block in ipairs(blocks) do if block.window_id == id then placed[#placed + 1] = block end end
        windows[#windows + 1] = { window_id = id, layers = { { blocks = placed } } }
      end
      return { windows = windows }
    elseif method == 'session.list_blocks' then return { blocks = blocks }
    elseif method == 'com.superlogical.terminal.process' then
      local block = find(args.block_id)
      return { foreground = { cwd = root, name = block and block.process or (block and block.socket and 'nvim' or 'zsh') } }
    elseif method == 'session.new_split' then
      local command = args.layout.block.options.command
      assert(position(command, '--remote-ui'), 'must use the built-in Neovim remote UI')
      created = created + 1
      local id = 'editor-' .. created
      blocks[#blocks + 1] = { block_id = id, label = args.layout.block.label, host_id = 'local',
        placement = 'placed', window_id = find(args.anchor_id).window_id, socket = command[position(command, '--server') + 1] }
      return { block_ids = { id } }
    elseif method == 'session.detach_block' then
      local block = find(args.block_id); block.placement, block.window_id = 'detached', nil; return {}
    elseif method == 'session.move_block' then
      local block = find(args.block_id)
      block.placement, block.window_id = 'placed', find(args.anchor_block_id).window_id; return {}
    elseif method == 'block.close' then
      for index, block in ipairs(blocks) do if block.block_id == args.block_id then table.remove(blocks, index); break end end
      return {}
    elseif method == 'session.focus_block' then return {} end
    error('Unexpected API: ' .. method)
  end,
}
local module = dofile(runtime .. '/neorex.lua').setup{ apply_rex_theme = true }
assert(bindings[1].action == 'personal', 'must preserve existing shortcuts')
assert(actions.neorex_toggle and actions.neorex_open and actions.neorex_preview)
local one, two = { session_id = 'test', block_id = 'source-one' }, { session_id = 'test', block_id = 'source-two' }
local first, second = module.perform(one, 'toggle'), module.perform(two, 'toggle')
assert(first.block ~= second.block and created == 2 and launches == 2, 'one server per tab')
assert(find(first.block).label == 'Neorex · ' .. vim.fs.basename(root))
assert(find(first.block).label == find(second.block).label, 'identical project titles must not merge editors')
find(first.block).label = 'My editor'
assert(module.perform(one, 'toggle').shown == false)
assert(find(first.block).label == 'My editor', 'preserve custom pane titles')
assert(module.perform(one, 'toggle').block == first.block and launches == 2, 'restore the same UI and server')
-- Rex can restore a saved editor pane as a shell while its server survives.
find(first.block).process = 'zsh'
local reattached = module.perform(one, 'toggle')
assert(reattached.block ~= first.block and launches == 2, 'attach the surviving server instead of toggling a restored shell')
assert(find(first.block), 'a restored terminal must be left untouched')
first = reattached
-- A saved pane can also outlive a server; a remembered PID must not block restart.
running[find(first.block).socket] = false
local restarted = module.perform(one, 'toggle')
assert(restarted.block ~= first.block and launches == 3, 'a stale editor pane must not prevent a fresh launch')
assert(find(first.block), 'do not close the stale terminal while replacing the editor')
first = restarted
dirty = true
local ok, err = pcall(module.perform, one, 'close')
assert(not ok and tostring(err):find('unsaved') and find(first.block), 'refuse closing modified work')
rex.call('block.close', { block_id = first.block })
busy = true
ok, err = pcall(module.perform, one, 'toggle')
assert(not ok and tostring(err):find('busy') and launches == 3, 'an unresponsive live editor must not be replaced')
busy = false
local recovered = module.perform(one, 'toggle')
assert(recovered.block ~= first.block and launches == 3, 'recover the existing native server after the UI closes')
assert(module.perform(one, 'status').running)
dirty = false
module.perform(one, 'close')
assert(not find(recovered.block) and find(second.block), 'close only the requested editor')
vim.opt.rtp:prepend(runtime)
local parts = require('neorex.workspace.preview').parts
assert(parts('before\n~~~mermaid\ngraph LR; A-->B\n~~~\nafter\n')[2].diagram)
for _, part in ipairs(parts('~~~~text\n~~~mermaid\ngraph LR\n~~~\n~~~~')) do assert(not part.diagram) end
local paths = require('neorex.workspace.history').paths('*** Update File: a file with spaces.rs\ncat src/main.rs:12')
assert(vim.tbl_contains(paths, 'a file with spaces.rs') and vim.tbl_contains(paths, 'src/main.rs'))
vim.cmd('qa!')
