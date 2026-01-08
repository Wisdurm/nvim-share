local uv = vim.uv
local M = {}

M.socket = nil
M.clients = {} -- For server mode: id -> client_socket
M.next_id = 1

-- Line buffering wrapper, reads content from socket
local function create_reader(client, callback)
	local buffer = ""

	client:read_start(function(err, chunk)
		if err then
			print(err)
			client:close()
			return
		end

		if chunk then
			buffer = buffer .. chunk
			-- Process all complete lines in the buffer
			while true do
				local line, rest = buffer:match("(.-)\n(.*)")
				if line then
					callback(line)
					buffer = rest
				else
					break
				end
			end
		else
			-- No chunk means the client closed the connection
			client:close()
		end
	end)
end
-- Doesn't crash if invalid json
local function safe_json(str)
	local ok, res = pcall(vim.json.decode, str)
	return ok and res or nil
end

-- Writes command and payload to spesified socket
function M.send_to(id, cmd, payload)
	local msg = vim.json.encode({ cmd = cmd, data = payload })
	if M.clients[id] then
		M.clients[id]:write("0:" .. msg .. "\n") -- 0 indicates payload from host
	elseif M.socket then
		-- We are client sending to host, or host sending to specific client
		if M.clients[id] then
			M.clients[id]:write(msg .. "\n")
		end
	end
end

function M.send_json(cmd, payload)
	local msg = vim.json.encode({ cmd = cmd, data = payload }) .. "\n"
	if M.socket then
		M.socket:write(msg)
	end
end

-- Start a Host
function M.start_server(port, on_msg, on_event)
	M.socket = uv.new_tcp()
	M.socket:bind("0.0.0.0", port)
	M.socket:listen(128, function(err)
		if err then
			return print("Listen error: " .. err)
		end

		local client = uv.new_tcp()
		M.socket:accept(client)

		local id = M.next_id
		M.next_id = M.next_id + 1
		M.clients[id] = client

		if on_event then
			on_event("CONNECT", id)
		end

		create_reader(client, function(line)
			-- Host routing
			local target, payload = line:match("^(%d+):(.*)")
			if target then
				-- If p2p later
			else
				-- Message for host
				local decoded = safe_json(line)
				if decoded then
					on_msg(id, decoded.cmd, decoded.data)
				end
			end
		end)
	end)
end

-- Join as client
function M.connect(host, port, on_msg)
	M.socket = uv.new_tcp()
	M.socket:connect(host, port, function(err)
		if err then
			return print("Connect error")
		end

		create_reader(M.socket, function(line)
			-- Client might receive "0:JSON" (from host) or just json
			local _, body = line:match("^(%d+):(.*)")
			local decoded = safe_json(body or line)
			if decoded then
				on_msg(decoded.cmd, decoded.data)
			end
		end)
	end)
end

function M.close()
	if M.socket then
		M.socket:close()
	end
	for _, c in pairs(M.clients) do
		c:close()
	end
	M.clients = {}
end

return M
