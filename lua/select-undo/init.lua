local M = {}

function M.setup(opts)
   opts = opts or {}
  vim.keymap.set("n", "<C-s>", function()
    local line = vim.api.nvim_get_current_line()
    print("Selected line: " .. line)
  end
  
  )
  vim.keymap.set("n","<C-s>u",function()
    local line_nr = vim.api.nvim_win_get_cursor(0)[1]
    vim.cmd(line_nr .. 'undo')
  end
  )
     
   vim.keymap.set("n", "<Leader>h", function()
      if opts.name then
         print("hello, " .. opts.name)
      else
         print("hello")
      end
   end)
end

return M
