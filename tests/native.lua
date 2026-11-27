local runtime, root = vim.env.WORKSPACE_TEST_RUNTIME, vim.env.WORKSPACE_TEST_ROOT
local socket = '/tmp/neorex-test-' .. vim.uv.os_getpid() .. '.sock'
local file, state_file = root .. "/a file'$(ignored).md", root .. '/native.json'
local state = { mode = 'native', root = root, runtime = runtime, state = state_file,
  socket = socket, nvim = vim.v.progpath, session = 'test', window = 'test', rex_bin = '/not-a-real-rex',
  initial = { action = 'open', args = { file = { path = file, line = 2, column = 3 } } } }
vim.fn.writefile({ vim.json.encode(state) }, state_file)
local function remote(code)
  local expression = 'luaeval(' .. vim.fn.string('vim.json.encode(' .. code .. ')') .. ')'
  local result = vim.system({ vim.v.progpath, '--server', socket, '--remote-expr', expression }, { text = true, timeout = 2000 }):wait()
  if result.code ~= 0 then return nil, result.stderr end
  return vim.json.decode(result.stdout)
end
local ui, pid
local ok, err = pcall(function()
  local started = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-l', runtime .. '/scripts/start.lua', state_file }, { text = true, timeout = 20000 }):wait()
  assert(started.code == 0, started.stderr)
  pid = vim.json.decode(started.stdout).pid
  assert(pid > 0)
  assert(remote('#vim.api.nvim_list_uis()') == 0, 'server must survive its launcher exiting')
  local listed = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-l', runtime .. '/scripts/list.lua', root }, { text = true }):wait()
  assert(listed.code == 0 and vim.json.decode(listed.stdout)[1].socket == socket, 'list retained native editors')
  local function attach()
    local output = {}
    ui = vim.fn.jobstart({ '/usr/bin/env', '-u', 'NVIM', '-u', 'NEOREX', vim.v.progpath, '--server', socket, '--remote-ui' }, {
      pty = true, width = 100, height = 32, env = { TERM = 'xterm-256color' },
      on_stdout = function(_, lines) vim.list_extend(output, lines) end,
    })
    assert(ui > 0)
    assert(vim.wait(3000, function() return remote('#vim.api.nvim_list_uis()') == 1 end, 20), 'UI did not attach: ' .. table.concat(output, '\n'))
  end
  attach()
  assert(vim.wait(3000, function() return remote('vim.api.nvim_buf_get_name(0)') == file end, 20), 'initial open must wait for the UI')
  assert(remote('vim.api.nvim_win_get_cursor(0)')[1] == 2)
  assert(remote('#vim.api.nvim_list_wins()') == 1, 'no automatic tree panel')
  remote('(function() vim.api.nvim_buf_set_lines(0,1,2,false,{"unsaved native buffer"}); return true end)()')
  vim.fn.jobstop(ui); ui = nil
  assert(vim.wait(3000, function() return remote('#vim.api.nvim_list_uis()') == 0 end, 20))
  vim.wait(200)
  assert(remote('vim.bo.modified') == true, 'closing the UI must keep unsaved work')
  attach()
  assert(remote('vim.api.nvim_buf_get_lines(0,1,2,false)')[1] == 'unsaved native buffer')
  assert(remote('vim.fn.undotree().seq_cur') > 0, 'undo history must survive reattachment')
  remote('(function() vim.bo.modified=false; return true end)()')
  vim.fn.jobstop(ui); ui = nil
  assert(vim.wait(3000, function() return remote('1') == nil end, 20), 'clean server must exit after the last UI closes')
  assert(vim.fn.filereadable(state_file .. '.ready') == 0)
end)
if ui then vim.fn.jobstop(ui) end
if remote('1') then
  vim.system({ vim.v.progpath, '--server', socket, '--remote-send', '<C-\\><C-N>:qa!<CR>' }):wait()
end
if not ok and pid and vim.fn.filereadable(state_file .. '.ready') == 1 then
  assert(tonumber(vim.fn.readfile(state_file .. '.ready')[1]) == pid)
  vim.uv.kill(pid, 15)
end
vim.fn.delete(socket)
assert(ok, err)
vim.cmd('qa!')
