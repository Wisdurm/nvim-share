local M = {}

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

return M