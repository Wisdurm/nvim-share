local uv = vim.uv
-- Telescope garbage
local pickers = require "telescope.pickers"
local finders = require "telescope.finders"
local conf = require("telescope.config").values
local themes = require "telescope.themes"
local actions = require "telescope.actions"

-- Opens menu containing all connections to the server
local function get_connections()
	local client = uv.new_tcp()
	-- TODO: ask for connection details
	client:connect("127.0.0.1", 8080, function(err)
		if err then
			vim.schedule(function()
				print("Connection error: " .. err)
			end)
			return
		end

		-- QUERY returns every connected socket
		client:write("QUERY", function(err)
			if err then
				vim.schedule(function()
					print("Write error: " .. err)
				end)
				return
			end

			client:read_start(function(err, chunk)
				if err then
					vim.schedule(function()
						print("Read error: " .. err)
					end)
					return
				end

				if chunk then
					client:close()
					vim.schedule(function()
						local lines = {}
						-- Cut the line on line endings (LF, CRLF) and append to table
						for s in chunk:gmatch("[^\r\n]+") do
							table.insert(lines, s)
						end

						-- Open telescope picker with ivy theme (opens at the bottom)
						-- TODO: Get telescope out of here, here for now out of laziness
						pickers.new(themes.get_ivy({
							prompt_title = "Connections",
							finder = finders.new_table {
								results = lines
							},
							sorter = conf.generic_sorter({}),
							attach_mappings = function(prompt_bufnr, map)
								actions.select_default:replace(function()
									-- Do nothing
								end)
								return true
							end,
						})):find()
					end)
				end
			end)
		end)
	end)
end

vim.api.nvim_create_user_command("ViewConnections", function()
	get_connections()
end, {})

