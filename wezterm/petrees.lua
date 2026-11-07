-- petrees: git worktree management for WezTerm.
--
-- Everything in this file is about git worktrees and nothing else. The main
-- config requires it and splices `M.keys` into its own key table:
--
--     local petrees = require('petrees')
--     config.keys = petrees.extend_keys({ ... your other keys ... })
--
-- Layout: worktrees live in <parent-of-repo>/<repo>-worktrees/<name>, e.g.
-- ~/dev/evergreen-worktrees/pc-1408.
--
-- Keys:
--   CMD+SHIFT+O   switch to a worktree's workspace
--   CMD+SHIFT+N   create a worktree + branch, gt track it, open its workspace
--   CMD+SHIFT+X   delete a worktree, its branch, and its workspace panes
--   CMD+SHIFT+R   set (or change) the repo petrees manages
--
-- The repo root must be stated explicitly. It is resolved on first use, in this
-- order:
--   1. ~/.config/wezterm/petrees.json, written by the setup prompt
--   2. $PETREES_REPO_ROOT
-- Nothing is guessed. If neither is set, the first keypress asks for the path
-- and saves it to petrees.json, which lives beside this file. Resolution cannot
-- happen at load time, because the config is evaluated before any window exists
-- to show a prompt in.

local wezterm = require('wezterm')
local act = wezterm.action

local M = {}

-- Fallback trunk. Both scripts derive the real trunk from origin/HEAD and only
-- fall back to this when the remote HEAD ref is missing, so a repo on `main`
-- needs no configuration here.
M.trunk = 'master'

-- Resolved absolute path of the managed repo, or nil until it is set.
M.repo_root = nil

--------------------------------------------------------------------------------
-- Persisted state
--------------------------------------------------------------------------------

local STATE_PATH = (os.getenv('HOME') or '') .. '/.config/wezterm/petrees.json'

local function read_state()
    local f = io.open(STATE_PATH, 'r')
    if not f then
        return {}
    end
    local body = f:read('*a')
    f:close()
    local ok, parsed = pcall(wezterm.json_parse, body)
    if ok and type(parsed) == 'table' then
        return parsed
    end
    return {}
end

local function write_state(state)
    local f = io.open(STATE_PATH, 'w')
    if not f then
        wezterm.log_error('petrees: cannot write ' .. STATE_PATH)
        return false
    end
    f:write(wezterm.json_encode(state))
    f:close()
    return true
end

--------------------------------------------------------------------------------
-- Repo resolution
--------------------------------------------------------------------------------

local function expand_home(path)
    local home = os.getenv('HOME') or ''
    return (path:gsub('^~', home))
end

-- True only for a real git repo, so a stray directory with the right name does
-- not get picked up.
local function is_git_repo(path)
    if not path or path == '' then
        return false
    end
    return wezterm.run_child_process({ 'git', '-C', path, 'rev-parse', '--git-dir' })
end

-- Explicit configuration only. Guessing a repo would silently manage the wrong
-- checkout, and CMD+SHIFT+X deletes branches, so a missing setting has to fail
-- loudly into the setup prompt instead.
local function resolve_repo_root()
    local stored = read_state().repo_root
    if stored and is_git_repo(stored) then
        return stored
    end

    local env = os.getenv('PETREES_REPO_ROOT')
    if env and env ~= '' then
        env = expand_home(env)
        if is_git_repo(env) then
            return env
        end
    end

    return nil
end

-- Resolution is deliberately NOT done at load time. It shells out to git, and
-- run_child_process yields internally, which is illegal inside `require` (a C
-- call) and raises "attempt to yield across a C-call boundary". So resolve on
-- first use instead, from inside a keypress callback.
local resolved = false

local function ensure_repo_root()
    if not resolved then
        resolved = true
        M.repo_root = resolve_repo_root()
    end
    return M.repo_root
end

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

-- Every worktree of the managed repo, root first and the rest alphabetical.
-- Asks git fresh on every call, so new worktrees show up without a config
-- reload.
-- One record per worktree: { path, name, branch, kind }, where kind is
--   'root'     the main worktree, the one holding .git
--   'linked'   a normal worktree under <parent>/<repo>-worktrees/
--   'external' a worktree living somewhere else entirely, e.g. the one
--              Superset keeps under ~/.superset/worktrees/
local function worktrees()
    local list = {}
    if not M.repo_root then
        return list
    end

    local ok, stdout = wezterm.run_child_process({
        'git', '-C', M.repo_root, 'worktree', 'list', '--porcelain',
    })
    if not ok then
        return list
    end

    local parent = M.repo_root:match('^(.*)/[^/]+$') or ''
    local base = M.repo_root:match('([^/]+)$') or ''
    local convention = parent .. '/' .. base .. '-worktrees/'

    local path, branch
    for line in stdout:gmatch('[^\n]+') do
        local p = line:match('^worktree (.+)$')
        local b = line:match('^branch refs/heads/(.+)$')
        if p then
            path = p
            branch = nil
        elseif b then
            branch = b
        end
        -- Porcelain separates records with a blank line, which gmatch skips, so
        -- flush on the line that ends a record instead.
        if path and (b or line == 'detached') then
            local kind = 'linked'
            if path == M.repo_root then
                kind = 'root'
            elseif path:sub(1, #convention) ~= convention then
                kind = 'external'
            end
            table.insert(list, {
                path = path,
                name = path:match('([^/]+)$'),
                branch = branch or 'detached',
                kind = kind,
            })
            path, branch = nil, nil
        end
    end

    -- Root first, then everything else alphabetically. The main checkout is the
    -- one you come back to between branches, so it gets a fixed spot at the top
    -- rather than sliding around as worktrees are created and deleted.
    table.sort(list, function(a, b)
        if (a.kind == 'root') ~= (b.kind == 'root') then
            return a.kind == 'root'
        end
        return a.name < b.name
    end)
    return list
end

local function worktree_choices()
    local choices = {}
    for _, wt in ipairs(worktrees()) do
        -- The root's directory name is just the repo name, which does not say
        -- what it is. Tag it, and pad the tagged name so the branch column stays
        -- lined up with every other row.
        local name = wt.kind == 'root' and (wt.name .. ' (root)') or wt.name
        table.insert(choices, {
            label = string.format('%-32s %s', name, wt.branch),
            id = wt.path,
        })
    end
    return choices
end

-- Workspace name -> worktree record, for callers that want to label a list of
-- workspaces. petrees names each workspace after its worktree directory, so the
-- name is the join key. Deliberately not keyed on a pane's cwd: that drifts as
-- soon as you cd, while the workspace name is fixed at creation.
--
-- Shells out to git, so call it from inside a keypress callback, never at load
-- time. See the note on ensure_repo_root.
function M.worktree_index()
    ensure_repo_root()
    local index = {}
    for _, wt in ipairs(worktrees()) do
        index[wt.name] = wt
    end
    return index
end

--------------------------------------------------------------------------------
-- Shell scripts
--
-- Create and delete run as real shell scripts in a visible pane, rather than
-- through run_child_process plus a toast. git output and errors land on screen,
-- so a failure is never silent.
--------------------------------------------------------------------------------

-- Quote a string for safe interpolation into a shell script.
local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function create_script(repo, name, trunk)
    return table.concat({
        'set -u',
        'REPO=' .. shq(repo),
        'NAME=' .. shq(name),
        'FALLBACK_TRUNK=' .. shq(trunk),
        'DIR="$(dirname "$REPO")/$(basename "$REPO")-worktrees"',
        'TARGET="$DIR/$NAME"',
        'mkdir -p "$DIR"',
        -- A hand-deleted worktree directory leaves a stale admin entry that
        -- makes `worktree add` fail. Prune first.
        'git -C "$REPO" worktree prune',
        -- Whatever the remote calls its default branch. gt wants a plain branch
        -- name, so strip the ref prefix.
        'TRUNK=$(git -C "$REPO" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \\',
        '  | sed "s|refs/remotes/origin/||")',
        'TRUNK=${TRUNK:-$FALLBACK_TRUNK}',
        'START="origin/$TRUNK"',
        'git -C "$REPO" rev-parse --verify --quiet "$START" >/dev/null || START="$TRUNK"',
        'echo "This checks out every tracked file. Do not close this pane until it finishes."',
        'echo',
        'if git -C "$REPO" show-ref --verify --quiet "refs/heads/$NAME"; then',
        '  echo "Branch $NAME already exists, checking it out."',
        '  git -C "$REPO" worktree add "$TARGET" "$NAME"',
        'else',
        '  echo "Creating $TARGET from $START"',
        '  git -C "$REPO" worktree add -b "$NAME" "$TARGET" "$START"',
        'fi',
        'if [ ! -d "$TARGET" ]; then',
        '  echo; echo "Worktree creation FAILED, see the error above."',
        '  cd "$REPO"',
        '  exec "${SHELL:-/bin/zsh}" -l',
        'fi',
        'cd "$TARGET"',
        -- Catch a checkout that died partway rather than leaving it looking ok.
        'MISSING=$(git -C "$TARGET" status --porcelain | grep -c "^ D" || true)',
        'if [ "$MISSING" != "0" ]; then',
        '  echo',
        '  echo "WARNING: $MISSING tracked files are missing - the checkout did not finish."',
        '  echo "Fix with: git -C \\"$TARGET\\" checkout -- ."',
        'fi',
        -- Register with Graphite. --parent is pinned so it never prompts.
        'if command -v gt >/dev/null 2>&1; then',
        '  echo; echo "gt track --parent $TRUNK"',
        '  gt track --parent "$TRUNK" --no-interactive || echo "gt track failed, run it by hand."',
        'fi',
        'exec "${SHELL:-/bin/zsh}" -l',
    }, '\n')
end

local function delete_script(target, trunk)
    return table.concat({
        'set -u',
        'TARGET=' .. shq(target),
        'FALLBACK_TRUNK=' .. shq(trunk),
        'NAME=$(basename "$TARGET")',
        -- Derive the main repo from the worktree itself. `git worktree list`
        -- always prints the main worktree first, so this stays correct even if
        -- petrees is pointed somewhere else.
        'REPO=$(git -C "$TARGET" worktree list --porcelain | awk \'/^worktree /{print $2; exit}\')',
        -- Trunk comes from the remote's default branch, same as create does.
        -- Needs REPO, so it has to follow the line above.
        'TRUNK=$(git -C "$REPO" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \\',
        '  | sed "s|refs/remotes/origin/||")',
        'TRUNK=${TRUNK:-$FALLBACK_TRUNK}',
        'BRANCH=$(git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)',
        'echo "Worktree: $TARGET"',
        'echo "Repo:     $REPO"',
        'echo "Branch:   $BRANCH"',
        'echo',
        -- Classify the dirt. A checkout killed midway shows only deletions;
        -- real work shows modifications, staged changes or new files. Only the
        -- latter should block deletion.
        'DELETED=$(git -C "$TARGET" status --porcelain | grep -c "^ D" || true)',
        'REALWORK=$(git -C "$TARGET" status --porcelain | grep -vc "^ D" || true)',
        'FORCE=""',
        'if [ "$REALWORK" != "0" ]; then',
        '  echo "REFUSING: uncommitted work in this worktree"',
        '  git -C "$TARGET" status --short | grep -v "^ D" | head -20',
        '  echo; echo "Commit or stash it first."',
        '  echo; echo "Press any key to close."; read -k1 -s',
        '  exit 1',
        'fi',
        'if [ "$DELETED" != "0" ]; then',
        '  echo "NOTE: $DELETED tracked files are missing, so this checkout never finished."',
        '  echo "      Treating it as broken rather than as your work."',
        '  FORCE="--force"',
        '  echo',
        'fi',
        'UNPUSHED=$(git -C "$TARGET" log --oneline "$BRANCH" --not --remotes 2>/dev/null | wc -l | tr -d " ")',
        'if [ "$UNPUSHED" != "0" ]; then',
        '  echo "REFUSING: $BRANCH has $UNPUSHED commit(s) on no remote"',
        '  git -C "$TARGET" log --oneline "$BRANCH" --not --remotes',
        '  echo; echo "To delete anyway:"',
        '  echo "  git -C $REPO worktree remove --force $TARGET"',
        '  echo; echo "Press any key to close."; read -k1 -s',
        '  exit 1',
        'fi',
        'printf "Delete worktree %s and branch %s? [y/N] " "$NAME" "$BRANCH"',
        'read -r ans',
        'case "$ans" in',
        '  y|Y) ;;',
        '  *) echo "Cancelled, nothing deleted."; echo; echo "Press any key to close."; read -k1 -s; exit 0 ;;',
        'esac',
        -- Unlinking a large monorepo checkout takes a while and git prints
        -- nothing while it works, so say so or this looks like a hang.
        'echo',
        'FILECOUNT=$(git -C "$TARGET" ls-files 2>/dev/null | wc -l | tr -d " ")',
        'echo "Removing $FILECOUNT files from $TARGET. This can take a minute."',
        'git -C "$REPO" worktree remove $FORCE "$TARGET" || exit 1',
        'echo "Removed worktree $TARGET"',
        -- Drop the branch and its Graphite metadata. gt delete restacks any
        -- children onto the parent; fall back to plain git if gt is absent.
        'if [ "$BRANCH" != "HEAD" ] && [ "$BRANCH" != "$TRUNK" ]; then',
        '  if command -v gt >/dev/null 2>&1; then',
        '    echo "gt delete $BRANCH"',
        '    gt delete "$BRANCH" --force --no-interactive --cwd "$REPO" \\',
        '      || git -C "$REPO" branch -D "$BRANCH" \\',
        '      || echo "Could not delete branch $BRANCH, do it by hand."',
        '  else',
        '    git -C "$REPO" branch -D "$BRANCH" || echo "Could not delete branch $BRANCH."',
        '  fi',
        'fi',
        -- Close the workspace's panes. A wezterm workspace exists only as long
        -- as it holds a pane, so this is what keeps CMD+SHIFT+P from filling up
        -- with workspaces pointing at deleted directories.
        'if [ -n "${WEZTERM_EXECUTABLE_DIR:-}" ] && command -v python3 >/dev/null 2>&1; then',
        '  "$WEZTERM_EXECUTABLE_DIR/wezterm" cli list --format json 2>/dev/null \\',
        '    | WT_NAME="$NAME" python3 -c "',
        'import json, os, sys',
        'name = os.environ[\'WT_NAME\']',
        'me = os.environ.get(\'WEZTERM_PANE\')',
        'for p in json.load(sys.stdin):',
        '    if p[\'workspace\'] == name and str(p[\'pane_id\']) != me:',
        '        print(p[\'pane_id\'])',
        '" \\',
        '    | while read -r wt_pane; do',
        '        "$WEZTERM_EXECUTABLE_DIR/wezterm" cli kill-pane --pane-id "$wt_pane" 2>/dev/null \\',
        '          && echo "Closed pane $wt_pane in workspace $NAME"',
        '      done',
        'fi',
        'echo; echo "Press any key to close."; read -k1 -s',
    }, '\n')
end

--------------------------------------------------------------------------------
-- Actions
--
-- Every action here is built once, while the config is evaluated. wezterm turns
-- each action_callback into a named event at that moment, so a callback minted
-- later (inside another callback, at keypress time) can fail to fire. State
-- that must cross steps goes in a local, not a closure.
--------------------------------------------------------------------------------

local function shell()
    return os.getenv('SHELL') or '/bin/zsh'
end

-- Asks for the repo root, validates it, and remembers it. Reachable on demand
-- via CMD+SHIFT+R, and used automatically when no root is configured yet.
local setup_prompt = act.PromptInputLine({
    description = 'Path to the git repo petrees should manage (petrees_repo_root)',
    action = wezterm.action_callback(function(win, pane, line)
        if not line or line == '' then
            return
        end
        local path = expand_home(line):gsub('/+$', '')
        if not is_git_repo(path) then
            win:toast_notification('petrees', 'Not a git repo:\n' .. path, nil, 6000)
            return
        end

        M.repo_root = path
        local state = read_state()
        state.repo_root = path
        if write_state(state) then
            win:toast_notification('petrees',
                'Repo set to ' .. path .. '\nSaved. Press the key again.', nil, 5000)
        else
            win:toast_notification('petrees',
                'Repo set to ' .. path .. '\nCould not save, it will be asked again.', nil, 6000)
        end
    end),
})

local switch_to_worktree = wezterm.action_callback(function(win, pane, id)
    if not id then
        return
    end
    win:perform_action(
        act.SwitchToWorkspace({
            name = id:match('([^/]+)$'),
            spawn = { cwd = id },
        }),
        pane
    )
end)

-- Built at config time so it can be performed from inside a callback.
local name_prompt = act.PromptInputLine({
    description = 'New worktree (used as both directory and branch name)',
    action = wezterm.action_callback(function(win, pane, line)
        if not line or line == '' or not M.repo_root then
            return
        end
        win:perform_action(
            act.SwitchToWorkspace({
                name = line,
                spawn = {
                    args = { shell(), '-lc', create_script(M.repo_root, line, M.trunk) },
                    cwd = M.repo_root,
                },
            }),
            pane
        )
    end),
})

local run_delete = wezterm.action_callback(function(win, pane, id)
    if not id then
        return
    end
    win:perform_action(
        act.SpawnCommandInNewTab({
            args = { shell(), '-lc', delete_script(id, M.trunk) },
            cwd = id:match('^(.*)/[^/]+$') or M.repo_root,
        }),
        pane
    )
end)

-- Every entry point funnels through here, so an unconfigured petrees asks for a
-- repo instead of doing nothing.
local function needs_setup(win, pane)
    if ensure_repo_root() then
        return false
    end
    win:perform_action(setup_prompt, pane)
    return true
end

local pick_worktree = wezterm.action_callback(function(win, pane)
    if needs_setup(win, pane) then
        return
    end
    win:perform_action(
        act.InputSelector({
            title = 'Git worktrees',
            fuzzy = true,
            fuzzy_description = 'worktree> ',
            choices = worktree_choices(),
            action = switch_to_worktree,
        }),
        pane
    )
end)

local new_worktree = wezterm.action_callback(function(win, pane)
    if needs_setup(win, pane) then
        return
    end
    win:perform_action(name_prompt, pane)
end)

local remove_worktree = wezterm.action_callback(function(win, pane)
    if needs_setup(win, pane) then
        return
    end

    local choices = {}
    for _, c in ipairs(worktree_choices()) do
        -- Never offer the main worktree.
        if c.id ~= M.repo_root then
            table.insert(choices, c)
        end
    end

    if #choices == 0 then
        win:toast_notification('petrees', 'No linked worktrees to remove', nil, 4000)
        return
    end

    win:perform_action(
        act.InputSelector({
            title = 'Delete which worktree?',
            fuzzy = true,
            fuzzy_description = 'delete worktree> ',
            choices = choices,
            action = run_delete,
        }),
        pane
    )
end)

--------------------------------------------------------------------------------
-- Exports
--------------------------------------------------------------------------------

M.keys = {
    { key = 'o', mods = 'CMD|SHIFT', action = pick_worktree },
    { key = 'n', mods = 'CMD|SHIFT', action = new_worktree },
    { key = 'x', mods = 'CMD|SHIFT', action = remove_worktree },
    { key = 'r', mods = 'CMD|SHIFT', action = setup_prompt },
}

-- Append the petrees keys to a caller's key table.
function M.extend_keys(keys)
    for _, k in ipairs(M.keys) do
        table.insert(keys, k)
    end
    return keys
end

return M
