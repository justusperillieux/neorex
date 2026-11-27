-- Query the attached Rex terminal's palette through standard OSC sequences.
local Theme = {}
function Theme.parse(sequence)
  local index, value = sequence:match('^\27%]4;(%d+);rgb:([%x]+/[%x]+/[%x]+)')
  local key = index and tonumber(index)
  if not value then
    local code
    code, value = sequence:match('^\27%](1[012]);rgb:([%x]+/[%x]+/[%x]+)')
    key = ({ ['10'] = 'foreground', ['11'] = 'background', ['12'] = 'cursor' })[code]
  end
  if key == nil or not value then return end
  local channels = {}
  for part in value:gmatch('[^/]+') do
    channels[#channels + 1] = math.floor(tonumber(part, 16) / (16 ^ #part - 1) * 255 + 0.5)
  end
  return key, string.format('#%02x%02x%02x', unpack(channels))
end
local function channel(color, offset) return tonumber(color:sub(offset, offset + 1), 16) end
local function blend(a, b, amount)
  local values = {}
  for _, offset in ipairs({ 2, 4, 6 }) do values[#values + 1] = math.floor(channel(a, offset) * amount + channel(b, offset) * (1 - amount) + 0.5) end
  return string.format('#%02x%02x%02x', unpack(values))
end
function Theme.apply(colors)
  local fg, bg = colors.foreground, colors.background
  if not fg or not bg then return false end
  local red, green, yellow = colors[1] or fg, colors[2] or fg, colors[3] or fg
  local blue, purple, cyan = colors[4] or fg, colors[5] or fg, colors[6] or fg
  local muted = colors[8] or blend(fg, bg, 0.45)
  local surface, selection = blend(fg, bg, 0.06), blend(blue, bg, 0.28)
  local luminance = channel(bg, 2) * 0.2126 + channel(bg, 4) * 0.7152 + channel(bg, 6) * 0.0722
  vim.o.background = luminance > 128 and 'light' or 'dark'
  vim.o.termguicolors = true
  local groups = {
    Normal = { fg = fg, bg = bg }, NormalNC = { fg = fg, bg = bg }, NormalFloat = { fg = fg, bg = surface },
    FloatBorder = { fg = muted, bg = surface }, FloatTitle = { fg = blue, bg = surface, bold = true },
    SignColumn = { fg = muted, bg = bg }, LineNr = { fg = muted, bg = bg },
    CursorLine = { bg = surface }, CursorLineNr = { fg = yellow, bold = true },
    Cursor = { fg = bg, bg = colors.cursor or fg }, Visual = { bg = selection },
    Pmenu = { fg = fg, bg = surface }, PmenuSel = { fg = fg, bg = selection, bold = true },
    StatusLine = { fg = fg, bg = selection }, StatusLineNC = { fg = muted, bg = surface },
    WinSeparator = { fg = muted, bg = bg }, NonText = { fg = muted }, Comment = { fg = muted, italic = true },
    String = { fg = green }, Character = { fg = green }, Number = { fg = yellow }, Boolean = { fg = yellow },
    Constant = { fg = yellow }, Identifier = { fg = fg }, Function = { fg = blue },
    Statement = { fg = purple }, Keyword = { fg = purple }, Operator = { fg = cyan },
    Type = { fg = cyan }, Special = { fg = cyan }, PreProc = { fg = purple }, Delimiter = { fg = fg },
    Directory = { fg = blue }, Title = { fg = blue, bold = true }, Search = { fg = bg, bg = yellow },
    IncSearch = { fg = bg, bg = colors[11] or yellow }, MatchParen = { bg = selection, bold = true },
    DiagnosticError = { fg = red }, DiagnosticWarn = { fg = yellow },
    DiagnosticInfo = { fg = blue }, DiagnosticHint = { fg = cyan },
    DiffAdd = { bg = blend(green, bg, 0.15) }, DiffDelete = { bg = blend(red, bg, 0.15) },
    DiffChange = { bg = blend(blue, bg, 0.15) }, DiffText = { bg = blend(blue, bg, 0.28) },
  }
  for name, highlight in pairs(groups) do vim.api.nvim_set_hl(0, name, highlight) end
  for capture, group in pairs({ comment = 'Comment', string = 'String', number = 'Number', boolean = 'Boolean',
    keyword = 'Keyword', operator = 'Operator', ['function'] = 'Function', type = 'Type', constant = 'Constant', variable = 'Identifier' }) do
    vim.api.nvim_set_hl(0, '@' .. capture, { link = group })
  end
  for index = 0, 15 do if colors[index] then vim.g['terminal_color_' .. index] = colors[index] end end
  vim.g.colors_name = 'neorex-rex'
  return true
end
function Theme.setup(enabled)
  if not enabled then return end
  local colors, pending = {}, false
  local group = vim.api.nvim_create_augroup('NeorexTheme', { clear = true })
  local function query()
    if #vim.api.nvim_list_uis() == 0 then return end
    local requests = { '\27]10;?\27\\', '\27]11;?\27\\', '\27]12;?\27\\' }
    for index = 0, 15 do requests[#requests + 1] = '\27]4;' .. index .. ';?\27\\' end
    vim.api.nvim_ui_send(table.concat(requests))
  end
  vim.api.nvim_create_autocmd('TermResponse', { group = group, callback = function(event)
    local key, color = Theme.parse(event.data and event.data.sequence or vim.v.termresponse)
    if key == nil then return end
    colors[key] = color
    if pending then return end
    pending = true
    vim.defer_fn(function() pending = false; Theme.apply(colors) end, 30)
  end })
  vim.api.nvim_create_autocmd({ 'UIEnter', 'FocusGained' }, { group = group, callback = query })
  vim.api.nvim_create_user_command('NeorexTheme', query, { desc = 'Refresh colors from the Rex terminal' })
end
return Theme
