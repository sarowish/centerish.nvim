# centerish.nvim

Keep your editing area centered in Neovim.

Centerish adds horizontal padding around your editing windows while preserving
their split proportions. File trees can occupy the margins, and optional
adaptive width makes room for long visible lines.

<img width="1494" height="747" alt="image" src="https://github.com/user-attachments/assets/3cf2452c-935d-434b-b116-100722c7a137" />

Requires **Neovim 0.10 or newer**.

## Getting started

### vim.pack

Requires Neovim 0.12 or newer and Git. Add this to your `init.lua`:

```lua
vim.pack.add({
  { src = "https://github.com/sarowish/centerish.nvim" },
}, { load = true })

require("centerish").setup({ width = 120 })

vim.keymap.set("n", "<leader>uc", "<cmd>CenterishToggle<cr>", {
  desc = "Toggle centering",
})
```

### lazy.nvim

Add this to your [lazy.nvim](https://github.com/folke/lazy.nvim) plugin specs:

```lua
{
  "sarowish/centerish.nvim",
  lazy = false,
  opts = { width = 120 },
  keys = {
    { "<leader>uc", "<cmd>CenterishToggle<cr>", desc = "Toggle centering" },
  },
}
```

### Enable centering

Install the plugin and restart Neovim. Open a file, then press `<leader>uc` or
run `:CenterishToggle`. When there is enough space, padding appears on both
sides of your editing area. Toggle again to remove it.

Centering starts disabled. Both examples load Centerish at startup so it is
also available when restoring sessions.

## Usage

| Command             | Action                                                      |
| ------------------- | ----------------------------------------------------------- |
| `:CenterishEnable`  | Center the current tab.                                     |
| `:CenterishDisable` | Remove the current tab's padding and reset adaptive growth. |
| `:CenterishToggle`  | Switch between those two states.                            |

Each tab is enabled independently. New tabs start disabled. Use your usual
split and window commands; navigation skips padding and wraps when moving
into padding at an outer edge.

Disabling keeps your editing windows open. Their sizes from before centering
are not restored.

## Configuration

With lazy.nvim, put these options in your plugin spec's `opts` table.

For all options and defaults, see the [configuration reference](doc/centerish.txt)
or run `:help centerish-config`.

`width` is a target for each editing column, including its gutters. It is not
a limit on the entire tab. Stacked windows share a column; unequal splits
retain their relative widths when space permits.

To keep only the left margin:

```lua
require("centerish").setup({
  width = 100,
  padding = { right = false },
})
```

The editor takes the space that would have been right padding. The left margin
stays in its centered position.

To widen windows for long visible lines:

```lua
require("centerish").setup({
  width = 100,
  adaptive = {
    enabled = true,
    max_width = 160,
  },
})
```

By default, growth uses right padding and keeps the left edge in place. Growth
is kept when you scroll to shorter lines or switch buffers; disable centering
to reset it. Available space and fixed-width windows can limit growth.

Manually moving the editing area's outer edges pauses adaptive growth until
centering is disabled and re-enabled.

The `NvimTree` and `neo-tree` filetypes are recognized as left sidebars by default.
To configure other filetypes or right sidebars, see the
[sidebar reference](doc/centerish.txt) or run `:help centerish-sidebars`.

## Sessions

Use `:mksession` and `:source` normally. Load Centerish before sourcing the
session and keep `blank` in `sessionoptions` so Neovim saves the padding needed
to restore centering. Tabs without saved padding must be enabled manually.

See the [session instructions](doc/centerish.txt) or run `:help centerish-sessions`
for the complete reference.

## Documentation

Run `:help centerish` for all options, layout behavior, and the Lua API, or
read [the help file](doc/centerish.txt) on GitHub.

## License

[MIT](LICENSE).
