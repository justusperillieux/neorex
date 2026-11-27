local T = require('neorex.workspace.transport')
local P = {}
local uv = vim.uv

function P.parts(text)
  local parts, lines, fence, opening = {}, {}, nil, nil
  for line in (text .. (text:sub(-1) == '\n' and '' or '\n')):gmatch('(.-)\n') do
    local trimmed = line:gsub('^%s+', '')
    local marker, count = trimmed:sub(1, 1), 0
    while trimmed:sub(count + 1, count + 1) == marker and count < #trimmed do count = count + 1 end
    local is_fence = (marker == '~' or marker == string.char(96)) and count >= 3 and #line - #trimmed <= 3
    if fence then
      if is_fence and marker == fence.marker and count >= fence.count and trimmed:sub(count + 1):match('^%s*$') then
        if fence.diagram then parts[#parts + 1] = { diagram = true, text = table.concat(lines, '\n') .. '\n' }; lines = {}
        else lines[#lines + 1] = line end
        fence = nil
      else lines[#lines + 1] = line end
    elseif is_fence then
      local mermaid = trimmed:sub(count + 1):match('^%s*(.-)%s*$') == 'mermaid'
      fence = { marker = marker, count = count, diagram = mermaid }
      if mermaid then
        parts[#parts + 1] = { diagram = false, text = #lines > 0 and table.concat(lines, '\n') .. '\n' or '' }
        lines, opening = {}, line
      else lines[#lines + 1] = line end
    else lines[#lines + 1] = line end
  end
  if fence and fence.diagram then table.insert(lines, 1, opening) end
  parts[#parts + 1] = { diagram = false, text = table.concat(lines, '\n') .. '\n' }
  return parts
end

local function image(path, size, callback)
  if vim.fn.executable('chafa') == 0 then callback(nil, 'Install chafa for image and SVG previews'); return end
  T.exec({ 'chafa', '--format=symbols', '--colors=full', '--size=' .. size, path }, function(result)
    callback(result.code == 0 and result.stdout or nil, result.code ~= 0 and result.stderr or nil)
  end)
end

local function diagram(code, size, callback)
  if vim.fn.executable('mmdc') == 0 or vim.fn.executable('chafa') == 0 then
    callback(nil, 'Mermaid rendering needs mmdc and chafa'); return
  end
  local directory = vim.fn.stdpath('cache') .. '/neorex/diagrams'
  vim.fn.mkdir(directory, 'p', 448)
  local theme = vim.o.background == 'light' and 'default' or 'dark'
  local hash = vim.fn.sha256(theme .. '\n' .. code)
  local input, output = directory .. '/' .. hash .. '.mmd', directory .. '/' .. hash .. '.svg'
  if uv.fs_stat(output) then image(output, size, callback); return end
  vim.fn.writefile(vim.split(code, '\n', { plain = true }), input)
  local temporary = directory .. '/' .. hash .. '.' .. uv.os_getpid() .. '.svg'
  T.exec({ 'mmdc', '--input', input, '--output', temporary, '--theme', theme, '--backgroundColor', 'transparent', '--quiet' }, function(result)
    if result.code ~= 0 then callback(nil, result.stderr); return end
    local ok, err = uv.fs_rename(temporary, output)
    if not ok then callback(nil, err); return end
    image(output, size, callback)
  end)
end

local function markdown(text, width, callback)
  if vim.fn.executable('glow') == 0 then callback(text); return end
  T.exec({ 'glow', '--style', vim.o.background, '--width', tostring(width), '-' }, function(result)
    callback(result.code == 0 and result.stdout or text)
  end, { stdin = text })
end

function P.render(path, width, height, callback)
  width, height = math.max(10, math.min(width or 90, 300)), math.max(5, math.min(height or 40, 200))
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then callback(nil, 'Preview file is missing: ' .. path); return end
  local ext, size = (path:match('%.([^./]+)$') or ''):lower(), width .. 'x' .. height
  if vim.tbl_contains({ 'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'avif', 'svg' }, ext) and vim.fn.executable('chafa') == 1 then
    image(path, size, function(rendered, err)
      callback(rendered and { kind = 'terminal', text = rendered } or nil, err)
    end)
    return
  end
  if vim.tbl_contains({ 'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'avif' }, ext) then callback(nil, 'Install chafa for image previews'); return end
  if stat.size > 2 * 1024 * 1024 then callback(nil, 'Text preview is limited to 2 MiB'); return end
  local file, err = io.open(path, 'rb')
  if not file then callback(nil, err); return end
  local contents = file:read('*a'); file:close()
  local function source(hint)
    callback({ kind = 'source', text = contents, filetype = vim.filetype.match({ filename = path }) or '', hint = hint })
  end
  if ext == 'mmd' or ext == 'mermaid' then
    diagram(contents, size, function(rendered, why)
      if rendered then callback({ kind = 'terminal', text = rendered })
      else source('Mermaid source shown: ' .. (why or 'renderer unavailable')) end
    end)
  elseif ext == 'md' or ext == 'markdown' then
    local parts, has_diagrams = P.parts(contents), false
    for _, part in ipairs(parts) do if part.diagram then has_diagrams = true end end
    if not has_diagrams then
      if vim.fn.executable('glow') == 0 then source(); return end
      markdown(contents, width, function(rendered) callback({ kind = 'terminal', text = rendered }) end)
      return
    end
    local rendered, failed = {}, false
    local function next_part(index)
      local part = parts[index]
      if not part then
        callback({ kind = 'terminal', text = table.concat(rendered),
          hint = failed and 'Some diagrams could not be rendered; their source is shown in place.' or nil })
        return
      end
      if part.diagram then
        diagram(part.text, size, function(output, why)
          failed = failed or not output
          rendered[#rendered + 1] = output or ('\nMermaid source (' .. (why or 'unavailable'):sub(1, 300) .. '):\n' .. part.text)
          next_part(index + 1)
        end)
      else markdown(part.text, width, function(output) rendered[#rendered + 1] = output; next_part(index + 1) end) end
    end
    next_part(1)
  else source() end
end

return P
