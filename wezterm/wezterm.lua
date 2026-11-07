local wezterm = require('wezterm')
local act = wezterm.action
local config = wezterm.config_builder()

-- Git worktree management lives in its own module. See petrees.lua for the
-- CMD+SHIFT+O / N / X bindings and the layout they assume.
local petrees = require('petrees')

-- DO NOT add `unix_domains` / `default_domain = 'unix'` here. Tried Aug 2026 and
-- rejected: it made windows glitch on resize with text garbled and clipped, left
-- junk windows behind on every launch, and broke CMD+Q. Panes stay owned by the
-- GUI. Quitting kills them, and that is fine.

-- Advertise WezTerm's own terminfo instead of the default xterm-256color.
--
-- Under xterm-256color, Neovim assumes xterm's left/right margin support
-- (DECLRMM / DECSLRM, mode 69) because the xterm terminfo entry implies it and
-- WezTerm answers the DECRQM probe for mode 69 affirmatively. Neovim then
-- scrolls a single vertical split by setting column margins around it, and
-- this build of WezTerm mishandles that: cells in the narrower window are
-- dropped or left stale, so a diff split renders half a line of the current
-- buffer with older text bleeding in after it. Measured on a scripted
-- diffview-shaped session: 21 of 22 rows wrong with xterm-256color, 0 with
-- the wezterm entry, which advertises no margin capabilities at all. The
-- entry is also a better description of this terminal than xterm's, carrying
-- true color, colored undercurl, italics, strikethrough and OSC 52.
--
-- This requires the terminfo to be installed, which is a per-machine step:
--
--   curl -fsSLO https://raw.githubusercontent.com/wez/wezterm/main/termwiz/data/wezterm.terminfo
--   tic -x -o ~/.terminfo wezterm.terminfo
--
-- If it is missing, Neovim still avoids the margin path, but other terminal
-- programs will complain about an unknown terminal type. The same applies over
-- ssh to a host without the entry, where `TERM=xterm-256color ssh host` is the
-- escape hatch.
config.term = 'wezterm'

-- Appearance
-- Matches `colorscheme tokyonight` in Neovim, which defaults to the moon style.
config.color_scheme = 'tokyonight_moon'
config.font_size = 14.0
-- No ligatures. Code should render as the bytes it is, so `!=` stays two
-- characters instead of being drawn as a single (and misleading) glyph.
config.harfbuzz_features = { 'calt=0', 'clig=0', 'liga=0' }
-- Opaque. Was 0.92 opacity with 30px blur, which composites every frame against
-- the desktop and is a plausible source of resize repaint artifacts on macOS.
--   config.window_background_opacity = 0.92
--   config.macos_window_background_blur = 30
config.window_decorations = 'RESIZE'
config.hide_tab_bar_if_only_one_tab = false
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = false
config.scrollback_lines = 50000

-- Show the active workspace on the right of the tab bar.
wezterm.on('update-right-status', function(window)
    window:set_right_status(' ' .. window:active_workspace() .. ' ')
end)

--------------------------------------------------------------------------------
-- Workspaces
--
-- A workspace is a named group of windows and tabs; WezTerm shows one group at a
-- time. petrees names the groups it creates after their worktree directory, but
-- a group need not be a worktree at all - hence these two keys, which stay
-- general on purpose and live here rather than in petrees.
--
-- Callbacks are built once here at config-evaluation time, not inside another
-- callback. See the note at the top of the actions section in petrees.lua.
--------------------------------------------------------------------------------

local function tilde(path)
    local home = os.getenv('HOME') or ''
    if home ~= '' and path:sub(1, #home) == home then
        return '~' .. path:sub(#home + 1)
    end
    return path
end

local switch_workspace = wezterm.action_callback(function(win, pane, id)
    if id then
        win:perform_action(act.SwitchToWorkspace({ name = id }), pane)
    end
end)

-- Lists every existing workspace, annotated with what petrees knows about it.
-- Labels are matched by workspace name, which is fixed at creation, rather than
-- by a pane's cwd, which drifts the moment you cd.
local pick_workspace = wezterm.action_callback(function(win, pane)
    local index = petrees.worktree_index()

    local rows = {}
    for _, name in ipairs(wezterm.mux.get_workspace_names()) do
        local wt = index[name]
        local tag = ''
        if wt then
            tag = wt.kind == 'linked' and 'worktree' or ('worktree  ' .. wt.kind)
        end
        table.insert(rows, {
            name = name,
            is_worktree = wt ~= nil,
            label = string.format('%-26s %-19s %s', name, tag, wt and tilde(wt.path) or ''),
        })
    end

    -- Worktrees first, then anything else, alphabetical within each group.
    table.sort(rows, function(a, b)
        if a.is_worktree ~= b.is_worktree then
            return a.is_worktree
        end
        return a.name < b.name
    end)

    local choices = {}
    for _, row in ipairs(rows) do
        table.insert(choices, { label = row.label, id = row.name })
    end

    win:perform_action(
        act.InputSelector({
            title = 'Workspaces',
            fuzzy = true,
            fuzzy_description = 'workspace> ',
            choices = choices,
            action = switch_workspace,
        }),
        pane
    )
end)

-- Opens any directory as its own workspace, named after the directory. This is
-- the way in for projects that are not worktrees of the repo petrees manages.
local workspace_from_dir = act.PromptInputLine({
    description = 'Directory to open as a workspace',
    action = wezterm.action_callback(function(win, pane, line)
        if not line or line == '' then
            return
        end
        local path = line:gsub('^~', os.getenv('HOME') or ''):gsub('/+$', '')
        win:perform_action(
            act.SwitchToWorkspace({
                name = path:match('([^/]+)$') or path,
                spawn = { cwd = path },
            }),
            pane
        )
    end),
})

-- Apps that capture the mouse (Claude Code) do their own selection and copy it
-- with OSC 52 on release, so WezTerm has no selection of its own. The default
-- CMD+C copies that empty selection and wipes the clipboard; only copy when
-- WezTerm actually has something selected.
local copy_if_selected = wezterm.action_callback(function(win, pane)
    if win:get_selection_text_for_pane(pane) ~= '' then
        win:perform_action(act.CopyTo('Clipboard'), pane)
    end
end)

config.keys = petrees.extend_keys({
    { key = 'c', mods = 'CMD', action = copy_if_selected },

    -- Workspaces
    { key = 'p', mods = 'CMD|SHIFT', action = pick_workspace },
    { key = 'd', mods = 'CMD|SHIFT', action = workspace_from_dir },

    -- CMD+SHIFT+P lists what is running; petrees' CMD+SHIFT+O lists every
    -- worktree whether it is running or not. They overlap because
    -- SwitchToWorkspace reuses an existing workspace when the name matches, so
    -- picking an already-open worktree lands back in its tabs and panes either
    -- way. WezTerm's built-in launcher is not used - it renders bare names with
    -- no room for the worktree / root / external labels.

    -- Splits, matching the | and - mnemonic from tmux.
    -- Bound to | rather than \ because 1Password claims CMD+\ system-wide.
    {
        key = '|',
        mods = 'CMD|SHIFT',
        action = act.SplitHorizontal({ domain = 'CurrentPaneDomain' }),
    },
    {
        key = '-',
        mods = 'CMD',
        action = act.SplitVertical({ domain = 'CurrentPaneDomain' }),
    },

    -- Pane navigation
    { key = 'h', mods = 'CMD|SHIFT', action = act.ActivatePaneDirection('Left') },
    { key = 'l', mods = 'CMD|SHIFT', action = act.ActivatePaneDirection('Right') },
    { key = 'k', mods = 'CMD|SHIFT', action = act.ActivatePaneDirection('Up') },
    { key = 'j', mods = 'CMD|SHIFT', action = act.ActivatePaneDirection('Down') },
    { key = 'z', mods = 'CMD|SHIFT', action = act.TogglePaneZoomState },
})

return config
