if vim.g.loaded_fpkit ~= nil then
  return
end

vim.g.loaded_fpkit = true

require('fpkit.Pair').setup()

vim.api.nvim_create_user_command('Dired', function(opts)
  local path = #opts.args > 0 and vim.fs.abspath(vim.fs.normalize(opts.args)) or vim.uv.cwd()
  require('fpkit.Dired').browse_directory(path)
end, { nargs = '?' })

local highlights = {
  DiredDirectory = { fg = '#88c0d0', bold = true },
  DiredSymlink = { fg = '#b48ead', bold = true },
  DiredExecutable = { fg = '#a3be8c', bold = true },
  DiredPermissions = { fg = '#4c566a' },
  DiredSize = { fg = '#8fbcbb' },
  DiredUser = { fg = '#d08770' },
  DiredDate = { fg = '#4c566a' },
  DiredHeader = { fg = '#81a1c1', bold = true },
  DiredHeaderLine = { fg = '#3b4252' },
  DiredCurrent = { bg = '#41466e' },
  DiredPrompt = { fg = '#a3be8c' },
}

for name, attrs in pairs(highlights) do
  vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', attrs, { default = true }))
end
