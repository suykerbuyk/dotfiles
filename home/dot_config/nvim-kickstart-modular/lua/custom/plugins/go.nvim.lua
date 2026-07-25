return {
  'ray-x/go.nvim',
  dependencies = { -- optional packages
    'ray-x/guihua.lua',
    'neovim/nvim-lspconfig',
    'nvim-treesitter/nvim-treesitter',
  },
  opts = {
    -- go.nvim configures gopls itself (found on PATH) with go-tuned defaults;
    -- kickstart's lspconfig leaves gopls commented out, so without this no
    -- LSP attaches to Go buffers at all.
    lsp_cfg = true,
    -- lsp_keymaps = false,
    -- other options
  },
  config = function(lp, opts)
    require('go').setup(opts)
    local format_sync_grp = vim.api.nvim_create_augroup('GoFormat', {})
    vim.api.nvim_create_autocmd('BufWritePre', {
      pattern = '*.go',
      callback = function()
        require('go.format').goimports()
      end,
      group = format_sync_grp,
    })
  end,
  event = { 'CmdlineEnter' },
  ft = { 'go', 'gomod' },
  build = ':lua require("go.install").update_all_sync()', -- if you need to install/update all binaries
}
