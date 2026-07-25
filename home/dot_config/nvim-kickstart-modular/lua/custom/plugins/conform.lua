return {
  { -- Autoformat
    'stevearc/conform.nvim',
    event = { 'BufWritePre' },
    cmd = { 'ConformInfo' },
    keys = {
      {
        '<leader>f',
        function()
          require('conform').format { async = true, lsp_format = 'fallback' }
        end,
        mode = '',
        desc = '[F]ormat buffer',
      },
    },
    opts = {
      notify_on_error = false,
      format_on_save = function(bufnr)
        -- :ToggleAutoformat / <leader>tF flips this global off and on
        if vim.g.autoformat == false then
          return nil
        end
        -- Disable "format_on_save lsp_fallback" for languages that don't
        -- have a well standardized coding style. You can add additional
        -- languages here or re-enable it for the disabled ones.
        local disable_filetypes = { c = true, cpp = true }
        if disable_filetypes[vim.bo[bufnr].filetype] then
          return nil
        else
          return {
            timeout_ms = 500,
            lsp_format = 'fallback',
          }
        end
      end,
      -- conform is the single format-on-save owner: none-ls carries only
      -- diagnostics (checkmake) and must not re-format via vim.lsp.buf.format
      formatters_by_ft = {
        lua = { 'stylua' },
        go = { 'goimports', 'gofmt' },
        javascript = { 'prettier' },
        json = { 'prettier' },
        markdown = { 'prettier' },
        html = { 'prettier' },
        yaml = { 'prettier' },
        toml = { 'taplo' },
        sh = { 'shfmt' },
        bash = { 'shfmt' },
        -- ruff_organize_imports keeps the import sorting the old null-ls
        -- `ruff --extend-select I` source provided; ruff_format alone drops it
        python = { 'ruff_organize_imports', 'ruff_format' },
        rust = { 'rustfmt', lsp_format = 'fallback' },
      },
    },
    config = function(_, opts)
      local conform = require 'conform'
      conform.setup(opts)
      conform.formatters.shfmt = {
        prepend_args = { '-i', '4' }, -- 4-space indent, matching the repo's shell style
      }
      vim.api.nvim_create_user_command('ToggleAutoformat', function()
        vim.g.autoformat = vim.g.autoformat == false and true or false
        vim.api.nvim_notify(
          'Format on save ' .. (vim.g.autoformat == false and 'disabled' or 'enabled') .. '.',
          vim.log.levels.INFO,
          { title = 'conform.nvim' }
        )
      end, { desc = 'Toggle format on save' })
      vim.keymap.set('n', '<leader>tF', '<cmd>ToggleAutoformat<cr>', { desc = 'Toggle format on save' })
    end,
  },
}
-- vim: ts=2 sts=2 sw=2 et
