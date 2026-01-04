local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local conf = require("telescope.config").values
local action_state = require("telescope.actions.state")
local actions = require("telescope.actions")
local previewers = require("telescope.previewers")
local themes = require("telescope.themes")

local M = {}

function M.show_remote_files(files, on_select)
	pickers
		.new(themes.get_ivy({
			prompt_title = "Remote Files",
			finder = finders.new_table({ results = files }),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				-- On selection
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						on_select(selection[1])
					end
				end)
				return true
			end,
		}))
		:find()
end

function M.review_changes(pending_changes, on_save)
	local items = {}
	for path, _ in pairs(pending_changes) do
		table.insert(items, path)
	end

	pickers
		.new({
			prompt_title = "Pending Changes",
			finder = finders.new_table({ results = items }),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Review Diff",
				get_buffer_by_name = function(_, entry)
					return entry.value
				end,
				define_preview = function(self, entry, status)
					local path = entry.value
					local data = pending_changes[path]
					if not data then
						return
					end

					local f = io.open(path, "r")
					local current_content = f and f:read("*a") or ""
					if f then
						f:close()
					end

					local ok, diff = pcall(
						vim.diff,
						current_content,
						data.content,
						{ result_type = "unified", ctxlen = 3 }
					)

					vim.schedule(function()
						if not vim.api.nvim_buf_is_valid(self.state.bufnr) then
							return
						end

						if ok and diff and type(diff) == "string" and #diff > 0 then
							vim.api.nvim_buf_set_lines(
								self.state.bufnr,
								0,
								-1,
								false,
								vim.split(diff, "\n")
							)
							vim.bo[self.state.bufnr].filetype = "diff"
						else
							vim.api.nvim_buf_set_lines(
								self.state.bufnr,
								0,
								-1,
								false,
								vim.split(data.content, "\n")
							)
							local ft = vim.filetype.match({ filename = path })
							if ft then
								vim.bo[self.state.bufnr].filetype = ft
							end
						end
					end)
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end

					local path = selection.value
					on_save(path)

					-- Refresh picker
					local current_picker = action_state.get_current_picker(prompt_bufnr)
					local new_items = {}
					for p, _ in pairs(pending_changes) do
						table.insert(new_items, p)
					end

					current_picker:refresh(
						finders.new_table({ results = new_items }),
						{ reset_prompt = false }
					)
				end)
				return true
			end,
		})
		:find()
end

return M
