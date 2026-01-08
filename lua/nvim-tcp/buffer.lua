local uv = vim.uv
local M = {}

M.attached = {} -- Keep track attached buffers
M.is_applying = false

-- Reads file and returns content
function M.read_file(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	return content
end

-- Write to file safely
function M.write_file(path, content)
	if type(content) ~= "string" then
		return
	end
	-- Ensure dir exists
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	-- Write (temp + rename)
	local tmp = path .. ".tmp"
	local fd = uv.fs_open(tmp, "w", 438) -- 0666 on linux
	if fd then
		uv.fs_write(fd, content, -1)
		uv.fs_close(fd)
		uv.fs_rename(tmp, path)
	end
end

-- Scans host dir recursively using libuv
function M.scan_dir(path)
	path = path or "."
	local files = {}
	-- TODO: add to config
	local ignore_patterns = { "^%.git", "^node_modules", "^%.venv", "^build", "^%.env" }

	-- Check if dir/file is in ignored patterns
	local function is_ignored(name)
		for _, pat in ipairs(ignore_patterns) do
			if name:match(pat) then
				return true
			end
		end
		return false
	end

	-- Recursive scanner
	local function scan(dir)
		local scanner = uv.fs_scandir(dir)
		if not scanner then
			return
		end

		while true do
			local name, type = uv.fs_scandir_next(scanner)
			if not name then
				break
			end

			local relative_path = (dir == "." and name) or (dir .. "/" .. name)

			if not is_ignored(relative_path) then
				if type == "directory" then
					scan(relative_path)
				elseif type == "file" or type == "link" then
					table.insert(files, relative_path)
				end
			end
		end
	end

	scan(path)
	return files
end

-- Gets buffer content based on path
function M.get_buffer_content(path)
	local buf = vim.fn.bufnr(path)

	-- Check if valid and loaded
	if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
		-- Get lines and return full content
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		return table.concat(lines, "\n")
	end
	return nil
end

function M.create_scratch_buf(path, content)
	local buf = vim.fn.bufnr(path)
	if buf == -1 then
		buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(buf)
		vim.bo[buf].buftype = "acwrite" -- Allow saving but handle it manually
		-- Swapfiles cause major headaches so forcefully GET THEM OUT
		vim.bo[buf].swapfile = false
		vim.cmd("silent! keepalt file " .. vim.fn.fnameescape(path))
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))

	-- Trick neovim to read this buffer as real file
	-- For syntax highlighting and other plugins
	local ft = vim.filetype.match({ filename = path })
	if ft then
		vim.bo[buf].filetype = ft
	end

	-- Fake save to clear modified flag
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			vim.bo[buf].modified = false
		end,
	})

	return buf
end

-- Reconstructs file content from a diff/patch without a buffer
function M.reconstruct_text(path, change, pending_data)
	if type(change) == "string" then
		return change
	end -- Full file sent

	-- Get base
	local text = (pending_data and pending_data.content) or M.read_file(path) or ""
	local lines = vim.split(text, "\n")

	-- Not that useful docs: https://neovim.io/doc/user/api.html#nvim_buf_attach()
	local start_idx = change.first + 1
	local end_idx = change.old_last
	local new_lines = change.lines

	-- How this works:
	-- lines: {"katti", "mirri", "hauva", "koira"}
	-- If we replace "mirri" and "hauva" (2-3) with "kissakoira":
	-- 1. (1 to start_idx - 1) Take everything before index 2 -> {"katti"}
	-- 2. (new_lines) Add the new lines -> {"kissakoira"}
	-- 3. (end_idx + 1 to #lines) Take everything after index 3 -> {"koira"}
	-- Result: {"katti", "kissakoira", "koira"}

	local res = {}
	-- Add lines before the change
	for i = 1, start_idx - 1 do
		table.insert(res, lines[i])
	end
	-- Add the new/changed lines
	for _, l in ipairs(new_lines) do
		table.insert(res, l)
	end
	-- Add lines after the change
	for i = end_idx + 1, #lines do
		table.insert(res, lines[i])
	end

	return table.concat(res, "\n")
end

function M.apply_patch(path, change)
	local buf = vim.fn.bufnr(path)
	-- Check buffer validity
	if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
		return false
	end

	M.is_applying = true

	-- If full content (no incremental update table)
	if type(change) == "string" then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(change, "\n"))
	else
		-- If info about exact places where a change happend
		-- "Smart" cursor preservation (keep cursor on intended place even if newlines are added or removed)
		local cursor = vim.api.nvim_win_get_cursor(0)
		local is_cur_buf = vim.api.nvim_get_current_buf() == buf

		-- Update only changed lines
		pcall(vim.api.nvim_buf_set_lines, buf, change.first, change.old_last, false, change.lines)

		-- If change happened above cursor, shift cursor (...smart cursor preservation)
		if is_cur_buf and cursor[1] > change.first then
			local delta = #change.lines - (change.old_last - change.first)
			local new_row = math.max(1, cursor[1] + delta)
			pcall(vim.api.nvim_win_set_cursor, 0, { new_row, cursor[2] })
		end
	end

	vim.bo[buf].modified = false
	M.is_applying = false
	return true
end

-- Listens buffer for changes and in on_change callback return THE EXACT changes, so no need to push the whole litany of text
function M.attach_listener(buf, on_change)
	if M.attached[buf] then
		return
	end

	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")

	-- Attach listner to the buffer
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, _, _, first, old_last, new_last)
			if M.is_applying then
				return
			end

			local lines = vim.api.nvim_buf_get_lines(buf, first, new_last, false)
			on_change(path, {
				first = first,
				old_last = old_last,
				lines = lines,
			})
		end,
		on_detach = function()
			M.attached[buf] = nil
		end,
	})
	M.attached[buf] = true
end

return M
