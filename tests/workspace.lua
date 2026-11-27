local api = vim.api
local root, tool = vim.env.WORKSPACE_TEST_ROOT, vim.env.WORKSPACE_TEST_TOOL
vim.g.mapleader = ' '
vim.keymap.set('n', '<leader>ne', ':echo "personal binding"<CR>')
local personal = vim.fn.maparg('<leader>ne', 'n')
vim.opt.rtp:prepend(vim.env.WORKSPACE_TEST_RUNTIME)
require('neorex.workspace').setup{ state = vim.env[tool:upper() .. '_WORKSPACE_STATE'] }
local M = _G[tool .. '_workspace']
assert(M.treewin == nil and #api.nvim_list_wins() == 1, 'the editor must start without a tree side panel')
assert(vim.fn.maparg('<leader>ne', 'n') == personal, 'personal keys must not change')
local file = root .. "/a file'$(ignored).md"
M.open({ path = file, line = 2, column = 3 })
assert(api.nvim_buf_get_name(0) == file)
assert(api.nvim_win_get_cursor(0)[1] == 2)
api.nvim_buf_set_lines(0, 1, 2, false, { 'unsaved change' })
assert(M.dispatch('dirty', '{}') == true)
M.toggle_tree()
assert(M.treewin and api.nvim_win_is_valid(M.treewin), 'the tree must still open on request')
assert(M.editwin ~= M.treewin, 'creating the tree must not replace the editor window')
M.toggle_tree()
assert(not (M.treewin and api.nvim_win_is_valid(M.treewin)))
M.toggle_tree()
assert(M.editwin ~= M.treewin)
api.nvim_set_current_win(M.editwin)
assert(api.nvim_buf_get_lines(0, 1, 2, false)[1] == 'unsaved change')

-- Comments remain attached to their lines as the buffer changes.
vim.ui.input = function(_, callback) callback('Please keep this heading') end
M.comment(1, 1)
assert(#M.notes == 1 and M.notes[1].path == file)
api.nvim_buf_set_lines(0, 0, 0, false, { 'new first line' })

-- Preview unsaved contents, then return to exactly the same buffer.
local original = api.nvim_get_current_buf()
M.preview()
assert(M.preview_source == original)
assert(table.concat(api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('unsaved change', 1, true))
local mappings = api.nvim_buf_get_keymap(0, 'n')
for _, mapping in ipairs(mappings) do if mapping.lhs == 'q' then mapping.callback() end end
assert(api.nvim_get_current_buf() == original and vim.bo.modified)

-- Renaming modified buffers asks before saving; cancel must leave data untouched.
M.files(true)
local selected
for index, row in ipairs(M.rows) do if row.path == file then selected = index end end
assert(selected, 'file must appear in tree even with spaces and quotes')
api.nvim_win_set_cursor(M.treewin, { selected, 0 })
vim.ui.input = function(_, callback) callback('renamed.md') end
vim.ui.select = function(_, _, callback) callback('Cancel') end
for _, mapping in ipairs(api.nvim_buf_get_keymap(M.treebuf, 'n')) do
  if mapping.lhs == 'r' then mapping.callback() end
end
assert(api.nvim_buf_get_name(original) == file and vim.bo[original].modified)
assert(vim.fn.readfile(file)[2] == 'original', 'cancel must not write the buffer')
vim.ui.select = function(_, _, callback) callback('Save and rename') end
for _, mapping in ipairs(api.nvim_buf_get_keymap(M.treebuf, 'n')) do
  if mapping.lhs == 'r' then mapping.callback() end
end
assert(api.nvim_buf_get_name(original) == root .. '/renamed.md')
assert(not vim.bo[original].modified, 'saving must happen only after explicit confirmation')
assert(M.notes[1].path == root .. '/renamed.md')
assert(vim.fn.readfile(root .. '/renamed.md')[3] == 'unsaved change')

-- Rename back so the runner can verify the original file contents.
M.files(true)
for index, row in ipairs(M.rows) do
  if row.path == root .. '/renamed.md' then api.nvim_win_set_cursor(M.treewin, { index, 0 }) end
end
vim.ui.input = function(_, callback) callback("a file'$(ignored).md") end
for _, mapping in ipairs(api.nvim_buf_get_keymap(M.treebuf, 'n')) do
  if mapping.lhs == 'r' then mapping.callback() end
end
assert(api.nvim_buf_get_name(original) == file)
api.nvim_buf_set_lines(original, 0, -1, false, { '# Heading', 'original' })
api.nvim_buf_call(original, function() vim.cmd('write') end) -- an ordinary save must work after renaming
assert(not vim.bo[original].modified)
vim.cmd('qa!')
