vim.cmd([[let &rtp.=','.getcwd()]])
vim.cmd("set rtp+=deps/nvim-treesitter")

-- Install and setup Tree-sitter
require("nvim-treesitter").setup({
  install_dir = "deps/parsers",
})

local ok, err_or_ok = require("nvim-treesitter")
    .install({
      "markdown",
      "markdown_inline",
      "latex",
    }, { summary = true, max_jobs = 10 })
    :wait(1800000)

if not ok then
  print("ERROR: ", err_or_ok)
end

-- Set up 'mini.test' only when calling headless Neovim (like with `make test`)
if #vim.api.nvim_list_uis() == 0 then
  -- Add 'mini.nvim' to 'runtimepath' to be able to use 'mini.test'
  -- Assumed that 'mini.nvim' is stored in 'deps/mini.nvim'
  vim.cmd('set rtp+=deps/mini.nvim')

  -- Set up 'mini.test'
  require('mini.test').setup()
end
