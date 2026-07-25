-- Diagnostics-only: conform.nvim owns ALL formatting (see custom/plugins/
-- conform.lua). none-ls must never register a formatting source or a
-- format-on-save autocmd — vim.lsp.buf.format would re-format what conform
-- already formatted, with ordering that varies per buffer.
return {
  'nvimtools/none-ls.nvim',
  dependencies = { 'nvim-lua/plenary.nvim' },
  config = function()
    local null_ls = require 'null-ls'
    null_ls.setup {
      sources = {
        null_ls.builtins.diagnostics.checkmake,
      },
    }
  end,
}
