local buffer_utils = require("nvim-tcp.buffer")
local transport = require("nvim-tcp.transport")
local ui = require("nvim-tcp.ui")

local M = {}

-- Default config
M.config = {
	port = 8080,
	sync_to_disk = false,
	name = "Jaakko",
	cursor_name = {
		pos = "right_align",
		hl_group = "Cursor",
	},
}

M.state = {
	role = nil, -- "HOST" or "CLIENT"
	clients = {}, -- ID -> Metadata, like name
	pending_changes = {}, -- Path -> { content, client_id }
	snapshot = {}, -- Path -> Last known clean content
	cursor_namespace = vim.api.nvim_create_namespace("share-cursor"), -- Not sure where else
}

-- About snapshots:
-- Initial load: Snapshot "Pullea pomeranian" - Pending nil (clean)
-- Client edits: Snapshot "Pullea pomeranian" - Pending "Paksu turkkinen pomeranian" (dirty, in review)
-- Client undos: Snapshot "Pullea pomeranian" - Pending nil | (clean)
-- Host saves: Snapshot "Paksu turkkinen pomeranian" - Pending nil (clean, new baseline)
-- Snapshots are source of truth

-- Sends file path and content to every socketm other than sender
local function broadcast(path, content, sender_id)
	for id, _ in pairs(M.state.clients) do
		if id ~= sender_id then
			transport.send_to(id, "UPDATE", { path = path, content = content })
		end
	end
end

-- Sends arbitrary data to every client other than sender
local function broadcast_data(cmd, payload, sender_id)
	for id, _ in pairs(M.state.clients) do
		if id ~= sender_id then
			transport.send_to(id, cmd, payload)
		end
	end
end

local handlers = {}

-- Event to host by cliet to ask for filetree to send to client that requested it
function handlers.LIST_REQ(client_id)
	local files = buffer_utils.scan_dir()
	transport.send_to(client_id, "FILE_LIST", files)
end

-- Event received by client after LIST_REQ that contains host's filetree
function handlers.FILE_LIST(_, payload)
	vim.schedule(function()
		ui.show_remote_files(payload, function(path)
			transport.send_json("GET_REQ", { path = path })
		end)
	end)
end

-- Event requived by host from client. Host responds with asked file content and path
function handlers.GET_REQ(client_id, payload)
	vim.schedule(function()
		local path = payload.path
		-- Priority: current buffer > pending > disk
		local content = buffer_utils.get_buffer_content(path)
			or (M.state.pending_changes[path] and M.state.pending_changes[path].content)
			or buffer_utils.read_file(path)

		if content then
			transport.send_to(client_id, "FILE_RES", { path = path, content = content })
		end
	end)
end

-- Event received by client from host that contains asked file content
function handlers.FILE_RES(_, payload)
	local path = payload.path
	local content = payload.content

	if M.config.sync_to_disk then
		buffer_utils.write_file(path, content)
	end

	vim.schedule(function()
		-- Create a scratch buffer for client to put file contents to
		local buf = buffer_utils.create_scratch_buf(path, content)

		-- Add listener for cursor movement
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			desc = "Notifies host when cursor is moved",
			callback = function()
				local current_id = 1
				local pos = vim.api.nvim_win_get_cursor(0)
				data = {
					path = path,
					position = pos,
					id = nil,
					name = nil,
					-- id and names are tracked by host so they will get added later
					-- when this message passes through the host
				}
				-- Broadcast to host, who will inform others
				transport.send_json("CLIENTCURSOR", data)
			end,
		})

		-- Attach listener for subsequent edits, if so send update to host that contains updated content
		buffer_utils.attach_listener(buf, function(p, c)
			transport.send_json("UPDATE", { path = p, content = c })
			if M.config.sync_to_disk then
				buffer_utils.write_file(p, c)
			end
		end)
	end)
end

-- Event received by host that contains updated content, this is forwarded to other clients
function handlers.UPDATE(client_id, payload)
	local path = payload.path
	local content = payload.content

	vim.schedule(function()
		-- Apply to live buffer if open
		local applied_live = buffer_utils.apply_patch(path, content)

		-- Build full text for caching/saving
		local full_text = applied_live and buffer_utils.get_buffer_content(path)
			or buffer_utils.reconstruct_text(path, content, M.state.pending_changes[path])

		-- Update snapshot (cache)
		if full_text then
			-- Init snapshot if missing
			if not M.state.snapshot[path] then
				M.state.snapshot[path] = buffer_utils.read_file(path) or ""
			end

			-- Check for drift/dirty state
			local clean_state = M.state.snapshot[path]
			-- Normalize newlines
			if full_text:sub(-1) ~= "\n" then
				full_text = full_text .. "\n"
			end
			if clean_state:sub(-1) ~= "\n" then
				clean_state = clean_state .. "\n"
			end

			if full_text ~= clean_state then
				M.state.pending_changes[path] = { content = full_text, client_id = client_id }
			else
				M.state.pending_changes[path] = nil
			end
		end

		-- Forward changes to every client except the one who made the changes
		broadcast(path, content, client_id)
	end)
end

-- Event received by host that contains client name
function handlers.NAME(client_id, payload)
	M.state.clients[client_id] = { name = payload.name }
	local message
	if math.random(100) <= 5 then
		message = "Wild " .. payload.name .. " appeared!"
	else
		message = payload.name .. " joined"
	end

	print(message)
end

-- Event recieved by host that informs of client cursor position
function handlers.CLIENTCURSOR(client_id, payload)
	-- Add id from client_id
	payload.id = client_id
	-- Add name stored by host to data
	payload.name = M.state.clients[client_id].name
	-- Broadcast data to every client
	broadcast_data("CURSOR", payload, client_id)
	-- Manually run CURSOR handler so host can see cursor as well
	handlers.CURSOR(client_id, payload)
end

-- Event recieved by host or client that contains cursor position
function handlers.CURSOR(client_id, payload)
	local row = payload.position[1] - 1
	local col = payload.position[2]
	local name = payload.name
	local path = payload.path
	local mark_id = payload.id + 1 -- host id is 0 which is not allowed :)

	-- If in currently opened buffer
	if path == vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.") then
		local options = {
			id = mark_id,
			end_col = col + 1,
			hl_group = "TermCursor",
			virt_text = {
				{ name, M.config.cursor_name.hl_group }, -- Cursor for visibility
			},
			strict = false,
		}
		-- Position config
		if M.config.cursor_name.pos == "follow" then
			options.virt_text_win_col = col + 2
		else
			options.virt_text_pos = M.config.cursor_name.pos
		end

		vim.api.nvim_buf_set_extmark(0, M.state.cursor_namespace, row, col, options)
	else -- Try to delete just in case we changed files halfway through
		vim.api.nvim_buf_del_extmark(0, M.state.cursor_namespace, mark_id)
	end
end

-- Executes correct handler above based on server message
function M.process_msg(client_id, cmd, payload)
	if handlers[cmd] then
		handlers[cmd](client_id, payload)
	end
end

function M.start_host()
	if M.state.role then
		return print("Already running")
	end

	transport.start_server(M.config.port, function(client_id, cmd, data)
		M.process_msg(client_id, cmd, data)
	end, function(event, id)
		if event == "CONNECT" then
			-- TODO: use config
			M.state.clients[id] = { name = "Host" }
		elseif event == "DISCONNECT" then
			M.state.clients[id] = nil
		end
	end)

	M.state.role = "HOST"
	print("Server started on port " .. M.config.port)

	-- Auto share local buffers on open
	vim.api.nvim_create_autocmd("BufReadPost", {
		callback = function(ev)
			local rel = vim.fn.fnamemodify(ev.file, ":.")

			-- If we have pending changes for this file, apply them now
			local pending = M.state.pending_changes[rel]
			if pending then
				vim.schedule(function()
					buffer_utils.apply_patch(ev.file, pending.content)
					print("Applied pending changes for " .. rel .. "to current buffer")
				end)
			end

			-- Attach listeners
			buffer_utils.attach_listener(ev.buf, function(p, c)
				broadcast(p, c, nil)
			end)

			-- On save, update the snapshot (clean state)
			vim.api.nvim_create_autocmd("BufWritePost", {
				buffer = ev.buf,
				callback = function()
					local txt = buffer_utils.get_buffer_content(rel) or ""
					M.state.snapshot[rel] = txt .. "\n"
					M.state.pending_changes[rel] = nil
				end,
			})
		end,
	})
	-- Track mouse movement and inform all clients
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		desc = "Notifies clients when cursor is moved",
		callback = function()
			local pos = vim.api.nvim_win_get_cursor(0)
			local relative_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
			data = {
				path = relative_path,
				position = pos,
				id = 0, -- Host is id 0 (essentially)
				name = "host",
			}
			-- Broadcast to all clients
			broadcast_data("CURSOR", data, 0)
		end,
	})
end

function M.join_server(ip)
	if M.state.role then
		return print("Already joined")
	end

	transport.connect(ip, M.config.port, function(cmd, data)
		M.process_msg(nil, cmd, data)
	end)

	M.state.role = "CLIENT"
	transport.send_json("NAME", { name = M.config.name })
	print("Connected to " .. ip)
end

function M.list_remote_files()
	if M.state.role ~= "CLIENT" then
		return print("Only clients can request files")
	end
	transport.send_json("LIST_REQ", {})
end

function M.review_pending()
	if M.state.role ~= "HOST" then
		return print("Host only")
	end
	ui.review_changes(M.state.pending_changes, function(path, content)
		buffer_utils.write_file(path, content)
		M.state.pending_changes[path] = nil
		M.state.snapshot[path] = content
		print("Saved " .. path)
	end)
end

function M.stop()
	transport.close()
	M.state.role = nil
end

return M
