-- Loaded after the person's init.lua. This runtime owns only its buffers,
-- commands and currently unbound keys.
local Plugin = {}
function Plugin.setup(options)
  local api, uv = vim.api, vim.uv
  local tool = 'neorex'
  local state_path = assert(options.state, 'workspace state is required')
  local T = require('neorex.workspace.transport')
  local H = require('neorex.workspace.history')
  local P = require('neorex.workspace.preview')
  local function read_json(path, fallback)
    local ok, value = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    end)
    return ok and value or fallback
  end
  local state = read_json(state_path, {})
  local root = state.root
  state.server = state.server or vim.env.REX_SERVER
  state.rex_bin = state.rex_bin or (vim.env.REX_BIN_DIR and (vim.env.REX_BIN_DIR .. '/rex')) or vim.fn.exepath('rex')
  if state.rex_bin == '' then state.rex_bin = 'rex' end
  local M = { root = root, expanded = { [root] = true }, rows = {}, notes = {}, marks = {} }
  _G[tool .. '_workspace'] = M
  local namespace = api.nvim_create_namespace(tool .. '_comments')
  local located_notes
  local notes_path = state_path:gsub('%.json$', '.notes.json')
  M.notes = read_json(notes_path, {})
  M.editwin = api.nvim_get_current_win()
  local function notify(message, level) vim.notify(tool .. ': ' .. message, level) end
  local function valid(win) return win and api.nvim_win_is_valid(win) end
  local function relative(path)
    return vim.fs.relpath(root, path) or path
  end
  local function scratch(name, ft)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, tool .. '://' .. name)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    if ft then vim.bo[buf].filetype = ft end
    return buf
  end
  local function lines(buf, text)
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, text)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  end
  local function map(buf, key, callback, mode)
    vim.keymap.set(mode or 'n', key, callback, { buffer = buf, silent = true, nowait = true })
  end
  local function save_notes()
    if located_notes then M.notes = located_notes() end
    local tmp = notes_path .. '.new'
    vim.fn.writefile({ vim.json.encode(M.notes) }, tmp)
    assert(uv.fs_rename(tmp, notes_path))
  end
  local function active_file()
    if M.preview_source and api.nvim_buf_is_valid(M.preview_source) then
      return api.nvim_buf_get_name(M.preview_source)
    end
    if valid(M.editwin) then
      local buf = api.nvim_win_get_buf(M.editwin)
      if vim.bo[buf].buftype == '' then return api.nvim_buf_get_name(buf) end
    end
  end
  local function editor()
    if not valid(M.editwin) then
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if not M.creating_tree and win ~= M.treewin and api.nvim_win_get_config(win).relative == '' then M.editwin = win; break end
      end
    end
    if not valid(M.editwin) then vim.cmd('botright vsplit'); M.editwin = api.nvim_get_current_win() end
    api.nvim_set_current_win(M.editwin)
  end
  local function refresh_marks()
    if located_notes then M.notes = located_notes() end
    api.nvim_buf_clear_namespace(0, namespace, 0, -1)
    local path = api.nvim_buf_get_name(0)
    for index, note in ipairs(M.notes) do
      if note.path == path then
        local line = math.min(note.line, api.nvim_buf_line_count(0))
        local mark = api.nvim_buf_set_extmark(0, namespace, line - 1, 0, {
          virt_text = { { '  ◆ ' .. note.text:gsub('\n', ' '), 'DiagnosticInfo' } },
          virt_text_pos = 'eol', strict = false,
          end_row = math.min(math.max(note.last or line, line), api.nvim_buf_line_count(0)), end_col = 0,
        })
        M.marks[index] = { buf = api.nvim_get_current_buf(), id = mark }
      end
    end
  end
  function M.open(file)
    if M.preview_restore then M.preview_restore() end
    editor()
    M.preview_source = nil
    local path = type(file) == 'table' and file.path or file
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    if type(file) == 'table' then
      local line = math.min(file.line or 1, api.nvim_buf_line_count(0))
      local text = api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ''
      api.nvim_win_set_cursor(0, { line, math.min((file.column or 1) - 1, #text) })
    end
    refresh_marks()
  end
  local function data(action, arguments, callback, stdin)
    arguments = arguments or {}
    local function done(result, err)
      if err then notify(err, vim.log.levels.ERROR); return end
      if callback then callback(result) end
    end
    if action == 'recent' then H.recent(state, done)
    elseif action == 'preview' then P.render(arguments[1], tonumber(arguments[2]), tonumber(arguments[3]), done)
    elseif action == 'agents' then T.agents(state, done)
    elseif action == 'send' then T.send(state, arguments[1], arguments[2] == '--submit', stdin, done) end
  end

  -- A local fuzzy picker, independent of the person's plugin manager.
  function M.picker(items, title, selected, all_items)
    if #items == 0 and all_items then items = all_items end
    if #items == 0 then notify('No files to show'); return end
    local width = math.max(20, math.min(100, vim.o.columns - 6))
    local height = math.max(3, math.min(20, vim.o.lines - 9))
    local row, col = math.max(0, math.floor((vim.o.lines - height - 4) / 2)), math.max(0, math.floor((vim.o.columns - width) / 2))
    local list = scratch('picker-' .. tostring(uv.hrtime()))
    local prompt = scratch('query-' .. tostring(uv.hrtime()))
    local listwin = api.nvim_open_win(list, false, {
      relative = 'editor', width = width, height = height, row = row, col = col,
      style = 'minimal', border = 'rounded', title = ' ' .. title .. ' ', title_pos = 'center',
    })
    local promptwin = api.nvim_open_win(prompt, true, {
      relative = 'editor', width = width, height = 1, row = row + height + 2, col = col,
      style = 'minimal', border = 'rounded', title = ' Type to filter · Enter open · Esc cancel ',
    })
    local filtered, current, closed = items, 1, false
    local function close()
      if closed then return end
      closed = true
      vim.cmd('stopinsert')
      if valid(promptwin) then api.nvim_win_close(promptwin, true) end
      if valid(listwin) then api.nvim_win_close(listwin, true) end
    end
    local function render()
      if closed or not valid(listwin) then return end
      local query = (api.nvim_buf_get_lines(prompt, 0, 1, false)[1] or '')
      filtered = query == '' and items or vim.fn.matchfuzzy(all_items or items, query, { key = 'label' })
      current = math.max(1, math.min(current, #filtered))
      local shown = {}
      for i, item in ipairs(filtered) do shown[i] = (i == current and '› ' or '  ') .. item.label end
      lines(list, #shown > 0 and shown or { '  No matches' })
      if #filtered > 0 then api.nvim_win_set_cursor(listwin, { current, 0 }) end
    end
    api.nvim_buf_attach(prompt, false, { on_lines = function() vim.schedule(render) end })
    local function move(delta) current = math.max(1, math.min(#filtered, current + delta)); render() end
    for _, mode in ipairs({ 'i', 'n' }) do
      map(prompt, '<Esc>', close, mode)
      map(prompt, '<CR>', function()
        local item = filtered[current]
        close()
        if item then (selected or function(it) M.open(it.path) end)(item) end
      end, mode)
      map(prompt, '<Down>', function() move(1) end, mode)
      map(prompt, '<Up>', function() move(-1) end, mode)
      map(prompt, '<C-n>', function() move(1) end, mode)
      map(prompt, '<C-p>', function() move(-1) end, mode)
    end
    render()
    vim.cmd('startinsert')
  end
  local function repository_files(callback)
    vim.system({ 'git', '-C', root, 'ls-files', '-co', '--exclude-standard', '-z' }, {}, vim.schedule_wrap(function(result)
      local items, seen = {}, {}
      for path in (result.code == 0 and result.stdout or ''):gmatch('[^%z]+') do
        if not seen[path] then
          seen[path] = true
          items[#items + 1] = { path = root .. '/' .. path, label = path }
        end
      end
      callback(items)
    end))
  end
  function M.pick()
    repository_files(function(items) M.picker(items, 'Find file') end)
  end
  function M.recent()
    data('recent', {}, function(result)
      repository_files(function(files)
        local combined, seen = vim.deepcopy(result.items), {}
        for _, item in ipairs(combined) do seen[item.path] = true end
        for _, item in ipairs(files) do if not seen[item.path] then combined[#combined + 1] = item end end
        M.picker(result.items, result.source, function(item) M.open(item.path) end, combined)
      end)
    end)
  end

  -- File tree. Root and expanded folders are refreshed while visible.
  M.git, M.ignored, M.selected = {}, {}, {}
  local function repaint()
    if not valid(M.treewin) then return end
    local cursor = api.nvim_win_get_cursor(M.treewin)[1]
    local selected = M.rows[cursor] and M.rows[cursor].path
    local rows, output = {}, {}
    local function walk(folder, depth)
      if #rows > 5000 then return end
      local scan = uv.fs_scandir(folder)
      if not scan then return end
      local children = {}
      while true do
        local name, kind = uv.fs_scandir_next(scan)
        if not name then break end
        local path = folder .. '/' .. name
        if name ~= '.git' and (M.hidden or name:sub(1, 1) ~= '.') and (M.show_ignored or not M.ignored[relative(path)]) then
          children[#children + 1] = { name = name, path = path, directory = kind == 'directory' }
        end
      end
      table.sort(children, function(a, b)
        if a.directory ~= b.directory then return a.directory end
        return a.name:lower() < b.name:lower()
      end)
      for _, child in ipairs(children) do
        rows[#rows + 1] = child
        local indicator = child.directory and (M.expanded[child.path] and '▾ ' or '▸ ') or '  '
        local mark = M.git[relative(child.path)] or ''
        output[#output + 1] = string.rep('  ', depth) .. (M.selected[child.path] and '● ' or indicator) .. child.name .. ' ' .. mark
        if child.path == selected then cursor = #rows end
        if child.directory and M.expanded[child.path] then walk(child.path, depth + 1) end
      end
    end
    walk(M.tree_root or root, 0)
    M.rows = rows
    lines(M.treebuf, #output > 0 and output or { '(empty folder)' })
    api.nvim_win_set_cursor(M.treewin, { math.max(1, math.min(cursor, math.max(1, #rows))), 0 })
  end
  local function git_status()
    if not valid(M.treewin) then return end
    vim.system({ 'git', '-C', root, 'status', '--porcelain=v1', '-z', '--ignored=matching' }, {}, vim.schedule_wrap(function(result)
      if result.code ~= 0 then return end
      M.git, M.ignored = {}, {}
      local records = vim.split(result.stdout, '\0', { plain = true, trimempty = true })
      local i = 1
      while i <= #records do
        local record = records[i]
        local mark, path = record:sub(1, 2), record:sub(4):gsub('/$', '')
        if mark == '!!' then M.ignored[path] = true
        else M.git[path] = mark:gsub(' ', '') end
        if mark:find('[RC]') then i = i + 1 end
        i = i + 1
      end
      repaint()
    end))
  end
  local function row() return valid(M.treewin) and M.rows[api.nvim_win_get_cursor(M.treewin)[1]] end
  local function folder()
    local selected = row()
    return selected and (selected.directory and selected.path or vim.fs.dirname(selected.path)) or root
  end
  local function operation(paths, operation_fn)
    local outside = false
    local realroot = uv.fs_realpath(root)
    for _, path in ipairs(paths) do
      local actual = uv.fs_realpath(path) or uv.fs_realpath(vim.fs.dirname(path))
      if not actual or (actual ~= realroot and actual:sub(1, #realroot + 1) ~= realroot .. '/') then outside = true end
    end
    if outside then
      vim.ui.select({ 'Cancel', 'Continue outside repository' }, { prompt = 'This operation follows a path outside the repository' }, function(choice)
        if choice == 'Continue outside repository' then operation_fn() end
      end)
    else operation_fn() end
  end
  local function rename(source, target, allow_save)
    if uv.fs_stat(target) then notify('Destination already exists'); return end
    if not allow_save then
      for _, buf in ipairs(api.nvim_list_bufs()) do
        local name = api.nvim_buf_get_name(buf)
        if (name == source or name:sub(1, #source + 1) == source .. '/') and vim.bo[buf].modified then
          vim.ui.select({ 'Cancel', 'Save and rename' },
            { prompt = 'Neovim saves modified buffers when renaming. Save and rename this path?' },
            function(choice) if choice == 'Save and rename' then rename(source, target, true) end end)
          return
        end
      end
    end
    operation({ source, target }, function()
      local files = { { oldUri = vim.uri_from_fname(source), newUri = vim.uri_from_fname(target) } }
      for _, client in ipairs(vim.lsp.get_clients()) do
        if client:supports_method('workspace/willRenameFiles') then
          local answer = client:request_sync('workspace/willRenameFiles', { files = files }, 1000)
          if answer and answer.result then vim.lsp.util.apply_workspace_edit(answer.result, client.offset_encoding) end
        end
      end
      local ok, err = pcall(vim.lsp.util.rename, source, target, { overwrite = false })
      if not ok or not uv.fs_stat(target) then notify(tostring(err or 'Rename did not complete'), vim.log.levels.ERROR); return end
      for _, note in ipairs(M.notes) do
        if note.path == source or note.path:sub(1, #source + 1) == source .. '/' then note.path = target .. note.path:sub(#source + 1) end
      end
      save_notes()
      for _, client in ipairs(vim.lsp.get_clients()) do
        if client:supports_method('workspace/didRenameFiles') then client:notify('workspace/didRenameFiles', { files = files }) end
      end
      git_status()
      repaint()
    end)
  end
  local function chosen()
    local paths = vim.tbl_keys(M.selected)
    if #paths == 0 and row() then paths = { row().path } end
    return paths
  end
  local function copy_into(paths, target)
    operation(vim.list_extend(vim.deepcopy(paths), { target }), function()
      local function next_copy(index)
        local source = paths[index]
        if not source then M.selected = {}; git_status(); repaint(); return end
        local dest = target .. '/' .. vim.fs.basename(source)
        if uv.fs_stat(dest) then notify('Destination already exists: ' .. dest); return end
        vim.system({ 'cp', '-R', '-n', source, dest }, { text = true }, vim.schedule_wrap(function(result)
          if result.code ~= 0 then notify(result.stderr); return end
          next_copy(index + 1)
        end))
      end
      next_copy(1)
    end)
  end
  function M.files(reveal)
    if not valid(M.treewin) then
      editor()
      local previous = M.editwin
      M.creating_tree = true
      vim.cmd('topleft 30vsplit')
      M.treewin = api.nvim_get_current_win()
      if not M.treebuf or not api.nvim_buf_is_valid(M.treebuf) then M.treebuf = api.nvim_create_buf(false, true) end
      api.nvim_win_set_buf(M.treewin, M.treebuf)
      M.editwin = previous
      M.creating_tree = false
      api.nvim_buf_set_name(M.treebuf, tool .. '://files')
      vim.bo[M.treebuf].buftype = 'nofile'
      vim.bo[M.treebuf].bufhidden = 'hide'
      vim.bo[M.treebuf].swapfile = false
      vim.wo[M.treewin].number, vim.wo[M.treewin].relativenumber = false, false
      vim.cmd('vertical resize 30')
      vim.wo[M.treewin].winfixwidth = true
      vim.wo[M.treewin].cursorline = true
      local function enter()
        local item = row()
        if not item then return end
        if item.directory then M.expanded[item.path] = not M.expanded[item.path]; repaint()
        else M.open(item.path) end
      end
      for _, key in ipairs({ '<CR>', 'l', '<Right>' }) do map(M.treebuf, key, enter) end
      map(M.treebuf, 'h', function()
        local item = row()
        if item and M.expanded[item.path] then M.expanded[item.path] = nil
        elseif item then M.expanded[vim.fs.dirname(item.path)] = nil end
        repaint()
      end)
      map(M.treebuf, '/', M.pick)
      map(M.treebuf, 'g', 'gg')
      map(M.treebuf, 'G', 'G')
      map(M.treebuf, 'q', function() editor() end)
      map(M.treebuf, '<Esc>', function() editor() end)
      map(M.treebuf, '<BS>', function() M.tree_root = vim.fs.dirname(M.tree_root or root); repaint() end)
      map(M.treebuf, '~', function() M.tree_root = root; repaint() end)
      map(M.treebuf, '.', function() M.tree_root = folder(); M.expanded[M.tree_root] = true; repaint() end)
      map(M.treebuf, 'H', function() M.hidden = not M.hidden; repaint() end)
      map(M.treebuf, 'I', function() M.show_ignored = not M.show_ignored; repaint() end)
      map(M.treebuf, 'Z', function() M.expanded = { [M.tree_root or root] = true }; repaint() end)
      map(M.treebuf, 'u', git_status)
      map(M.treebuf, '<Tab>', function()
        if row() then M.selected[row().path] = not M.selected[row().path] or nil; repaint() end
      end)
      map(M.treebuf, 'a', function()
        local parent = folder()
        vim.ui.input({ prompt = 'New file or folder (end with /): ' }, function(name)
          if not name or name == '' then return end
          local path = vim.fs.normalize(parent .. '/' .. name)
          operation({ path }, function()
            if uv.fs_stat(path) then notify('Already exists'); return end
            if name:sub(-1) == '/' then vim.fn.mkdir(path, 'p')
            else vim.fn.mkdir(vim.fs.dirname(path), 'p'); vim.fn.writefile({}, path); M.open(path) end
            repaint()
          end)
        end)
      end)
      map(M.treebuf, 'r', function()
        local item = row()
        if not item then return end
        vim.ui.input({ prompt = 'Rename to: ', default = relative(item.path) }, function(name)
          if name and name ~= '' then rename(item.path, vim.fs.normalize(root .. '/' .. name)) end
        end)
      end)
      map(M.treebuf, 'm', function()
        local target, paths = folder(), chosen()
        vim.ui.select({ 'Cancel', 'Move selected files' }, { prompt = 'Move into ' .. relative(target) .. '?' }, function(choice)
          if choice ~= 'Move selected files' then return end
          for _, source in ipairs(paths) do rename(source, target .. '/' .. vim.fs.basename(source)) end
          M.selected = {}
        end)
      end)
      map(M.treebuf, 'c', function()
        local target, paths = folder(), chosen()
        vim.ui.select({ 'Cancel', 'Copy selected files' }, { prompt = 'Copy into ' .. relative(target) .. '?' }, function(choice)
          if choice == 'Copy selected files' then copy_into(paths, target) end
        end)
      end)
      map(M.treebuf, 'd', function()
        local paths = chosen()
        vim.ui.select({ 'Cancel', 'Delete selected files' }, { prompt = 'Delete ' .. #paths .. ' selected paths?' }, function(choice)
          if choice ~= 'Delete selected files' then return end
          operation(paths, function()
            for _, path in ipairs(paths) do
              for _, buf in ipairs(api.nvim_list_bufs()) do
                local name = api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) or ''
                if name == path or name:sub(1, #path + 1) == path .. '/' then
                  if vim.bo[buf].modified then notify('Save unsaved buffer first: ' .. name); return end
                end
              end
            end
            for _, path in ipairs(paths) do
              if vim.fn.delete(path, 'rf') ~= 0 then notify('Could not delete ' .. path); return end
              for _, buf in ipairs(api.nvim_list_bufs()) do
                local name = api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) or ''
                if name == path or name:sub(1, #path + 1) == path .. '/' then api.nvim_buf_delete(buf, {}) end
              end
            end
            M.selected = {}
            git_status()
            repaint()
          end)
        end)
      end)
      map(M.treebuf, 'y', function() M.copied = chosen(); vim.fn.setreg('"', table.concat(M.copied, '\n')); notify('Paths yanked') end)
      map(M.treebuf, 'p', function() copy_into(M.copied or {}, folder()) end)
      map(M.treebuf, '?', function()
        notify('Enter/l open · h close · / find · a new · r rename · Tab select · m move · c copy · d delete · y/p yank/paste · H hidden · I ignored · Z collapse · q editor')
      end)
    end
    if reveal then
      local path = active_file()
      if path then
        local parent = vim.fs.dirname(path)
        while parent and parent:sub(1, #root) == root do M.expanded[parent] = true; parent = vim.fs.dirname(parent) end
        repaint()
        for i, item in ipairs(M.rows) do if item.path == path then api.nvim_win_set_cursor(M.treewin, { i, 0 }); break end end
      end
      api.nvim_set_current_win(M.treewin)
    end
    repaint()
    git_status()
  end
  function M.toggle_tree()
    if valid(M.treewin) then api.nvim_win_close(M.treewin, true); M.treewin = nil; editor()
    else M.files(true) end
  end

  function M.comment(first, last)
    editor()
    local path = api.nvim_buf_get_name(0)
    if path == '' or vim.bo.buftype ~= '' then notify('Open a file before commenting'); return end
    vim.ui.input({ prompt = 'Comment on ' .. relative(path) .. ':' .. first .. ': ' }, function(text)
      if not text or text == '' then return end
      M.notes[#M.notes + 1] = { path = path, line = first, last = last, text = text }
      save_notes()
      refresh_marks()
    end)
  end
  located_notes = function()
    local notes = vim.deepcopy(M.notes)
    for index, note in ipairs(notes) do
      local mark = M.marks[index]
      if mark and api.nvim_buf_is_valid(mark.buf) then
        local position = api.nvim_buf_get_extmark_by_id(mark.buf, namespace, mark.id, { details = true })
        if #position > 0 then note.line = position[1] + 1; note.last = position[3].end_row or note.line end
      end
    end
    return notes
  end
  function M.review()
    local notes = located_notes()
    local items = {}
    for i, note in ipairs(notes) do
      items[i] = { label = relative(note.path) .. ':' .. note.line .. '  ' .. note.text, path = note.path, index = i }
    end
    M.picker(items, 'Review comments', function(item)
      vim.ui.select({ 'Open file', 'Delete comment', 'Cancel' }, { prompt = item.label }, function(choice)
        if choice == 'Open file' then M.open({ path = item.path, line = notes[item.index].line })
        elseif choice == 'Delete comment' then
          M.notes = located_notes(); table.remove(M.notes, item.index); M.marks = {}
          for _, buf in ipairs(api.nvim_list_bufs()) do api.nvim_buf_clear_namespace(buf, namespace, 0, -1) end
          save_notes(); refresh_marks()
        end
      end)
    end)
  end
  function M.send(submit)
    if #M.notes == 0 then notify('No comments to send'); return end
    local text = { 'Review comments (' .. root .. '):' }
    for _, note in ipairs(located_notes()) do
      text[#text + 1] = relative(note.path) .. ':' .. note.line .. (note.last > note.line and ('-' .. note.last) or '') .. '\n' .. note.text
    end
    data('agents', {}, function(agents)
      if #agents == 0 then notify('No supported agent is running in this Rex tab'); return end
      local function selected(agent)
        if not agent then return end
        local function send()
          data('send', vim.list_extend({ agent.block }, submit and { '--submit' } or {}), function()
            notify(submit and 'Comments sent' or 'Comments pasted into agent input; press Enter there to submit')
          end, table.concat(text, '\n\n'))
        end
        vim.ui.select({ 'Cancel', submit and 'Paste and submit' or 'Paste comments' },
          { prompt = 'Send ' .. #M.notes .. ' comments to ' .. agent.name .. '?' },
          function(choice) if choice and choice ~= 'Cancel' then send() end end)
      end
      if #agents == 1 then selected(agents[1])
      else vim.ui.select(agents, { prompt = 'Choose agent', format_item = function(a) return a.name .. ' · ' .. a.label end }, selected) end
    end)
  end
  function M.preview(file)
    local path = file and file.path or active_file()
    if not path or path == '' then notify('Open a file to preview'); return end
    local function present(result)
      editor()
      local original = M.preview_source or api.nvim_get_current_buf()
      if M.preview_restore then M.preview_restore() end
      local saved_options = {}
      for _, key in ipairs({ 'conceallevel', 'number', 'relativenumber', 'signcolumn', 'foldcolumn', 'wrap' }) do saved_options[key] = vim.wo[M.editwin][key] end
      vim.wo[M.editwin].number, vim.wo[M.editwin].relativenumber = false, false
      vim.wo[M.editwin].signcolumn, vim.wo[M.editwin].foldcolumn = 'no', '0'
      M.preview_source = original
      local buf = scratch('preview-' .. tostring(uv.hrtime()), result.filetype)
      api.nvim_win_set_buf(M.editwin, buf)
      if result.kind == 'terminal' then api.nvim_chan_send(api.nvim_open_term(buf, {}), result.text)
      else
        lines(buf, vim.split(result.text, '\n', { plain = true }))
        vim.wo[M.editwin].conceallevel = 2
        if result.filetype == 'markdown' then pcall(function() require('render-markdown').enable() end) end
      end
      local function source()
        if api.nvim_buf_is_valid(original) then api.nvim_win_set_buf(M.editwin, original) end
        M.preview_source = nil
        for key, value in pairs(saved_options) do vim.wo[M.editwin][key] = value end
        M.preview_restore = nil
      end
      M.preview_restore = source
      map(buf, 'q', source)
      map(buf, '<Esc>', source)
      if result.hint then notify(result.hint) end
    end
    local original = M.preview_source or (valid(M.editwin) and api.nvim_win_get_buf(M.editwin))
    if original and vim.bo[original].modified and api.nvim_buf_get_name(original) == path then
      present({ kind = 'source', text = table.concat(api.nvim_buf_get_lines(original, 0, -1, false), '\n'), filetype = vim.bo[original].filetype })
    else
      data('preview', { path, tostring(api.nvim_win_get_width(M.editwin) - 2), tostring(api.nvim_win_get_height(M.editwin) - 2) }, present)
    end
  end
  function M.dispatch(action, encoded)
    local args = vim.json.decode(encoded)
    if action == 'dirty' then
      for _, buf in ipairs(api.nvim_list_bufs()) do if vim.bo[buf].modified and vim.bo[buf].buftype == '' then return true end end
      return false
    end
    vim.schedule(function()
      if action == 'open' then M.open(args.file)
      elseif action == 'files' then M.files(true)
      elseif action == 'pick' then M.pick()
      elseif action == 'recent' then M.recent()
      elseif action == 'preview' then M.preview(args.file)
      elseif action == 'notes' then M.review() end
    end)
    return true
  end

  local commands = {
    Files = function() M.files(true) end, Pick = M.pick, Recent = M.recent,
    Preview = function() M.preview() end, Notes = M.review,
  }
  for suffix, callback in pairs(commands) do if vim.fn.exists(':Neorex' .. suffix) == 0 then api.nvim_create_user_command('Neorex' .. suffix, callback, {}) end end
  api.nvim_create_user_command('NeorexComment', function(opts) M.comment(opts.line1, opts.line2) end, { range = true })
  api.nvim_create_user_command('NeorexSend', function(opts) M.send(opts.bang) end, { bang = true })
  local bindings = {
    { '<leader>ne', M.toggle_tree }, { '<leader>nf', M.pick }, { '<leader>no', M.recent },
    { '<leader>np', function() M.preview() end }, { '<leader>al', M.review },
    { '<leader>as', function() M.send(false) end }, { '<leader>aS', function() M.send(true) end },
  }
  for _, binding in ipairs(bindings) do
    if vim.fn.maparg(binding[1], 'n') == '' then vim.keymap.set('n', binding[1], binding[2], { silent = true, desc = tool .. ' workspace' }) end
  end
  for _, mode in ipairs({ 'n', 'x' }) do
    if vim.fn.maparg('<leader>ac', mode) == '' then
      vim.keymap.set(mode, '<leader>ac', ':NeorexComment<CR>', { silent = true, desc = 'Comment for agent' })
    end
  end
  api.nvim_create_autocmd('BufEnter', { callback = function()
    local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    if not M.creating_tree and win ~= M.treewin and api.nvim_win_get_config(win).relative == '' and vim.bo[buf].buftype == '' then M.editwin = win; refresh_marks() end
  end })
  api.nvim_create_autocmd('BufWritePost', { callback = function(args)
    M.notes = located_notes(); save_notes(); git_status(); repaint()
    if M.preview_source == args.buf then M.preview() end
  end })
  local timer = uv.new_timer()
  local checking = false
  local entered, started = #api.nvim_list_uis() > 0, uv.hrtime()
  local function unattended()
    if M.dispatch('dirty', '{}') then
      M.orphaned = true
      if #api.nvim_list_uis() > 0 then notify('Parent Rex tab closed; unsaved work is kept.') end
    else vim.cmd('qa') end
  end
  if state.mode == 'native' then
    api.nvim_create_autocmd('UIEnter', { callback = function()
      if M.orphaned then
        M.recovered = true
        if #api.nvim_list_uis() > 1 and state.block then
          T.rex(state, 'block.close', { block_id = state.block }, function() end)
        end
        T.rex(state, 'session.view', {}, function(view)
          for _, window in ipairs(view and view.windows or {}) do
            if window.window_id == state.window then M.recovered = false; return end
          end
        end)
      end
      entered, M.orphaned = true, false
      state.block = read_json(state_path, {}).block or state.block
      if state.initial then
        local initial = state.initial; state.initial = nil
        M.dispatch(initial.action, vim.json.encode(initial.args))
      end
    end })
    api.nvim_create_autocmd('UILeave', { callback = function()
      vim.defer_fn(function() if #api.nvim_list_uis() == 0 then unattended() end end, 100)
    end })
    require('neorex.theme').setup(state.apply_rex_theme)
  end
  timer:start(2000, 2000, vim.schedule_wrap(function()
    git_status()
    if state.mode == 'native' and not entered and uv.hrtime() - started > 30e9 then unattended(); return end
    if M.orphaned then
      if not M.dispatch('dirty', '{}') then vim.cmd('qa') end
      return
    end
    if M.recovered then return end
    if checking then return end
    checking = true
    T.rex(state, 'session.view', {}, function(view)
      checking = false
      if not view then return end
      for _, window in ipairs(view.windows or {}) do if window.window_id == state.window then return end end
      unattended()
    end)
  end))
  api.nvim_create_autocmd('VimLeavePre', { once = true, callback = function()
    timer:stop(); timer:close(); save_notes()
    if state.mode == 'native' then vim.fn.delete(state_path .. '.ready') end
  end })
  editor()
  if state.mode == 'native' then vim.fn.writefile({ tostring(uv.os_getpid()) }, state_path .. '.ready') end
  return M
end
return Plugin
