# agentation.nvim

Minimal Neovim bridge for Agentation component-source links.

## Related components

- [`@alexgorbatchev/agentation`](https://github.com/alexgorbatchev/agentation) — frontend annotation toolbar
- [`@alexgorbatchev/agentation-cli`](https://github.com/alexgorbatchev/agentation-cli) — local server/router CLI required for router mode
- [`@alexgorbatchev/agentation-skills`](https://github.com/alexgorbatchev/agentation-skills) — shared coding-agent skills for Agentation workflows
- [`@alexgorbatchev/pi-agentation`](https://github.com/alexgorbatchev/pi-agentation) — Pi integration for automated Agentation fix loops
- [agentation.dev](https://agentation.dev) — public docs and examples

## What it does

- starts a small local HTTP server
- accepts requests like `/open?path=src/Button.tsx&line=42&column=8`
- opens the file in the current Neovim instance and jumps to the location
- optionally registers this Neovim session with the Agentation router managed by the `agentation` CLI

## Install

Install as a regular Neovim plugin.

Example with `lazy.nvim`:

```lua
{
  "alexgorbatchev/agentation.nvim",
  config = function()
    require("agentation").setup({
      root = vim.fn.getcwd(),

      -- Optional router integration
      router_url = "http://127.0.0.1:8787",
      router_bin = "agentation",
    })
  end,
}
```

## Commands

- `:AgentationStart`
- `:AgentationStop`
- `:AgentationStatus`

`AgentationStatus` reports whether the bridge is:

- not running
- listening with no webpage connected
- connected to a webpage via heartbeat

## Configuration

```lua
require("agentation").setup({
  host = "127.0.0.1",
  port = 8777,
  root = vim.fn.getcwd(),
  allow_absolute_paths = false,

  -- Optional router integration
  router_url = "http://127.0.0.1:8787",
  router_token = nil,
  router_register_interval_ms = 5000,
  router_auto_start = true,
  router_bin = "agentation", -- defaults to PATH lookup
  router_start_args = { "start" },

  -- Optional identity overrides
  project_id = nil,
  repo_id = nil,
  session_id = nil,
  display_name = nil,

  -- Statusline indicator
  statusline_enabled = true,
  statusline_auto_append = true,
  statusline_label = "AGT",
})
```

Project IDs default to `sha256(realpath(git_root_or_root))`.
Repo IDs default to `sha256(git remote.origin.url)` when available.

When `router_auto_start=true`, the plugin attempts to start the router with `<router_bin> <router_start_args...>` whenever `router_url` is configured but unreachable.

With the current CLI lifecycle model, `router_start_args = { "start" }` starts the single Agentation stack process (server + router).
If you want router-only startup from Neovim auto-start, launch Neovim with `AGENTATION_SERVER_ADDR=0` in the environment.

`router_bin` defaults to `"agentation"` (resolved via `PATH`). Set an absolute path in `setup()` if you want to force a local binary.

Startup auto-connect failures are silent. Manual `:AgentationStart` emits at most one router warning per command invocation.

## Statusline indicator

When `statusline_enabled=true`, the plugin exposes:

- `%{%v:lua.require('agentation').statusline()%}`

If `statusline_auto_append=true`, it is appended automatically to the built-in statusline (unless you use a `%!` expression statusline).

Format:

- `AGT B+ P+ R+`
- `B`: local Neovim bridge server running
- `P`: webpage heartbeat connected
- `R`: router state (`+` connected, `-` configured but not connected, `!` not configured)

## Agentation usage

Pass `componentEditor="neovim"` to `PageFeedbackToolbarCSS`.

For router mode, also set `neovimBridgeUrl` in the frontend:

```tsx
<Agentation
  componentEditor="neovim"
  neovimBridgeUrl="http://127.0.0.1:8787"
/>
```
