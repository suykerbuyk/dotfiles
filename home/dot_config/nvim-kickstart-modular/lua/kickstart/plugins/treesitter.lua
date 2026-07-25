return {
  { -- Highlight, edit, and navigate code
    'nvim-treesitter/nvim-treesitter',
    -- The rewritten main branch: the old configs module with its
    -- ensure_installed/opts is gone — parsers install via install(), and
    -- features are enabled per buffer from the FileType autocmd below. Needs
    -- the tree-sitter CLI (fetch.bins/15_fetch.tree-sitter.sh) for parsers.
    branch = 'main',
    lazy = false, -- upstream: "This plugin does not support lazy-loading."
    build = ':TSUpdate',
    config = function()
      local ts = require 'nvim-treesitter'

      -- Parsers installed up front. Base kickstart set, plus go and rust
      -- (formerly the custom/plugins/treesitter.lua overlay — merged here
      -- because config functions, unlike opts tables, do not merge).
      -- Anything else auto-installs on first use via the autocmd below.
      ts.install {
        'bash',
        'c',
        'diff',
        'html',
        'lua',
        'luadoc',
        'markdown',
        'markdown_inline',
        'query',
        'vim',
        'vimdoc',
        'go',
        'rust',
      }

      ---@param buf integer
      ---@param language string
      local function try_attach(buf, language)
        -- Check if a parser exists and load it
        if not vim.treesitter.language.add(language) then
          return
        end
        -- Enable syntax highlighting and other treesitter features
        vim.treesitter.start(buf, language)
        -- Treesitter indentation where an indent query exists (falls back to
        -- vim's built-in indenting otherwise)
        if vim.treesitter.query.get(language, 'indents') then
          vim.bo[buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end
      end

      local available_parsers = ts.get_available()
      vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup('kickstart-treesitter-attach', { clear = true }),
        callback = function(args)
          local buf, filetype = args.buf, args.match
          local language = vim.treesitter.language.get_lang(filetype)
          if not language then
            return
          end
          if vim.tbl_contains(ts.get_installed 'parsers', language) then
            -- Parser already installed — attach immediately
            try_attach(buf, language)
          elseif vim.tbl_contains(available_parsers, language) then
            -- Known to nvim-treesitter but not installed — install, then attach
            ts.install(language):await(function()
              if vim.api.nvim_buf_is_valid(buf) then
                try_attach(buf, language)
              end
            end)
          else
            -- Parser may exist outside nvim-treesitter — try anyway
            try_attach(buf, language)
          end
        end,
      })
    end,
  },
}
-- vim: ts=2 sts=2 sw=2 et
