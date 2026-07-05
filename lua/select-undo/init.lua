-- Main plugin module
local M = {}

-- vim.diff was renamed to vim.text.diff in Neovim 0.12
local diff = vim.text and vim.text.diff or vim.diff

local defaults = {
    persistent_undo = true,  -- enable undofile for normal buffers
    mapping = true,          -- create default visual-mode mappings
    line_mapping = "gu",     -- mapping for :SelectUndoLine (step)
    sweep_mapping = "gU",    -- mapping for :SelectUndoSweep
    partial_mapping = "gC", -- mapping for :SelectUndoPartial
    max_history = 100,       -- how many undo states to search backward
}

M.config = vim.deepcopy(defaults)

-- Enable persistent undo for the current buffer. Neovim already keeps
-- 'undodir' at stdpath("state")/undo and creates it, so only 'undofile'
-- needs to be turned on; the user's own 'undodir' setting is respected.
local function setup_buffer_undo()
    vim.bo.undofile = true
end

local function create_undo_autocmd()
    local group = vim.api.nvim_create_augroup("SelectUndoGroup", { clear = true })
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
        group = group,
        pattern = "*",
        callback = function()
            -- Only enable for normal files
            if vim.bo.buftype == "" then
                setup_buffer_undo()
            end
        end,
        desc = "Enable persistent undo for new buffers",
    })
end

-- Visual selection range; lines and columns are 1-based, columns are bytes
local function get_visual_selection()
    local _, start_line, start_col, _ = unpack(vim.fn.getpos("'<"))
    local _, end_line, end_col, _ = unpack(vim.fn.getpos("'>"))
    return start_line, end_line, start_col, end_col
end

-- Hunks separated by matched lines on both sides are independently
-- anchored. Hunks with no gap between them come from splitting one
-- larger change (linematch), and there the line pairing of a 1:1 piece
-- is arbitrary - trusting it copies one line's history onto another.
-- Returns a set of hunk indices whose run contains a structural
-- (ca ~= cb) hunk; 1:1 hunks in such runs must not be paired line-wise.
local function mark_unreliable(hunks)
    local unreliable = {}
    if #hunks == 0 then return unreliable end
    local run_start = 1
    local run_structural = hunks[1][2] ~= hunks[1][4]
    local function close_run(run_end)
        if run_structural then
            for i = run_start, run_end do unreliable[i] = true end
        end
    end
    for i = 2, #hunks do
        local p, h = hunks[i - 1], hunks[i]
        local gap_a = h[1] - (p[1] + math.max(p[2], 1))
        local gap_b = h[3] - (p[3] + math.max(p[4], 1))
        if gap_a <= 0 or gap_b <= 0 then
            run_structural = run_structural or h[2] ~= h[4]
        else
            close_run(i - 1)
            run_start = i
            run_structural = h[2] ~= h[4]
        end
    end
    close_run(#hunks)
    return unreliable
end

-- Given diff hunks between the current units (a-side) and an older
-- state's units (b-side), build the replacement that reverts the hunks
-- overlapping the selection [sel_lo, sel_hi] (a-side indices). Pure 1:1
-- replacement hunks are clamped to the selection (xdiff coalesces
-- adjacent changed lines into one hunk, and unselected neighbors must
-- stay untouched); hunks that insert or delete units are taken whole
-- since their sides cannot be aligned unit-by-unit. Works on any unit:
-- lines for line mode, single bytes for partial mode.
-- Returns the a-range [first, last] and the units to put there, or nil
-- when no hunk touches the selection.
local function build_revert(hunks, sel_lo, sel_hi, a_units, b_units)
    local unreliable = mark_unreliable(hunks)
    local pieces = {}
    for idx, h in ipairs(hunks) do
        local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
        -- For ca == 0 the hunk is content removed between sa and sa+1;
        -- treat it as touching both neighboring positions
        local a_lo = sa
        local a_hi = ca > 0 and (sa + ca - 1) or (sa + 1)

        if a_lo <= sel_hi and a_hi >= sel_lo then
            if ca == cb and not unreliable[idx] then
                local lo = math.max(sa, sel_lo)
                local hi = math.min(sa + ca - 1, sel_hi)
                pieces[#pieces + 1] = { a_lo = lo, a_hi = hi,
                    b_lo = sb + (lo - sa), b_hi = sb + (hi - sa) }
            elseif ca == 0 then
                -- Empty a-range at the boundary: replacing [sa+1, sa]
                -- re-inserts the removed b-side content at that spot
                pieces[#pieces + 1] = { a_lo = sa + 1, a_hi = sa,
                    b_lo = sb, b_hi = sb + cb - 1 }
            elseif cb == 0 then
                -- Pure deletion of current units: unit-aligned, so clamp
                -- to the selection - never delete unselected neighbors
                local lo = math.max(sa, sel_lo)
                local hi = math.min(sa + ca - 1, sel_hi)
                pieces[#pieces + 1] = { a_lo = lo, a_hi = hi, b_lo = 1, b_hi = 0 }
            else
                pieces[#pieces + 1] = { a_lo = sa, a_hi = sa + ca - 1,
                    b_lo = sb, b_hi = sb + cb - 1 }
            end
        end
    end
    if #pieces == 0 then return nil end

    -- Stitch the pieces (in ascending order) into one contiguous
    -- replacement, keeping the current units between them
    local first = pieces[1].a_lo
    local last = pieces[#pieces].a_hi
    local units = {}
    local pos = first
    for _, p in ipairs(pieces) do
        for i = pos, p.a_lo - 1 do units[#units + 1] = a_units[i] end
        for i = p.b_lo, p.b_hi do units[#units + 1] = b_units[i] end
        pos = p.a_hi + 1
    end
    return first, last, units
end

-- Split a string into one byte per diff-unit / array slot so
-- build_revert can work at character level
local function as_byte_lines(s)
    return (s:gsub(".", "%0\n"))
end

local function as_byte_array(s)
    local t = {}
    for i = 1, #s do t[i] = s:sub(i, i) end
    return t
end

-- Character-level revert for a single line: replace only the changed
-- spans that overlap the selected byte columns [cs, ce]. Returns the new
-- line, or nil when no change touches the selected columns; the second
-- return value is true when the two versions are unrelated (the line was
-- rewritten wholesale) and character comparison is meaningless.
local function partial_revert(cur_line, old_line, cs, ce)
    ce = math.min(ce, #cur_line) -- '> col is v:maxcol after linewise selection
    if #cur_line == 0 or cs > ce then return nil end

    local hunks = diff(as_byte_lines(cur_line), as_byte_lines(old_line),
        { result_type = "indices" })

    -- Character diffs only mean something between related versions of a
    -- line; diffing against unrelated content aligns coincidental
    -- letters and would splice nonsense fragments
    local changed = 0
    for _, h in ipairs(hunks) do changed = changed + h[2] end
    local common = #cur_line - changed
    if common * 2 < math.max(#cur_line, #old_line) then
        return nil, true
    end

    local first, last, units = build_revert(hunks, cs, ce,
        as_byte_array(cur_line), as_byte_array(old_line))
    if not first then return nil end

    return cur_line:sub(1, first - 1) .. table.concat(units) .. cur_line:sub(last + 1)
end

-- A revert whose content equals what is already in the buffer would
-- create a no-op undo state (possible from diff alignment artifacts)
local function is_noop(first, last, lines, orig_lines)
    if last - first + 1 ~= #lines then return false end
    for i = 1, #lines do
        if lines[i] ~= orig_lines[first + i - 1] then return false end
    end
    return true
end

-- One step back through the undo history; returns the new state's seq,
-- or nil when already at the oldest state
local function step_back()
    local before = vim.fn.undotree().seq_cur
    vim.cmd("silent undo")
    local seq = vim.fn.undotree().seq_cur
    if seq == before then return nil end
    return seq
end

-- Buffer content of the current undo state. An empty buffer reads as one
-- empty line; report it as truly empty so "the file didn't exist yet"
-- diffs as a pure deletion that build_revert can clamp to the selection.
local function state_snapshot()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if #lines == 1 and lines[1] == "" then
        return {}, ""
    end
    return lines, table.concat(lines, "\n") .. "\n"
end

-- Line-mode search. Two behaviors:
--
-- Step (sweep = false): revert only the single newest change touching
-- the selection - safe for sloppy selections, since lines whose changes
-- are older stay untouched; press again to walk further back.
--
-- Sweep (sweep = true): collect, for EVERY selected line, the content
-- it had before its most recent change, so one press steps the whole
-- selection back one visible change even when the lines were edited at
-- different times.
--
-- Structural changes (lines inserted/deleted) cannot be attributed to
-- single lines: when the newest change touching the selection is
-- structural it is reverted alone, and an ongoing sweep stops when it
-- reaches one. Runs inside pcall by the caller; the caller restores the
-- buffer state afterward.
local function search_lines(rs, re, orig_lines, orig_text, start_seq, sweep)
    -- Resuming a previous selective undo: start below the state that
    -- provided the current region content, otherwise the state we just
    -- reverted away from would match again and the region would bounce
    -- between two contents instead of walking further back
    if start_seq then
        vim.cmd("silent undo " .. start_seq)
    end

    local reverted = {} -- line nr -> its content before the latest change
    local n_reverted = 0
    local last_source
    local steps = 0

    while steps < M.config.max_history and n_reverted < (re - rs + 1) do
        local state_seq = step_back()
        if not state_seq then break end
        steps = steps + 1

        local state_lines, state_text = state_snapshot()
        local hunks = diff(orig_text, state_text,
            { result_type = "indices", linematch = true })

        if not sweep then
            -- Step mode: revert the newest touching change and stop
            local first, last, lines =
                build_revert(hunks, rs, re, orig_lines, state_lines)
            if first and not is_noop(first, last, lines, orig_lines) then
                return { first = first, last = last, lines = lines,
                    source_seq = state_seq }
            end
            goto continue
        end

        local unreliable = mark_unreliable(hunks)
        local found = {}
        local structural = false
        for idx, h in ipairs(hunks) do
            local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
            local a_lo = sa
            local a_hi = ca > 0 and (sa + ca - 1) or (sa + 1)
            local touches = false
            for i = math.max(a_lo, rs), math.min(a_hi, re) do
                if not reverted[i] then
                    touches = true
                    break
                end
            end
            if touches then
                if ca == cb and not unreliable[idx] then
                    for i = math.max(sa, rs), math.min(sa + ca - 1, re) do
                        local old = state_lines[sb + (i - sa)]
                        if not reverted[i] and old ~= orig_lines[i] then
                            found[i] = old
                        end
                    end
                else
                    structural = true
                end
            end
        end

        if structural then
            if n_reverted == 0 then
                -- The newest change touching the selection restructures
                -- lines: revert exactly that one step
                local first, last, lines =
                    build_revert(hunks, rs, re, orig_lines, state_lines)
                if first and not is_noop(first, last, lines, orig_lines) then
                    return { first = first, last = last, lines = lines,
                        source_seq = state_seq }
                end
            else
                break -- never mix structural changes into a sweep
            end
        else
            for i, old in pairs(found) do
                reverted[i] = old
                n_reverted = n_reverted + 1
            end
            if next(found) then last_source = state_seq end
        end
        ::continue::
    end

    if n_reverted == 0 then return nil end
    local first, last
    for i in pairs(reverted) do
        first = (not first or i < first) and i or first
        last = (not last or i > last) and i or last
    end
    local lines = {}
    for i = first, last do
        lines[#lines + 1] = reverted[i] or orig_lines[i]
    end
    return { first = first, last = last, lines = lines, source_seq = last_source }
end

-- Character-mode search for a single-line selection: walk backward until
-- a change inside the selected columns is found (one step per press)
local function search_partial(rs, cs, ce, orig_lines, orig_text, start_seq)
    if start_seq then
        vim.cmd("silent undo " .. start_seq)
    end

    local steps = 0
    while steps < M.config.max_history do
        local state_seq = step_back()
        if not state_seq then return nil end
        steps = steps + 1

        local state_lines, state_text = state_snapshot()
        local hunks = diff(orig_text, state_text,
            { result_type = "indices", linematch = true })
        local first, last, lines = build_revert(hunks, rs, rs, orig_lines, state_lines)

        if first and not is_noop(first, last, lines, orig_lines) then
            if first == last and #lines == 1 then
                local new_line, unrelated =
                    partial_revert(orig_lines[first], lines[1], cs, ce)
                if new_line and new_line ~= orig_lines[first] then
                    return { first = first, last = last, lines = { new_line },
                        source_seq = state_seq }
                end
                if unrelated then
                    -- The change touching the selection rewrote the
                    -- whole line: partial mode refuses rather than
                    -- splicing fragments of unrelated content
                    return { whole_line_change = true }
                end
                -- The line changed, but outside the selected columns:
                -- keep walking for an older change inside them
            else
                -- The change added or removed lines; that cannot be
                -- reverted characters-at-a-time either
                return { whole_line_change = true }
            end
        end
    end
    return nil
end

-- Main function to perform selective undo
function M.undo_selection(mode)
    local rs, re, cs, ce = get_visual_selection()
    local orig_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if rs < 1 or re > #orig_lines or rs > re then return end

    local orig_seq = vim.fn.undotree().seq_cur
    if orig_seq == 0 then
        vim.notify("select-undo: no undo history for this buffer", vim.log.levels.INFO)
        return
    end

    -- If this is another press on the exact same selection with nothing
    -- edited in between, continue the walk below the state the previous
    -- press took its content from
    local resume = vim.b.select_undo_resume
    local start_seq = nil
    if resume and resume.applied_seq == orig_seq and resume.mode == mode
        and resume.rs == rs and resume.re == re
        and (mode ~= "partial" or (resume.cs == cs and resume.ce == ce)) then
        start_seq = resume.source_seq
    end

    local orig_text = table.concat(orig_lines, "\n") .. "\n"
    local view = vim.fn.winsaveview()
    local saved_eventignore = vim.o.eventignore
    vim.o.eventignore = "all"

    local ok, revert
    if mode == "partial" and rs == re then
        ok, revert = pcall(search_partial, rs, cs, ce, orig_lines, orig_text, start_seq)
    else
        -- Line modes, or a partial selection spanning multiple lines
        -- (which falls back to stepping)
        ok, revert = pcall(search_lines, rs, re, orig_lines, orig_text,
            start_seq, mode == "sweep")
    end

    -- Jumping back to the original state is a pure tree move: the scan
    -- leaves no new undo states behind
    vim.cmd("silent undo " .. orig_seq)
    vim.o.eventignore = saved_eventignore
    vim.fn.winrestview(view)

    if not ok then
        vim.notify("select-undo: " .. tostring(revert), vim.log.levels.ERROR)
        return
    end
    if not revert then
        vim.notify("select-undo: no earlier change found for the selection",
            vim.log.levels.INFO)
        return
    end
    if revert.whole_line_change then
        vim.notify(("select-undo: the change touching the selection rewrote"
            .. " or restructured the whole line - select it and use %s"
            .. " (:SelectUndoLine) to revert it"):format(M.config.line_mapping),
            vim.log.levels.INFO)
        return
    end

    -- The single edit below is the only new undo state, so native undo
    -- reverts a selective undo in one step
    vim.api.nvim_buf_set_lines(0, revert.first - 1, revert.last, false, revert.lines)
    vim.b.select_undo_resume = {
        applied_seq = vim.fn.undotree().seq_cur,
        source_seq = revert.source_seq,
        mode = mode,
        rs = rs, re = re, cs = cs, ce = ce,
    }

    -- Replacing lines shifts the visual marks; put them back on the
    -- selected region so gv reselects it and repeated presses resume
    local function clamp_col(lnum, col)
        local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
        return math.max(0, math.min(col - 1, math.max(#line - 1, 0)))
    end
    local line_count = vim.api.nvim_buf_line_count(0)
    local mark_rs = math.min(rs, line_count)
    local mark_re = math.min(re, line_count)
    vim.api.nvim_buf_set_mark(0, "<", mark_rs, clamp_col(mark_rs, cs), {})
    vim.api.nvim_buf_set_mark(0, ">", mark_re, clamp_col(mark_re, ce), {})
end

-- Setup function to create user commands and mappings
function M.setup(opts)
    M.config = vim.tbl_extend("force", vim.deepcopy(defaults), opts or {})

    if M.config.persistent_undo ~= false then
        setup_buffer_undo()
        create_undo_autocmd()
    end

    vim.api.nvim_create_user_command("SelectUndoLine", function()
        M.undo_selection("line")
    end, {
        range = true,
        desc = "Undo the newest change within the selected lines",
    })

    vim.api.nvim_create_user_command("SelectUndoSweep", function()
        M.undo_selection("sweep")
    end, {
        range = true,
        desc = "Undo the last change of every selected line",
    })

    vim.api.nvim_create_user_command("SelectUndoPartial", function()
        M.undo_selection("partial")
    end, {
        range = true,
        desc = "Undo only selected parts of lines",
    })

    -- "x" (visual only), not "v": in select mode printable keys must
    -- keep inserting text
    if M.config.mapping ~= false then
        vim.keymap.set("x", M.config.line_mapping, ":SelectUndoLine<CR>", {
            silent = true,
            noremap = true,
            desc = "Selective undo: newest change in selection",
        })
        vim.keymap.set("x", M.config.sweep_mapping, ":SelectUndoSweep<CR>", {
            silent = true,
            noremap = true,
            desc = "Selective undo: last change of every selected line",
        })
        vim.keymap.set("x", M.config.partial_mapping, ":SelectUndoPartial<CR>", {
            silent = true,
            noremap = true,
            desc = "Selective undo for character selection",
        })
    end
end

return M
