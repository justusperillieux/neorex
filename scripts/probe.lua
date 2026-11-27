-- Check the listening socket even when Neovim cannot answer an RPC request.
local socket = assert(arg[1], 'editor socket is required')
local ok, channel = pcall(vim.fn.sockconnect, 'pipe', socket, { rpc = true })
local listening = ok and channel > 0
if listening then vim.fn.chanclose(channel) end
io.stdout:write(vim.json.encode(listening) .. '\n')
