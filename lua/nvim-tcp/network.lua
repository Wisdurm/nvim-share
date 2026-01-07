local uv = vim.uv
local M = {}

M.client = nil

-- Sends raw data over TCP
function M.send_raw(data)
	if M.client then
		M.client:write(data)
	end
end

-- Sends a json encoded message
function M.send_json(cmd, payload)
	local msg = vim.json.encode({ cmd = cmd, data = payload }) .. "\n"
	M.send_raw(msg)
end

-- Sends a message to a specific client (host only)
function M.send_to(client_id, cmd, payload)
	local msg = client_id .. ":" .. vim.json.encode({ cmd = cmd, data = payload }) .. "\n"
	M.send_raw(msg)
end

-- Creates a closure that buffers chunks and emits lines
-- For streamed TCP data
function M.create_line_handler(callback)
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

function M.connect(host, port, on_connect, on_data, on_error)
	M.client = uv.new_tcp()
	M.client:nodelay(true)
	M.client:connect(host, port, function(err)
		if err then
			if on_error then
				on_error(err)
			end
			return
		end

		M.client:read_start(function(err, chunk)
			if err then
				if M.client then
					M.client:close()
					M.client = nil
				end
				if on_error then
					on_error(err)
				end
				return
			end
			if chunk and on_data then
				on_data(chunk)
			end
		end)

		if on_connect then
			vim.schedule(on_connect)
		end
	end)
end

function M.disconnect()
	if M.client then
		M.client:close()
		M.client = nil
	end
end

return M
