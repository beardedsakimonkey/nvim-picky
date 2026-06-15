Local neovim docs directory: /opt/homebrew/Cellar/neovim/0.12.2/share/nvim/runtime/doc
We only support neovim v0.12+

LuaLS `@class` names use PascalCase with a `Picky` prefix (e.g. `PickyItem`, `PickyConfig`).

For ad hoc headless Neovim checks, set `NVIM_LOG_FILE=/dev/null` to avoid creating `nvim.log` in the repo and use `set noswapfile` to prevent swap-file errors.
