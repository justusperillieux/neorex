-- List live native editors without a custom command-line executable.
local directory, states = assert(arg[1], 'workspace directory is required'), {}
for _, file in ipairs(vim.fn.globpath(directory, '*.json', false, true)) do
  if not file:match('%.notes%.json$') then
    local ok, state = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(file), '\n')) end)
    if ok and state.mode == 'native' and state.socket then
      local connected, channel = pcall(vim.fn.sockconnect, 'pipe', state.socket, { rpc = true })
      if connected and channel > 0 then
        vim.fn.chanclose(channel)
        states[#states + 1] = { root = state.root, socket = state.socket, pid = state.pid,
          session = state.session, window = state.window, block = state.block }
      end
    end
  end
end
io.stdout:write(vim.json.encode(states) .. '\n')
