# Petrees

WezTerm configuration and the petrees workspace/worktree manager.

The active files in `~/.config/wezterm/` are symlinks to `wezterm/` in this repo.
The machine-specific `~/.config/wezterm/petrees.json` stays outside Git.

To install on another machine, clone into `~/personal-dev/petrees`, back up
existing configuration files, then run:

```sh
mkdir -p ~/.config/wezterm
ln -s ~/personal-dev/petrees/wezterm/wezterm.lua ~/.config/wezterm/wezterm.lua
ln -s ~/personal-dev/petrees/wezterm/petrees.lua ~/.config/wezterm/petrees.lua
```

See the comments in the Lua files for key bindings and required terminfo setup.
