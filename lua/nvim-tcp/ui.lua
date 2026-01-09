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
			attach_mappings = function(prompt_bufnr)
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

function M.review_changes(changes, on_save)
	local items = vim.tbl_keys(changes)
	if #items == 0 then
		return print("No pending changes")
	end

	pickers
		.new({
			prompt_title = "Review Changes",
			finder = finders.new_table({ results = items }),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				define_preview = function(self, entry)
					local path = entry.value
					local pending_content = changes[path].content

					-- Get clean content from disk to compare to
					local disk_content = ""
					local fd = io.open(path, "r")
					if fd then
						disk_content = fd:read("*a")
						fd:close()
					end

					-- Create diff
					local diff_text = vim.diff(disk_content, pending_content, {
						result_type = "unified",
						ctxlen = 3,
					})

					-- Display the diff
					vim.api.nvim_buf_set_lines(
						self.state.bufnr,
						0,
						-1,
						false,
						vim.split(diff_text, "\n")
					)

					-- Set buf filetype to "diff" to get syntax highlight
					vim.bo[self.state.bufnr].filetype = "diff"
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					if selection then
						on_save(selection.value, changes[selection.value].content)
						-- Refresh picker
						local current_picker = action_state.get_current_picker(prompt_bufnr)
						local new_items = {}
						for p, _ in pairs(changes) do
							table.insert(new_items, p)
						end

						current_picker:refresh(
							finders.new_table({ results = new_items }),
							{ reset_prompt = false }
						)
					end
				end)
				return true
			end,
		})
		:find()
end

return M
