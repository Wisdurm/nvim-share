local uv = vim.uv
local M = {}

M.applying_change = false
M.attached_buffers = {}

-- Applies content to a buffer
function M.apply_changes(path, change)
	local buf = vim.fn.bufnr(path)
	if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
		return false
	end

	M.applying_change = true

	-- Save cursor position to restore later
	local cursor = vim.api.nvim_win_get_cursor(0)

	if type(change) == "string" then
		-- Full update, sends entire buffer. This is for initial syncs
		local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local current_text = table.concat(current_lines, "\n")
		if current_text ~= change then
			pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, vim.split(change, "\n"))
		end
	elseif type(change) == "table" then
		-- Partial update, very fast and reliable
		-- TODO: If feeling masochistic, verify that existing lines match expected old lines
		pcall(vim.api.nvim_buf_set_lines, buf, change.first, change.old_last, false, change.lines)
	end

	-- Restore cursor if we are in that buffer
	if vim.api.nvim_get_current_buf() == buf then
		local line_count = vim.api.nvim_buf_line_count(buf)
		if cursor[1] > line_count then
			cursor[1] = line_count
		end
		pcall(vim.api.nvim_win_set_cursor, 0, cursor)
	end

	vim.bo[buf].modified = false
	M.applying_change = false
	return true
end

-- Attaches listeners to a buffer to detect and send changes, down to the changed line 
function M.attach_listeners(buf, path, callback)
	if M.attached_buffers[buf] then
		return
	end

	M.attached_buffers[buf] = true

	-- Listens for buffer changes and gets exact places where the chnage happend
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, _, _, firstline, old_lastline, new_lastline)
			if M.applying_change then
				return
			end

			-- Check if buffer is valid
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			
			local lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, false)
			local change = {
				first = firstline,
				old_last = old_lastline,
				lines = lines,
			}
			callback(path, change)
		end,
		on_detach = function()
			M.attached_buffers[buf] = nil
		end,
	})
end

return M
