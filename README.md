Dirty and unreliable Neovim plugin for realtime buffer sharing using TCP

## Config

```lua
require("nvim-tcp").setup({
    -- The port to run the server on
	port = 8080,            
    -- Whether to sync the host's files on your computer
	sync_to_disk = false,   
    -- Your name visible to other clients
	name = "Jaakko",        
	cursor_name = {
        -- The position of names assigned to cursors.
        -- Options are:
            -- follow: shows next to the cursor
            -- eol: right after eol character
            -- eol_right_align: display right aligned in the window unless the virtual text is longer than the space available. If the virtual text is too long, it is truncated to fit in the window after the EOL character. If the line is wrapped, the virtual text is shown after the end of the line rather than the previous screen line.
            -- overlay: display over the specified column, without shifting the underlying text.
            -- right_align: display right aligned in the window.
            -- inline: display at the specified column, and shift the buffer text to the right as needed. 
		pos = "follow",
        -- The highlight group for the cursor name
		hl_group = "Cursor"
	}
})

```
