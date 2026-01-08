local session = require("nvim-tcp.session")

local M = {}

function M.setup(opts)
	-- Allow user to define config in setup, similarly to other plugins
	session.config = vim.tbl_deep_extend("force", session.config, opts or {})

	-- Starts server as "HOST"
	vim.api.nvim_create_user_command("TcpHost", function()
		session.start_host()
	end, {})

	-- Joins server as "CLIENT", default to localhost if no IP is provided
	vim.api.nvim_create_user_command("TcpJoin", function(args)
		local ip = args.args ~= "" and args.args or "127.0.0.1"
		session.join_server(ip)
	end, { nargs = "?" })

	-- Opens a menu buffer that contains changes not yet applied to host's actual files
	vim.api.nvim_create_user_command("TcpReview", function()
		session.review_pending()
	end, {})

	-- Opens a menu buffer that contains host's files
	vim.api.nvim_create_user_command("TcpExplore", function()
		session.list_remote_files()
	end, {})

	-- Stop session on ecit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			session.stop()
		end,
	})
end

return M
