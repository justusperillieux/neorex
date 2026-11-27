-- A short-lived Neovim runs this Lua script to start a detached native server.
local file = assert(arg[1], 'workspace state path is required')
local state = vim.json.decode(table.concat(vim.fn.readfile(file), '\n'))
assert(state.mode == 'native' and state.socket and state.runtime)
assert(vim.fn.has('nvim-0.12') == 1, 'Neorex requires Neovim 0.12 or later')
local existing = vim.uv.fs_stat(state.socket)
if existing then
  local ok, channel = pcall(vim.fn.sockconnect, 'pipe', state.socket, { rpc = true })
  if ok and channel > 0 then vim.fn.chanclose(channel); error('An editor already listens on this socket') end
  assert(existing.type == 'socket', 'Refusing to replace a non-socket file')
  assert(vim.uv.fs_unlink(state.socket))
end
local ready = file .. '.ready'
vim.fn.delete(ready)
local setup = "lua vim.opt.rtp:prepend(" .. string.format('%q', state.runtime)
  .. "); require('neorex.workspace').setup{state=" .. string.format('%q', file) .. '} '
local argv = { '/usr/bin/env', '-u', 'NVIM', '-u', 'NEOREX',
  state.nvim or vim.v.progpath, '--headless', '--listen', state.socket, '-c', setup }
local errors = {}
local job = vim.fn.jobstart(argv, { cwd = state.root, detach = true, stdin = 'null',
  on_stderr = function(_, lines) vim.list_extend(errors, lines) end })
assert(job > 0, 'Could not start Neovim')
local pid = vim.fn.jobpid(job)
local ok = vim.wait(15000, function()
  return vim.uv.fs_stat(ready) ~= nil or vim.fn.jobwait({ job }, 0)[1] ~= -1
end, 20)
if not ok or not vim.uv.fs_stat(ready) then
  error('Neovim did not finish starting. ' .. table.concat(errors, '\n'))
end
io.stdout:write(vim.json.encode({ pid = pid }) .. '\n')
