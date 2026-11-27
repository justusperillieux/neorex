-- Check registration in Rex itself without opening panes or editing user config.
local root = assert(os.getenv('GITHUB_WORKSPACE') or os.getenv('PWD'))
dofile(root .. '/neorex.lua').setup {}
