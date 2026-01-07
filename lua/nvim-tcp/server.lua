local uv = vim.uv
local M = {}

M.server_handle = nil
M.server_sockets = {}
M.next_client_id = 1
M.host_id = nil

function M.stop()
	if M.server_handle then
		M.server_handle:close()
		M.server_handle = nil
	end
	for _, client in pairs(M.server_sockets) do
		if not client:is_closing() then
			client:close()
		end
	end
	M.server_sockets = {}
	M.host_id = nil
	M.next_client_id = 1
end

-- Create a TCP server with libuv
-- https://docs.libuv.org/en/v1.x/tcp.html
-- https://neovim.io/doc/user/luvref.html#uv_tcp_t
function M.start(port)
	M.server_handle = uv.new_tcp()
	M.server_handle:nodelay(true) -- TCP_NODELAY
	M.server_handle:bind("0.0.0.0", port)

	M.server_handle:listen(128, function(err)
		if err then
			print("Failed to listen socket: " .. err)
			return
		end

		-- Accept new client connection
		local client = uv.new_tcp()
		client:nodelay(true)
		M.server_handle:accept(client)

		-- Create unique id for client
		local id = M.next_client_id
		M.next_client_id = M.next_client_id + 1
		M.server_sockets[id] = client

		-- If no host, make this client the host
		if not M.host_id then
			M.host_id = id
		else
			if M.server_sockets[M.host_id] then
				local msg = { type = "CONNECT", id = id }
				M.server_sockets[M.host_id]:write("0:" .. vim.json.encode(msg) .. "\n")
			end
		end

		local buffer = ""
		client:read_start(function(read_err, chunk)
			-- If error or disconnected remove client
			if read_err or not chunk then
				client:close()
				M.server_sockets[id] = nil
				if id == M.host_id then
					M.host_id = nil
				else
					if M.host_id and M.server_sockets[M.host_id] then
						local msg = { type = "DISCONNECT", id = id }
						M.server_sockets[M.host_id]:write("0:" .. vim.json.encode(msg) .. "\n")
					end
				end
				return
			end

			buffer = buffer .. chunk
			while true do
				-- Make sure to use full lines only, TCP streams
				local line_end = buffer:find("\n")
				if not line_end then
					break
				end

				-- Extract line
				local line = buffer:sub(1, line_end - 1)
				buffer = buffer:sub(line_end + 1)

				-- If host, route to target client
				-- If client, route to host
				if id == M.host_id then
					local target_id_str, data = line:match("^(%d+):(.*)")
					if target_id_str then
						local target_id = tonumber(target_id_str)
						if M.server_sockets[target_id] then
							M.server_sockets[target_id]:write(data .. "\n")
						end
					end
				elseif M.host_id and M.server_sockets[M.host_id] then
					M.server_sockets[M.host_id]:write(id .. ":" .. line .. "\n")
				end
			end
		end)
	end)
end

return M
