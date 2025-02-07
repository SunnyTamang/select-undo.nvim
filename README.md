# select-undo.nvim

## Overview

select-undo is a Neovim plugin that enhances undo functionality by allowing users to undo changes selectively. Unlike the default undo command, which reverts changes sequentially, Select-Undo enables users to undo specific lines or partial selections without affecting the rest of the file.



## Features
	•	Persistent Undo: Ensures that undo history persists even after closing Neovim.
	•	Selective Line Undo: Undo only the changes within selected lines (gu).
	•	Partial Undo: Undo changes within a visual selection (gu).
	•	Visual Mode Integration: Works seamlessly with Neovim’s visual mode for intuitive selection-based undo.
	•	Customizable Keybindings: Default mappings are provided, but users can configure their own.
	

**This is still in development phase**

## Things that dont work properly

- If added a line in between two lines and reverted the line value is replaced by the very next line.
- If buffer is closed, undo doesnot work.

https://github.com/user-attachments/assets/1ffd1790-94e5-4733-91b0-f4bcbe3e0adf




## Installation

**Using lazy.nvim**

```lua
{
  "SunnyTamang/select-undo.nvim",
  config = function()
    require("select-undo").setup()
  end
}
```

**Using packer.nvim**

```lua
use {
  "SunnyTamang/select-undo.nvim",
  config = function()
    require("select-undo").setup()
  end
}
```

**Using vim-plug**

```vim
Plug 'SunnyTamang/select-undo.nvim'
lua require("select-undo").setup()
```

## Usage

**Undo Entire Lines**

	1.	Select multiple lines in Visual Mode (V or Shift + V).
	2.	Press gu to undo changes within the selected lines.

**Undo a Partial Selection**

	1.	Select part of a line in Visual Mode (v).
	2.	Press gu to undo only the selected portion.

**Undo a Specific Line**

	1.	Move to the line you want to undo.
	2.	Press gu to undo that specific line.

**Customizing Mappings**

You can override the default keybindings in the setup function:

```lua
require("select-undo").setup({
  line_mapping = "gU",    -- Change line undo mapping
  partial_mapping = "gCp" -- Change partial undo mapping
})
```

## Configuration

**Default Settings**

```lua
require("select-undo").setup({
  persistent_undo = true,  -- Enables persistent undo history
  mapping = true,          -- Enables default keybindings
  line_mapping = "gu",     -- Undo for entire lines
  partial_mapping = "gcu"  -- Undo for selected characters -- Note: dont use this line as gu can also handle partial undo
})
```

## Contributing

Feel free to open issues or pull requests to improve the plugin. 🚀

## License

This project is licensed under the MIT License.
