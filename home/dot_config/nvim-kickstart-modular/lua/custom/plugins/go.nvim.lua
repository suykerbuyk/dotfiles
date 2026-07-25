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
  -- Go format-on-save belongs to conform (goimports + gofmt binaries, sync).
  -- Do NOT re-add a GoFormat autocmd: go.nvim's goimports() routes through an
  -- async gopls organizeImports code action that can write the buffer after
  -- the save it was triggered by.
  event = { 'CmdlineEnter' },
  ft = { 'go', 'gomod' },
  build = ':lua require("go.install").update_all_sync()', -- if you need to install/update all binaries
}
