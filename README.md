<!--markdoc_ignore_start-->
<h1 align="center">mathlive.nvim</h1>

<p align="center">
  Live math previews as images inside Neovim.
</p>

## Features
- Replaces source math with rendered images seamlessly inside Neovim.
- Low latency preview that updates live while typing.
- Supports [Typst](https://typst.app/) in `markdown` with `$inline$` or `$$display$$` blocks.

## Table of Contents
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Compatibility](#compatibility)
  - [mathlive.nvim](#mathlive.nvim)
  - [render-markdown.nvim](#render-markdown.nvim)
- [Acknowledgements](#acknowledgements)

## Requirements
- Neovim >= 0.11
- Typst
- Tree-sitter with `markdown`, `markdown_inline`, and `latex` parsers
### Supported Terminals
- [Ghostty](https://ghostty.org)
- [kitty](https://sw.kovidgoyal.net/kitty)
- [iTerm2](https://github.com/gnachman/iTerm2)
- [st](https://st.suckless.org/) (with a [patch](https://st.suckless.org/patches/kitty-graphics-protocol/))
- [tmux](https://github.com/tmux/tmux)
### Unsupported Terminals
- [WezTerm](https://wezterm.org) ([tracking issue](https://github.com/wezterm/wezterm/issues/986)): Missing unicode placeholders.
- [Konsole](https://invent.kde.org/utilities/konsole) ([related issue](https://github.com/3rd/image.nvim/issues/74)): Missing unicode placeholders.
- [Warp](https://www.warp.dev) ([tracking issue](https://github.com/warpdotdev/warp/issues/6210)): Missing unicode placeholders.
- [xterm.js](https://github.com/xtermjs/xterm.js) ([tracking issue](https://github.com/xtermjs/xterm.js/issues/5711)): Missing unicode placeholders.
- [Alacritty](https://alacritty.org) ([tracking issue](https://github.com/alacritty/alacritty/issues/910))
- [Zellij](https://zellij.dev) ([tracking issue](https://github.com/zellij-org/zellij/issues/2814))

## Installation
mathlive.nvim auto-initializes with sensible defaults. No `setup()` call is required unless you want to change the [default configuration]().
### vim.pack
```lua
vim.pack.add({
  "https://github.com/saadndm/mathlive.nvim",
})
```
### lazy.nvim
```lua
return {
  "saadndm/mathlive.nvim",
  lazy = false, -- the plugin lazy-loads itself
};
```

## Configuration

```lua
require("mathlive").setup({
  -- Filetypes where mathlive should attach.
  -- Set to {} to disable automatic attachment.
  filetypes = { "markdown" },

  -- Formula foreground color.
  -- If empty, falls back to the highlight groups:
  -- @markup.math.latex, Special or Normal, in that order.
  color_hex = "", -- Example: "#ffffff"

  -- Pixel density used when Typst renders PNGs.
  ppi = 300,

  -- Typst code inserted before each formula.
  -- Use this to customize how Typst renders math.
  preamble = [[]],

  -- Multiplier for formula size relative to terminal cell height.
  -- 1.0 makes rendered text roughly match Neovim's text size.
  text_scale = 1.0,
})
```

## Compatibility
### [markview.nvim](https://github.com/OXY2DEV/markview.nvim)
```lua
require("markview").setup({
  preview = {
    enable_hybrid_mode = true,
    linewise_hybrid_mode = false,
    debounce = 1,
    modes = { "n", "i", "v", "c" },
    hybrid_modes = { "n", "i", "v", "c" },
    callbacks = {
      on_enable = function (_, win)
        vim.wo[win].conceallevel = 3
        vim.wo[win].concealcursor = "nvic"
      end,
      on_mode_change = function (_, win)
        vim.wo[win].conceallevel = 3
        vim.wo[win].concealcursor = "nvic"
      end,
      on_hybrid_enable = function (_, win)
        vim.wo[win].conceallevel = 3
        vim.wo[win].concealcursor = "nvic"
      end
    }
  },
  typst = {
    math_blocks = { enable = false },
    math_spans = { enable = false },
    symbols = { enable = false },
    code_blocks = { enable = false },
    superscripts = { enable = false },
    subscripts = { enable = false },
  },
  latex = {
    blocks = { enable = false },
    inlines = { enable = false },
    symbols = { enable = false },
    superscripts = { enable = false },
    subscripts = { enable = false },
    commands = { enable = false },
    fonts = { enable = false },
  },
  })
```
### [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
```lua
require("render-markdown").setup({
  win_options = {
    concealcursor = { rendered = "nvic" }
  },
  latex = { enabled = false }
})
```

## WIP
- Document/Implement autocomplete via [otter.nvim](https://github.com/jmbuhr/otter.nvim).
- Document/Implement formatting inside math blocks via [conform.nvim](https://github.com/stevearc/conform.nvim).
- LaTeX support via [tylax](https://github.com/scipenai/tylax).
- `wrap` support (blocked by [this neovim issue](https://github.com/neovim/neovim/issues/33724)).
- Replace the `typst` CLI dependency with [typst-lua](https://github.com/rousbound/typst-lua) lua bindings.

## Acknowledgements
- Inspired by [markview.nvim](https://github.com/OXY2DEV/markview.nvim).
- The Kitty graphics renderer is adapted from [snacks.nvim](https://github.com/folke/snacks.nvim).
