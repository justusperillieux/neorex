local T = require('neorex.workspace.transport')
local H = {}
local uv = vim.uv

local function collect(path, depth, files)
  local scan = uv.fs_scandir(path)
  if not scan then return end
  while true do
    local name, kind = uv.fs_scandir_next(scan)
    if not name then break end
    local child = path .. '/' .. name
    if kind == 'directory' and depth > 0 then collect(child, depth - 1, files)
    elseif kind == 'file' and name:sub(-6) == '.jsonl' then
      local stat = uv.fs_stat(child)
      files[#files + 1] = { path = child, time = stat and stat.mtime.sec or 0 }
    end
  end
end

function H.paths(text)
  local found = {}
  for line in text:gmatch('[^\n]+') do
    for _, prefix in ipairs({ '*** Update File: ', '*** Add File: ', '*** Delete File: ', '*** Move to: ' }) do
      if line:sub(1, #prefix) == prefix then found[#found + 1] = line:sub(#prefix + 1) end
    end
  end
  local separated = text:gsub('["\'%[%]%(%){};,=<>]', ' '):gsub(string.char(96), ' ')
  for word in separated:gmatch('%S+') do
    word = word:gsub('^[*+:]+', ''):gsub('[*:]+$', ''):gsub(':%d+.*$', '')
    if word:find('/', 1, true) or word:find('.', 1, true) then found[#found + 1] = word end
  end
  return found
end

local function tool_paths(value, found)
  if type(value) ~= 'table' then return end
  for key, item in pairs(value) do
    if (key == 'file_path' or key == 'path' or key == 'file') and type(item) == 'string' then found[#found + 1] = item
    elseif type(item) == 'string' and (key == 'cmd' or key == 'command' or key == 'patch' or key == 'input') then
      vim.list_extend(found, H.paths(item))
    elseif type(item) == 'table' then tool_paths(item, found) end
  end
end

local function matches_root(path, root)
  local file = io.open(path, 'r')
  if not file then return false end
  local matches = false
  for _ = 1, 12 do
    local line = file:read('*l')
    if not line then break end
    local ok, data = pcall(vim.json.decode, line)
    if ok and type(data) == 'table' then
      local cwd = data.cwd or (type(data.payload) == 'table' and data.payload.cwd)
      if cwd and (cwd == root or cwd:sub(1, #root + 1) == root .. '/') then matches = true; break end
    end
  end
  file:close()
  return matches
end

local function transcript(path)
  local references, file = {}, io.open(path, 'r')
  if not file then return references end
  local size = file:seek('end')
  local start = math.max(0, size - 8 * 1024 * 1024)
  file:seek('set', start)
  if start > 0 then file:read('*l') end
  for line in file:lines() do
    if #line <= 2 * 1024 * 1024 then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == 'table' then
        local payload = type(event.payload) == 'table' and event.payload or {}
        if payload.type == 'custom_tool_call' and type(payload.input) == 'string' then vim.list_extend(references, H.paths(payload.input))
        elseif payload.type == 'function_call' and type(payload.arguments) == 'string' then
          local valid, arguments = pcall(vim.json.decode, payload.arguments)
          if valid then tool_paths(arguments, references) end
        end
        local message = type(event.message) == 'table' and event.message or {}
        local content = type(message.content) == 'table' and message.content or {}
        for _, block in ipairs(content) do
          if block.type == 'tool_use' then tool_paths(block.input, references) end
        end
      end
    end
  end
  file:close()
  return references
end

function H.recent(state, callback)
  local references, source, logs = {}, 'Agent terminal and Git changes', {}
  local home = vim.uv.os_homedir()
  collect(home .. '/.codex/sessions', 4, logs)
  collect(home .. '/.claude/projects', 2, logs)
  table.sort(logs, function(a, b) return a.time > b.time end)
  for index, log in ipairs(logs) do
    if index > 150 then break end
    if matches_root(log.path, state.root) then
      references = transcript(log.path)
      source = 'Latest repository transcript: ' .. vim.fs.basename(log.path)
      break
    end
  end
  T.exec({ state.rex_bin, 'capture', '-s', state.session, '-b', state.source, '--trim', '--unwrap' }, function(screen)
    if screen.code == 0 then vim.list_extend(references, H.paths(screen.stdout:sub(-131072))) end
    local seen, items, root = {}, {}, uv.fs_realpath(state.root) or state.root
    for i = #references, 1, -1 do
      local path = references[i]:sub(1, 1) == '/' and references[i] or root .. '/' .. references[i]
      path = uv.fs_realpath(path)
      local stat = path and uv.fs_stat(path)
      if path and stat and stat.type == 'file' and path:sub(1, #root + 1) == root .. '/' and not seen[path] then
        seen[path] = true
        items[#items + 1] = { path = path, label = vim.fs.relpath(root, path) or path, kind = 'agent' }
      end
    end
    T.exec({ 'git', '-C', root, 'status', '--porcelain=v1', '-z', '--untracked-files=all' }, function(git)
      if git.code == 0 then
        local records = vim.split(git.stdout, '\0', { plain = true, trimempty = true })
        local index = 1
        while index <= #records do
          local record = records[index]
          local mark, path = record:sub(1, 2), record:sub(4)
          if not seen[root .. '/' .. path] then
            items[#items + 1] = { path = root .. '/' .. path, label = path .. ' [' .. mark .. ']', kind = 'git' }
          end
          index = index + (mark:find('[RC]') and 2 or 1)
        end
      end
      callback({ source = source, items = items })
    end)
  end)
end

return H
