-- Main plugin module
local M = {}

-- Enable persistent undo for current buffer
local function setup_buffer_undo()
    -- Create undo directory if it doesn't exist
    local undodir = vim.fn.stdpath("data") .. "/undo"
    if vim.fn.isdirectory(undodir) == 0 then
        vim.fn.mkdir(undodir, "p")
    end
    
    -- Set undofile and undodir for current buffer only
    vim.bo.undofile = true
    -- We still need to set undodir globally as it's not buffer-local
    vim.opt.undodir = undodir
end

-- Create an autocommand to enable undo for new buffers
local function create_undo_autocmd()
    local group = vim.api.nvim_create_augroup('SelectUndoGroup', { clear = true })
    vim.api.nvim_create_autocmd('BufReadPost', {
        group = group,
        pattern = '*',
        callback = function()
            -- Only enable for normal files
            if vim.bo.buftype == '' then
                setup_buffer_undo()
            end
        end,
        desc = 'Enable persistent undo for new buffers'
    })
end

-- Store original text for comparison
local function get_lines(start_line, end_line)
    return vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
end

-- Get visual selection range with column information
local function get_visual_selection()
    local _, start_line, start_col, _ = unpack(vim.fn.getpos("'<"))
    local _, end_line, end_col, _ = unpack(vim.fn.getpos("'>"))
    -- Convert from 1-based to 0-based indexing
    start_col = start_col - 1
    end_col = end_col - 1
    return start_line, end_line, start_col, end_col
end

-- Get line content with column ranges
local function get_line_content(line_nr, start_col, end_col, original_text)
    local line = vim.api.nvim_buf_get_lines(0, line_nr - 1, line_nr, false)[1]
    if not line then return "", "" end
    
    -- If no column ranges provided, return full line
    if not start_col then return line, "" end
    
    -- Get parts of the line
    local before = start_col > 0 and line:sub(1, start_col) or ""
    local after = start_col + #original_text < #line and line:sub(start_col + #original_text + 1) or ""
    return before, after
end

-- Main function to perform selective undo
function M.undo_selection(mode)
    -- Get visual selection range
    local start_line, end_line, start_col, end_col = get_visual_selection()
    
    -- Get undo tree
    local undo_tree = vim.fn.undotree()
    if not undo_tree.entries or #undo_tree.entries == 0 then
        return
    end
    
    -- Store current state
    local current_seq = undo_tree.seq_cur
    
    -- Function to find word boundaries in a line
    local function find_word_boundaries(line, start_pos, end_pos)
        -- Find word start
        local word_start = start_pos
        while word_start > 0 and line:sub(word_start, word_start):match("[%w_]") do
            word_start = word_start - 1
        end
        word_start = word_start + 1
        
        -- Find word end
        local word_end = end_pos
        while word_end <= #line and line:sub(word_end, word_end):match("[%w_]") do
            word_end = word_end + 1
        end
        word_end = word_end - 1
        
        return word_start, word_end
    end
    
    if mode == 'partial' then
        -- Get current line and selection
        local current_line = vim.api.nvim_buf_get_lines(0, start_line - 1, start_line, false)[1]
        if not current_line then return end
        
        -- Store original state
        local original_state = {
            lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
            seq = current_seq
        }
        
        -- Find word boundaries for current selection
        local word_start, word_end = find_word_boundaries(current_line, start_col + 1, end_col)
        local selected_text = current_line:sub(word_start, word_end)
        
        -- Variables to track states
        local best_state = nil
        local deletion_start_seq = nil
        local last_line = current_line
        local deletion_count = 0
        local in_deletion_sequence = false
        
        -- Go through undo history
        for i = #undo_tree.entries, 1, -1 do
            local entry = undo_tree.entries[i]
            if entry.seq >= current_seq then goto continue end
            
            -- Try this undo state
            vim.cmd('silent undo ' .. entry.seq)
            
            -- Get the line at this state
            local test_line = vim.api.nvim_buf_get_lines(0, start_line - 1, start_line, false)[1]
            if not test_line then goto continue end
            
            -- Track character deletions
            local length_diff = #test_line - #last_line
            if length_diff == 1 then  -- Character was deleted
                if not in_deletion_sequence then
                    deletion_start_seq = entry.seq
                    in_deletion_sequence = true
                end
                deletion_count = deletion_count + 1
            else
                if in_deletion_sequence and deletion_count > 1 then
                    -- We found the end of a deletion sequence
                    -- Check the state before deletions started
                    vim.cmd('silent undo ' .. deletion_start_seq)
                    local pre_deletion_line = vim.api.nvim_buf_get_lines(0, start_line - 1, start_line, false)[1]
                    
                    -- Find word at the deletion position
                    local pre_word_start = word_start
                    local pre_word_end = word_start
                    
                    while pre_word_start > 1 and pre_deletion_line:sub(pre_word_start - 1, pre_word_start - 1):match("[%w_]") do
                        pre_word_start = pre_word_start - 1
                    end
                    while pre_word_end <= #pre_deletion_line and pre_deletion_line:sub(pre_word_end, pre_word_end):match("[%w_]") do
                        pre_word_end = pre_word_end + 1
                    end
                    
                    local pre_word = pre_deletion_line:sub(pre_word_start, pre_word_end - 1)
                    if pre_word:match("^%w+$") and pre_word ~= selected_text then
                        best_state = {
                            text = pre_word,
                            start = pre_word_start,
                            end_ = pre_word_end - 1
                        }
                        break
                    end
                end
                in_deletion_sequence = false
                deletion_count = 0
            end
            
            last_line = test_line
            ::continue::
        end
        
        -- Restore original state
        vim.api.nvim_buf_set_lines(0, 0, -1, false, original_state.lines)
        vim.cmd('silent undo ' .. original_state.seq)
        
        -- Apply the best change if found
        if best_state then
            local new_line = current_line:sub(1, word_start - 1) .. best_state.text .. current_line:sub(word_end + 1)
            vim.api.nvim_buf_set_lines(0, start_line - 1, start_line, false, {new_line})
        end
    else
        -- For line mode
        -- Store the original state
        local original_state = {
            lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
            seq = current_seq
        }
        
        -- Store the current selected lines
        local current_lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
        
        -- Track all changes we find
        local previous_states = {}
        
        -- Go through undo history in reverse order
        for i = #undo_tree.entries, 1, -1 do
            local entry = undo_tree.entries[i]
            if entry.seq >= current_seq then goto continue end
            
            -- Try this undo state
            vim.cmd('silent undo ' .. entry.seq)
            
            -- Get the lines at this state
            local test_lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
            
            -- Check if any line is different
            local has_changes = false
            for j = 1, #current_lines do
                if not test_lines[j] or test_lines[j] ~= current_lines[j] then
                    has_changes = true
                    break
                end
            end
            
            if has_changes then
                table.insert(previous_states, {
                    seq = entry.seq,
                    lines = vim.deepcopy(test_lines)
                })
            end
            
            ::continue::
        end
        
        -- Restore original state
        vim.api.nvim_buf_set_lines(0, 0, -1, false, original_state.lines)
        vim.cmd('silent undo ' .. original_state.seq)
        
        -- Find the most appropriate previous state
        -- (the one where all lines are different from current)
        local best_state = nil
        for _, state in ipairs(previous_states) do
            local all_lines_different = true
            for i, line in ipairs(state.lines) do
                if current_lines[i] and line == current_lines[i] then
                    all_lines_different = false
                    break
                end
            end
            if all_lines_different then
                best_state = state
                break
            end
        end
        
        -- Apply the changes if found
        if best_state then
            vim.api.nvim_buf_set_lines(0, start_line - 1, end_line, false, best_state.lines)
        end
    end
    
    -- Exit visual mode
    vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
end

-- Setup function to create user commands and mappings
function M.setup(opts)
    opts = opts or {}
    
    -- Enable persistent undo if not disabled
    if opts.persistent_undo ~= false then
        -- Setup for current buffer
        setup_buffer_undo()
        -- Setup autocmd for future buffers
        create_undo_autocmd()
    end
    
    -- Create user commands
    vim.api.nvim_create_user_command('SelectUndoLine', function()
        M.undo_selection('line')
    end, {
        range = true,
        desc = "Undo entire lines within selection"
    })
    
    vim.api.nvim_create_user_command('SelectUndoPartial', function()
        M.undo_selection('partial')
    end, {
        range = true,
        desc = "Undo only selected parts of lines"
    })
    
    -- Create default mappings if not disabled
    if opts.mapping ~= false then
        -- Default mapping for full line undo: gu
        local line_mapping = opts.line_mapping or 'gu'
        vim.keymap.set('x', line_mapping, ':SelectUndoLine<CR>', {
            silent = true,
            noremap = true,
            desc = "Selective undo for entire lines"
        })
        
        -- Default mapping for partial undo: gcu (changed from gU)
        local partial_mapping = opts.partial_mapping or 'gcu'
        vim.keymap.set('x', partial_mapping, ':SelectUndoPartial<CR>', {
            silent = true,
            noremap = true,
            desc = "Selective undo for character selection"
        })
    end

 -- vim.keymap.set("n","<C-s>u",function()
 --   local line_nr = vim.api.nvim_win_get_cursor(0)[1]
 --   vim.cmd(line_nr .. 'undo')
 -- end
 -- )
     
--   vim.keymap.set("n", "<Leader>h", function()
--      if opts.name then
--         print("hello, " .. opts.name)
--      else
--         print("hello")
--      end
--   end)
end

return M
