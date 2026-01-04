local uv = vim.uv
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local conf = require("telescope.config").values
local action_state = require("telescope.actions.state")
local actions = require("telescope.actions")
local previewers = require("telescope.previewers")
local themes = require("telescope.themes")

local M = {}

M.role = nil
M.client = nil
M.pending_changes = {}
M.connected_clients = {}
M.applying_change = false
M.buffer_last_sent = {}
M.buffer_last_received = {}

local DEBOUNCE_MS = 50
local PORT = 8080

-- Sends raw data over TCP
local function send_raw(data)
	if M.client then
		M.client:write(data)
	end
end

-- Sends a json encoded message
local function send_json(cmd, payload)
	local msg = cmd .. ":" .. vim.json.encode(payload) .. "\n"
	send_raw(msg)
end

-- Sends a message to a specific client (host only)
local function send_to(client_id, cmd, payload)
	local msg = client_id .. ":" .. cmd .. ":" .. vim.json.encode(payload) .. "\n"
	send_raw(msg)
end

-- Broadcasts an update to all connected clients except exclude_id (usually the sender)
local function broadcast_update(path, content, exclude_id)
	for id, _ in pairs(M.connected_clients) do
		if id ~= exclude_id then
			send_to(id, "UPDATE", { path = path, content = content })
		end
	end
end

-- Applies content to a buffer if it differs from current content
local function apply_buffer_changes(path, content)
	local buf = vim.fn.bufnr(path)
	if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
		return false
	end

	local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local current_text = table.concat(current_lines, "\n")

	if current_text == content then
		return false
	end

	-- Track received content to prevent echoing it back, very hacky but works
	M.buffer_last_received[buf] = content
	M.applying_change = true

	-- Save cursor position
	local cursor = vim.api.nvim_win_get_cursor(0)

	-- Apply changes
	pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, vim.split(content, "\n"))

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

-- Attaches listeners to a buffer to detect and send changes, with debouncing
local function attach_buffer_listeners(buf, path, callback)
	local timer = uv.new_timer()

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = function()
			if M.applying_change then
				return
			end

			timer:stop()
			timer:start(
				DEBOUNCE_MS,
				0,
				vim.schedule_wrap(function()
					if not vim.api.nvim_buf_is_valid(buf) then
						return
					end
					if M.applying_change then
						return
					end

					local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
					local text = table.concat(lines, "\n")

					-- Only send if content differs from what we last sent or received
					if text ~= M.buffer_last_sent[buf] and text ~= M.buffer_last_received[buf] then
						M.buffer_last_sent[buf] = text
						callback(path, text)
					end
				end)
			)
		end,
	})

	-- Make sure that everything is cleared when closing buffer so they don't linger
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		callback = function()
			if not timer:is_closing() then
				timer:close()
			end
			M.buffer_last_sent[buf] = nil
			M.buffer_last_received[buf] = nil
		end,
	})
end

-- Host sends list of files to spesified client
local function handle_list_req(client_id)
	-- fetch all files in current directory recursively
	local files = vim.fn.glob("**/*", false, true)
	local filtered = {}
	for _, f in ipairs(files) do
		-- Keep .git and .env safe, and skip build directory too
		-- TODO: add more filters later
		if
			vim.fn.isdirectory(f) == 0
			and not f:match("^%.git")
			and not f:match("^build")
			and not f:match("^%.env")
		then
			table.insert(filtered, f)
		end
	end
	send_to(client_id, "FILE_LIST", filtered)
end

-- Host sends file content on GET_REG
local function handle_get_req(client_id, payload)
	local path = payload.path
	local content = nil

	-- 1. Try to get from loaded buffer
	local buf = vim.fn.bufnr(path)
	if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		content = table.concat(lines, "\n")
	end

	-- 2. Try to get from pending changes
	if not content and M.pending_changes[path] then
		content = M.pending_changes[path].content
	end

	-- 3. Fallback to disk
	if not content then
		local f = io.open(path, "r")
		if f then
			content = f:read("*a")
			f:close()
		end
	end

	if content then
		send_to(client_id, "FILE", { path = path, content = content })
	end
end

-- Host handles an UPDATE message from a client. Applies changes to buffer, bordcasts the update to other clients and adds pending change
local function handle_update(client_id, payload)
	local path = payload.path
	local content = payload.content

	-- Check against file on disk
	local f = io.open(path, "r")
	local disk_content = ""
	if f then
		disk_content = f:read("*a") or ""
		f:close()
	end

	-- Only store as pending if it differs from disk
	if content ~= disk_content then
		M.pending_changes[path] = { content = content, client_id = client_id }
	else
		M.pending_changes[path] = nil
	end

	apply_buffer_changes(path, content)
	broadcast_update(path, content, client_id)
end

-- Helper to parse "CMD:JSON_PAYLOAD"
local function parse_msg(line)
	local cmd, payload_str = line:match("^([^:]+):(.*)")
	if not cmd then
		return nil, nil
	end
	local ok, payload = pcall(vim.json.decode, payload_str)
	if not ok then
		return nil, nil
	end
	return cmd, payload
end

-- Handles host commands
-- LIST_REQ - Sends list of files to client
-- GET_REQ - Send spesific file to client
-- UPDATE - Get changes from client and brodcast to others
local function process_host_msg(client_id, line)
	local cmd, payload = parse_msg(line)
	if not cmd then
		return
	end

	if cmd == "LIST_REQ" then
		handle_list_req(client_id)
	elseif cmd == "GET_REQ" then
		handle_get_req(client_id, payload)
	elseif cmd == "UPDATE" then
		handle_update(client_id, payload)
	end
end

-- Handles client commands (from host)
-- FILE_LIST - Contains host file listed (returned after LIST_REQ)
-- FILE - Contains file (returned after GET_REQ)
-- UPDATE - Contains new changed buffer changes 
local function process_client_msg(line)
	local cmd, payload = parse_msg(line)
	if not cmd then
		return
	end

	if cmd == "FILE_LIST" then
		-- TODO: Get telescope out of here
		pickers
			.new(themes.get_ivy({
				prompt_title = "Remote Files",
				finder = finders.new_table({ results = payload }),
				sorter = conf.generic_sorter({}),
				attach_mappings = function(prompt_bufnr, map)
					-- On select request spesified file from host and open it
					actions.select_default:replace(function()
						actions.close(prompt_bufnr)
						local selection = action_state.get_selected_entry()
						if selection then
							send_json("GET_REQ", { path = selection[1] })
						end
					end)
					return true
				end,
			}))
			:find()
	elseif cmd == "FILE" then
		local path = payload.path
		local content = payload.content

		local buf = vim.fn.bufnr(path)
		if buf == -1 then
			buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, path)
		end

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
		vim.api.nvim_set_current_buf(buf)
		-- Acwrite so we can handle writes manually and ignore them
		vim.bo[buf].buftype = "acwrite"

		-- Set filetype for syntax highlighting
		local ft = vim.filetype.match({ filename = path })
		if ft then
			vim.bo[buf].filetype = ft
		end

		-- Attach listeners for realtime updates
		attach_buffer_listeners(buf, path, function(p, c)
			send_json("UPDATE", { path = p, content = c })
		end)

		-- Setup manual save to clear modified flag (updates are handled by listeners)
		-- Vim complains if we don't do this for acwrite buffers
		vim.api.nvim_clear_autocmds({ event = "BufWriteCmd", buffer = buf })
		vim.api.nvim_create_autocmd("BufWriteCmd", {
			buffer = buf,
			callback = function()
				vim.bo[buf].modified = false
			end,
		})
	elseif cmd == "UPDATE" then
		local path = payload.path
		local content = payload.content
		apply_buffer_changes(path, content)
	end
end

-- Creates a closure that buffers chunks and emits lines
-- For streamed TCP data
local function create_line_handler(callback)
	local buffer = ""
	return function(chunk)
		buffer = buffer .. chunk
		while true do
			local line_end = buffer:find("\n")
			if not line_end then
				break
			end
			local line = buffer:sub(1, line_end - 1)
			buffer = buffer:sub(line_end + 1)
			callback(line)
		end
	end
end

local function connect(host, callback)
	M.client = uv.new_tcp()
	M.client:connect(host, PORT, function(err)
		if err then
			vim.schedule(function()
				print(err)
				if M.client then
					M.client:close()
					M.client = nil
				end
			end)
			return
		end

		-- State for host parser
		local last_client_id = nil

		local host_handler = create_line_handler(function(line)
			local client_id_str, rest = line:match("^(%d+):(.*)")
			local client_id = client_id_str and tonumber(client_id_str)

			if client_id then
				last_client_id = client_id
			else
				client_id = last_client_id
				rest = line
			end

			if client_id then
				if client_id == 0 then
					local action, id_str = rest:match("^(%w+):(%d+)")
					if action == "CONNECT" then
						M.connected_clients[tonumber(id_str)] = true
					elseif action == "DISCONNECT" then
						M.connected_clients[tonumber(id_str)] = nil
					end
				else
					vim.schedule(function()
						process_host_msg(client_id, rest)
					end)
				end
			end
		end)

		local client_handler = create_line_handler(function(line)
			vim.schedule(function()
				process_client_msg(line)
			end)
		end)

		M.client:read_start(function(err, chunk)
			if err then
				if M.client then
					M.client:close()
					M.client = nil
				end
				M.role = nil
				return
			end
			if chunk then
				if M.role == "HOST" then
					host_handler(chunk)
				else
					client_handler(chunk)
				end
			end
		end)

		vim.schedule(callback)
	end)
end

local server_handle = nil
local server_sockets = {}
local next_client_id = 1
local host_id = nil

local function stop_server()
	if server_handle then
		server_handle:close()
		server_handle = nil
	end
	for _, client in pairs(server_sockets) do
		if not client:is_closing() then
			client:close()
		end
	end
	server_sockets = {}
	host_id = nil
	next_client_id = 1
end

local function start_tcp_server()
	server_handle = uv.new_tcp()
	server_handle:bind("0.0.0.0", PORT)
	server_handle:listen(128, function(err)
		if err then
			print("Server listen error: " .. err)
			return
		end
		local client = uv.new_tcp()
		server_handle:accept(client)

		local id = next_client_id
		next_client_id = next_client_id + 1
		server_sockets[id] = client

		if not host_id then
			host_id = id
		else
			if server_sockets[host_id] then
				server_sockets[host_id]:write("0:CONNECT:" .. id .. "\n")
			end
		end

		local buffer = ""
		client:read_start(function(read_err, chunk)
			if read_err or not chunk then
				client:close()
				server_sockets[id] = nil
				if id == host_id then
					host_id = nil
				else
					if host_id and server_sockets[host_id] then
						server_sockets[host_id]:write("0:DISCONNECT:" .. id .. "\n")
					end
				end
				return
			end

			buffer = buffer .. chunk
			while true do
				local line_end = buffer:find("\n")
				if not line_end then
					break
				end
				local line = buffer:sub(1, line_end - 1)
				buffer = buffer:sub(line_end + 1)

				if id == host_id then
					local target_id_str, data = line:match("^(%d+):(.*)")
					if target_id_str then
						local target_id = tonumber(target_id_str)
						if server_sockets[target_id] then
							server_sockets[target_id]:write(data .. "\n")
						end
					end
				elseif host_id and server_sockets[host_id] then
					server_sockets[host_id]:write(id .. ":" .. line .. "\n")
				end
			end
		end)
	end)
end

function M.server_start()
	if M.client or server_handle then
		print("Already connected or server running")
		return
	end

	start_tcp_server()

	-- Kill server on exit
	vim.api.nvim_create_autocmd("VimLeave", {
		callback = function()
			stop_server()
		end,
	})

	vim.defer_fn(function()
		connect("127.0.0.1", function()
			M.role = "HOST"
			print("Server is ready")

			-- Auto-share opened buffers
			vim.api.nvim_create_autocmd("BufReadPost", {
				pattern = "*",
				callback = function(ev)
					local abs_path = ev.file
					local rel_path = vim.fn.fnamemodify(abs_path, ":.")

					-- Check for pending changes
					local pending = M.pending_changes[rel_path]
					if pending then
						vim.schedule(function()
							apply_buffer_changes(abs_path, pending.content)
							print("Applied pending changes from client " .. pending.client_id)
						end)
					end

					attach_buffer_listeners(ev.buf, rel_path, function(p, c)
						broadcast_update(p, c, nil)
					end)
				end,
			})

			-- Clear pending changes on save
			vim.api.nvim_create_autocmd("BufWritePost", {
				pattern = "*",
				callback = function(ev)
					local abs_path = ev.file
					local rel_path = vim.fn.fnamemodify(abs_path, ":.")
					if M.pending_changes[rel_path] then
						M.pending_changes[rel_path] = nil
					end
				end,
			})

			-- Share current buffer
			local current_buf = vim.api.nvim_get_current_buf()
			local current_name = vim.api.nvim_buf_get_name(current_buf)
			if current_name ~= "" then
				local rel_path = vim.fn.fnamemodify(current_name, ":.")
				attach_buffer_listeners(current_buf, rel_path, function(p, c)
					broadcast_update(p, c, nil)
				end)
			end
		end)
	end, 500)
end

function M.server_join(ip)
	if M.client then
		print("Already connected or server running")
		return
	end

	local host = ip or "127.0.0.1"
	connect(host, function()
		M.role = "CLIENT"
		print("Joined the server at " .. host)

		-- Prevent opening netrw, and instead fetch remote files
		vim.api.nvim_create_autocmd("FileType", {
			pattern = "netrw",
			callback = function()
				if M.role == "CLIENT" then
					-- Close netrw buffer
					local buf = vim.api.nvim_get_current_buf()
					vim.schedule(function()
						pcall(vim.api.nvim_buf_delete, buf, { force = true })
						M.remote_files()
					end)
				end
			end,
		})
	end)
end

function M.remote_files()
	if M.role ~= "CLIENT" then
		print("Not connected as client")
		return
	end
	send_json("LIST_REQ", {})
end

function M.review_changes()
	local items = {}
	for path, _ in pairs(M.pending_changes) do
		table.insert(items, path)
	end

	if M.role ~= "HOST" then
		print("Only the host can review changes")
		return
	end

	if #items == 0 then
		print("No pending changes")
		return
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
					local data = M.pending_changes[path]
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
							-- If there is a diff, show it
							vim.api.nvim_buf_set_lines(
								self.state.bufnr,
								0,
								-1,
								false,
								vim.split(diff, "\n")
							)
							-- Filetype diff for syntax
							vim.bo[self.state.bufnr].filetype = "diff"
						else
							-- No diff, show the new content
							vim.api.nvim_buf_set_lines(
								self.state.bufnr,
								0,
								-1,
								false,
								vim.split(data.content, "\n")
							)
							-- Set filetype mainly for syntax and some plugins might use it
							local ft = vim.filetype.match({ filename = path })
							if ft then
								vim.bo[self.state.bufnr].filetype = ft
							end
						end
					end)
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				-- On enter (select), save the change and refresh the picker
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end

					local path = selection.value
					local data = M.pending_changes[path]

					if data then
						local f = io.open(path, "w")
						if f then
							f:write(data.content)
							f:close()
							print("Saved " .. path)
							M.pending_changes[path] = nil

							-- Refresh picker
							local current_picker = action_state.get_current_picker(prompt_bufnr)
							local new_items = {}
							for p, _ in pairs(M.pending_changes) do
								table.insert(new_items, p)
							end

							current_picker:refresh(
								finders.new_table({ results = new_items }),
								{ reset_prompt = false }
							)
						else
							print("Error saving " .. path)
						end
					end
				end)
				return true
			end,
		})
		:find()
end

vim.api.nvim_create_user_command("ServerStart", function()
	M.server_start()
end, {})

vim.api.nvim_create_user_command("ServerJoin", function(opts)
	M.server_join(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

vim.api.nvim_create_user_command("ReviewChanges", function()
	M.review_changes()
end, {})

vim.api.nvim_create_user_command("RemoteFiles", function()
	M.remote_files()
end, {})

return M
