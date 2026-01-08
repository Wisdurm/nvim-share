local uv = vim.uv

local M = {}

M.applying_change = false
M.attached_buffers = {}

function M.apply_changes(path, change)
	local buf = vim.fn.bufnr(path)
	if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
		return false
	end

	M.applying_change = true

	-- Check if we are currently looking at this buffer to handle cursor
	local is_current_buf = vim.api.nvim_get_current_buf() == buf
	local cursor = nil

	if is_current_buf then
		cursor = vim.api.nvim_win_get_cursor(0)
	end

	local line_offset = 0

	if type(change) == "string" then
		-- Full update, sends entire buffer. This is for initial syncs
		local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local current_text = table.concat(current_lines, "\n")
		if current_text ~= change then
			pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, vim.split(change, "\n"))
		end
	elseif type(change) == "table" then
		-- Partial update

		-- 0-index start and end line of the change
		local start_row = change.first
		local old_end_row = change.old_last

		local new_count = #change.lines
		local old_count = old_end_row - start_row
		local delta = new_count - old_count

		-- Only shift cursor if we are valid and the cursor is BELOW the change
		-- cursor[1] is 1-based, start_row is 0-based.
		if cursor and start_row < (cursor[1] - 1) then
			line_offset = delta
		end

		pcall(vim.api.nvim_buf_set_lines, buf, change.first, change.old_last, false, change.lines)
	end

	-- Restore cursor with calculated offset
	if is_current_buf and cursor then
		local new_row = cursor[1] + line_offset

		-- Ensure we don't jump to negative lines or 0
		if new_row < 1 then
			new_row = 1
		end

		-- Ensure we don't jump past the new end of file
		local line_count = vim.api.nvim_buf_line_count(buf)
		if new_row > line_count then
			new_row = line_count
		end

		cursor[1] = new_row
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
