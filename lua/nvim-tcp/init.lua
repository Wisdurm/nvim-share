local uv = vim.uv
local buffer = require("nvim-tcp.buffer")
local network = require("nvim-tcp.network")
local server = require("nvim-tcp.server")
local ui = require("nvim-tcp.ui")

local M = {}

M.role = nil
M.pending_changes = {}
M.connected_clients = {}

M.config = {
	sync_to_disk = false,
	sync_dir = nil,
}

-- Dummy function for lazy.nvim, later extended, maybe, possibly...
function M.setup(opts) end

local PORT = 8080

-- Broadcasts an update to all connected clients except exclude_id (usually the sender)
local function broadcast_update(path, content, exclude_id)
	for id, _ in pairs(M.connected_clients) do
		if id ~= exclude_id then
			network.send_to(id, "UPDATE", { path = path, content = content })
		end
	end
end

local function parse_msg(line)
	local ok, decoded = pcall(vim.json.decode, line)
	if not ok or type(decoded) ~= "table" then
		return nil, nil
	end
	return decoded.cmd, decoded.data
end

local function handle_list_req(client_id)
	local files = vim.fn.glob("**/*", false, true)
	local filtered = {}
	for _, f in ipairs(files) do
		if
			vim.fn.isdirectory(f) == 0
			and not f:match("^%.git")
			and not f:match("^build")
			and not f:match("^%.env")
			and not f:match("^%.venv")
		then
			table.insert(filtered, f)
		end
	end
	network.send_to(client_id, "FILE_LIST", filtered)
end

local function handle_get_req(client_id, payload)
	local path = payload.path
	local content = nil

	local buf = vim.fn.bufnr(path)
	if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		content = table.concat(lines, "\n")
	end

	if not content and M.pending_changes[path] then
		content = M.pending_changes[path].content
	end

	if not content then
		local f = io.open(path, "r")
		if f then
			content = f:read("*a")
			f:close()
		end
	end

	if content then
		network.send_to(client_id, "FILE", { path = path, content = content })
	end
end

local function handle_update(client_id, payload)
	local path = payload.path
	local content = payload.content

	local f = io.open(path, "r")
	local disk_content = ""
	if f then
		disk_content = f:read("*a") or ""
		f:close()
	end

	if content ~= disk_content then
		M.pending_changes[path] = { content = content, client_id = client_id }
	else
		M.pending_changes[path] = nil
	end

	buffer.apply_changes(path, content)
	broadcast_update(path, content, client_id)
end

-- Handles host commands
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
	elseif cmd == "NAME" then
		local name = payload.name
		M.connected_clients[client_id] = { name = name }
		print(name .. " connected, id: " .. client_id)
	end
end

local function write_to_disk(path, content)
	local full_path = path
	if M.config.sync_dir then
		full_path = M.config.sync_dir .. "/" .. path
	end

	local dir = vim.fn.fnamemodify(full_path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	if content:sub(-1) ~= "\n" then
		content = content .. "\n"
	end

	-- Write to a temp file and rename to avoid partial writes
	-- Also use libuv for async write to not block neovim
	-- 438 = 0666 read-write permissions
	local tmp_path = full_path .. ".tmp"
	uv.fs_open(tmp_path, "w", 438, function(err, fd)
		if err then
			return
		end
		uv.fs_write(fd, content, -1, function(err_write)
			uv.fs_close(fd)
			if not err_write then
				uv.fs_rename(tmp_path, full_path, function() end)
			end
		end)
	end)
end

local function handle_file_response(payload)
	local path = payload.path
	local content = payload.content

	if M.config.sync_to_disk then
		write_to_disk(path, content)
	end

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
	buffer.attach_listeners(buf, path, function(p, c)
		network.send_json("UPDATE", { path = p, content = c })
		if M.config.sync_to_disk then
			write_to_disk(p, c)
		end
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
end

-- Handles client commands (from host)
local function process_client_msg(line)
	local cmd, payload = parse_msg(line)
	if not cmd then
		return
	end

	if cmd == "FILE_LIST" then
		ui.show_remote_files(payload, function(path)
			network.send_json("GET_REQ", { path = path })
		end)
	elseif cmd == "FILE" then
		handle_file_response(payload)
	elseif cmd == "UPDATE" then
		local path = payload.path
		local content = payload.content
		buffer.apply_changes(path, content)
		if M.config.sync_to_disk then
			write_to_disk(path, content)
		end
	end
end

local function setup_connection(host, on_connect)
	-- State for host parser
	local last_client_id = nil

	local host_handler = network.create_line_handler(function(line)
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
				local ok, sys_msg = pcall(vim.json.decode, rest)
				if ok and type(sys_msg) == "table" then
					local action = sys_msg.type
					local id_str = tostring(sys_msg.id)

					if action == "CONNECT" then
						M.connected_clients[tonumber(id_str)] = { name = "Katti" }
						print("Client " .. id_str .. " connected")
					elseif action == "DISCONNECT" then
						local client = M.connected_clients[tonumber(id_str)]
						local name = client and client.name or id_str
						M.connected_clients[tonumber(id_str)] = nil
						print("Client " .. name .. " disconnected")
					end
				end
			else
				vim.schedule(function()
					process_host_msg(client_id, rest)
				end)
			end
		end
	end)

	local client_handler = network.create_line_handler(function(line)
		vim.schedule(function()
			process_client_msg(line)
		end)
	end)

	network.connect(host, PORT, on_connect, function(chunk)
		if M.role == "HOST" then
			host_handler(chunk)
		else
			client_handler(chunk)
		end
	end, function(err)
		vim.schedule(function()
			print(err)
			network.disconnect()
			M.role = nil
		end)
	end)
end

function M.server_start()
	if network.client or server.server_handle then
		print("Already connected or server running")
		return
	end

	server.start(PORT)

	-- Kill server on exit
	vim.api.nvim_create_autocmd("VimLeave", {
		callback = function()
			server.stop()
		end,
	})

	vim.defer_fn(function()
		setup_connection("127.0.0.1", function()
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
							buffer.apply_changes(abs_path, pending.content)
							print("Applied pending changes from client " .. pending.client_id)
						end)
					end

					buffer.attach_listeners(ev.buf, rel_path, function(p, c)
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
				buffer.attach_listeners(current_buf, rel_path, function(p, c)
					broadcast_update(p, c, nil)
				end)
			end
		end)
	end, 500)
end

function M.server_join(ip, sync_dir)
	if network.client then
		print("Already connected or server running")
		return
	end

	if sync_dir then
		M.config.sync_to_disk = true
		M.config.sync_dir = sync_dir
	end

	vim.ui.input({ prompt = "Enter your name: " }, function(name)
		if not name or name == "" then
			print("Name is required")
			return
		end

		local host = ip or "127.0.0.1"
		setup_connection(host, function()
			M.role = "CLIENT"
			print("Joined the server at " .. host)
			network.send_json("NAME", { name = name })

			local function hijack_func()
				M.remote_files()
			end
			-- Override netrw commands to open remote files instead
			-- TODO: Add sexplore and vexplore
			vim.api.nvim_create_user_command("Ex", hijack_func, { force = true })
			vim.api.nvim_create_user_command("Explore", hijack_func, { force = true })

			-- Hijack all regular dir bufs
			local hijack_group = vim.api.nvim_create_augroup("RemoteNetrwHijack", { clear = true })

			vim.api.nvim_create_autocmd("BufEnter", {
				group = hijack_group,
				pattern = "*",
				callback = function()
					if M.role ~= "CLIENT" then
						return
					end

					-- Check if it's a directory OR if Netrw managed to sneak in
					local is_dir = vim.fn.isdirectory(vim.fn.expand("%:p")) == 1
					local is_netrw = vim.bo.filetype == "netrw"

					if is_dir or is_netrw then
						local buf = vim.api.nvim_get_current_buf()

						vim.schedule(function()
							if vim.api.nvim_buf_is_valid(buf) then
								-- Force delete the buffer so we don't get "unsaved changes" warnings
								pcall(vim.api.nvim_buf_delete, buf, { force = true })
							end
							M.remote_files()
						end)
					end
				end,
			})

			-- If netrw is already open replace it
			vim.schedule(function()
				if vim.bo.filetype == "netrw" or vim.fn.isdirectory(vim.fn.expand("%:p")) == 1 then
					local buf = vim.api.nvim_get_current_buf()
					pcall(vim.api.nvim_buf_delete, buf, { force = true })
					M.remote_files()
				end
			end)
		end)
	end)
end

function M.remote_files()
	if M.role ~= "CLIENT" then
		print("Not connected as client")
		return
	end
	network.send_json("LIST_REQ", {})
end

function M.review_changes()
	if M.role ~= "HOST" then
		print("Only the host can review changes")
		return
	end

	local count = 0
	for _ in pairs(M.pending_changes) do
		count = count + 1
	end

	if count == 0 then
		print("No pending changes")
		return
	end

	ui.review_changes(M.pending_changes, function(path)
		local data = M.pending_changes[path]
		if data then
			local f = io.open(path, "w")
			if f then
				f:write(data.content)
				f:close()
				print("Saved " .. path)
				M.pending_changes[path] = nil
			else
				print("Error saving " .. path)
			end
		end
	end)
end

return M
