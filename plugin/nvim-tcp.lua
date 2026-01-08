-- Make sure not to load multiple times
if vim.g.loaded_nvim_tcp then
	return
end
vim.g.loaded_nvim_tcp = 1

-- Use default setup (can be overridden by the user)
require("nvim-tcp").setup({})
