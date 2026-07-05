# select-undo.nvim

## Overview

select-undo is a Neovim plugin that enhances undo functionality by allowing users to undo changes selectively. Unlike the default undo command, which reverts changes sequentially across the whole buffer, select-undo enables users to undo specific lines or partial selections without affecting the rest of the file.

For example: if you edit line 10 and then line 50, native undo forces you to revert line 50 first. With select-undo you can select line 10, press `gu`, and revert only that change - the edit on line 50 stays.

## Features

- **Selective Line Undo** (`gu`): revert the newest change within the selected lines; press again to step further back, one change at a time. Safe for sloppy selections - lines whose changes are older stay untouched.
- **Selective Sweep** (`gU`): revert the last change of *every* selected line in one press, even when the lines were edited at different times.
- **Partial Undo** (`gC`): revert only the selected characters within a line.
- **Undo-friendly**: A selective undo is a single regular edit, so native `u` reverts it in one step.
- **Persistent Undo**: Enables `undofile` so undo history survives closing Neovim.
- **Customizable Keybindings**: Default mappings are provided, but users can configure their own.

<!--https://github.com/user-attachments/assets/1ffd1790-94e5-4733-91b0-f4bcbe3e0adf-->


https://github.com/user-attachments/assets/ce45d5af-971d-4fef-8a31-4d9fbf458019


https://github.com/user-attachments/assets/9075f616-cd54-4760-b563-df258534c0cf


https://github.com/user-attachments/assets/e216aa62-75e9-44b1-897a-32173d8e2407



## Installation

**Using lazy.nvim**

```lua
{
  "SunnyTamang/select-undo.nvim",
  opts = {},
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

**Undo entire lines, one change at a time**

1. Select one or more lines in Visual Mode (`v` or `V`).
2. Press `gu` to revert the newest change that touched those lines.
3. Press `gu` again to step the same selection one change further back.

**Undo every selected line's last change at once**

1. Select the lines you edited in Visual Mode.
2. Press `gU` to revert the last change of each selected line in one press.
   Use this when you deliberately want everything in the selection undone -
   it will also revert selected lines you edited earlier and consider "done".

**Undo a partial selection**

1. Select part of a line in Visual Mode (`v`).
2. Press `gC` to revert only the selected characters; changes elsewhere on the line are kept.

**Customizing mappings**

The defaults `gu`/`gU` shadow Neovim's built-in visual-mode lowercase/uppercase operators. If you use those, remap the plugin to any keys you like - the built-ins come back automatically:

```lua
require("select-undo").setup({
  line_mapping = "zu",     -- Step undo mapping (frees gu for lowercasing)
  sweep_mapping = "zU",    -- Sweep undo mapping (frees gU for uppercasing)
  partial_mapping = "zcu", -- Partial undo mapping
})
```

Or disable all default mappings and bind the commands yourself:

```lua
require("select-undo").setup({ mapping = false })
vim.keymap.set("x", "<leader>u", ":SelectUndoLine<CR>", { silent = true })
```

## Configuration

**Default settings**

```lua
require("select-undo").setup({
  persistent_undo = true,  -- Enables persistent undo history (undofile)
  mapping = true,          -- Enables default keybindings
  line_mapping = "gu",     -- Step: undo the newest change in the selection
  sweep_mapping = "gU",    -- Sweep: undo every selected line's last change
  partial_mapping = "gC",  -- Undo for selected characters
  max_history = 100,       -- Undo states searched backward per press
})
```

## Limitations

- Partial (character-wise) undo works within a single line; multi-line character selections fall back to line-level undo.
- If the only change touching a character selection rewrote the whole line, `gC` refuses and suggests `gu` instead.
- Stepping back past a line's creation deletes the line (its oldest recorded state is "not there yet"); native `u` restores it in one step.
- Restoring deleted content may expand to the whole change so the result stays coherent, but a revert never deletes lines outside your selection.

## Development

Run the test suite from the repository root:

```sh
nvim --headless -u tests/minimal_init.lua -l tests/run.lua
```

## Contributing

Feel free to open issues or pull requests to improve the plugin.

## License

This project is licensed under the MIT License.
