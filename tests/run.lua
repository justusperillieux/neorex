local runtime = assert(vim.uv.cwd())
assert(vim.fn.has('nvim-0.12') == 1, 'Neorex tests require Neovim 0.12 or later')
local function run(name)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/neorex/workspaces', 'p')
  root = assert(vim.uv.fs_realpath(root))
  local file, state = root .. "/a file'$(ignored).md", root .. '/state.json'
  vim.fn.writefile({ '# Heading', 'original' }, file)
  vim.fn.writefile({ vim.json.encode({ root = root, state = state, session = 'test', window = 'test',
    server = 'unix:///not-a-real-rex', rex_bin = '/not-a-real-rex' }) }, state)
  local result = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-l', runtime .. '/tests/' .. name .. '.lua' }, {
    text = true, timeout = 30000, env = { WORKSPACE_TEST_ROOT = root, WORKSPACE_TEST_RUNTIME = runtime,
      WORKSPACE_TEST_TOOL = 'neorex', NEOREX_WORKSPACE_STATE = state, XDG_STATE_HOME = root,
      XDG_CONFIG_HOME = root .. '/config', NVIM_APPNAME = 'neorex-test' },
  }):wait()
  if result.code ~= 0 then error(name .. ':\n' .. result.stdout .. '\n' .. result.stderr) end
  if name == 'workspace' then
    assert(vim.fn.readfile(file)[2] == 'original', 'test must restore file contents')
    local notes = vim.json.decode(table.concat(vim.fn.readfile(root .. '/state.notes.json'), '\n'))
    assert(notes[1].text == 'Please keep this heading')
  end
  vim.fn.delete(root, 'rf')
  print('PASS ' .. name)
end
local selected = arg[1]
assert(not selected or vim.tbl_contains({ 'workspace', 'rex_workspace', 'theme', 'native' }, selected), 'unknown test target')
for _, name in ipairs({ 'workspace', 'rex_workspace', 'theme', 'native' }) do
  if not selected or selected == name then run(name) end
end
vim.cmd('qa!')
