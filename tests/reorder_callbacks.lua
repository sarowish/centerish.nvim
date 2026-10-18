-- Compare callback decisions and failures against native keyboard commands.
return function()
  local cases = {
    { name = "rotation callback switches tabs", keys = "V5<C-W>r", callback = "tab" },
    { name = "reverse rotation callback switches tabs", keys = "V5<C-W>R", callback = "tab" },
    {
      name = "rotation callback enters another centered tab",
      keys = "V5<C-W>r",
      callback = "centered_tab",
    },
    { name = "rotation callback closes its source", keys = "V5<C-W>r", callback = "close" },
    { name = "rotation callback disables centering", keys = "V5<C-W>R", callback = "disable" },
    { name = "rotation callback enters a nested split", keys = "V5<C-W>r", callback = "nested" },
    {
      name = "rejected rotation leaves no pending correction",
      keys = "V5<C-W>r",
      callback = "float",
      refresh = true,
    },
    {
      name = "callback failure preserves counted rotation",
      keys = "V5<C-W>r",
      callback = "error",
      refresh = true,
    },
    { name = "callback failure preserves reverse rotation", keys = "V<C-W>R", callback = "error" },
    { name = "shifted prefix exchange", keys = "<C-S-W>x", focus = 3 },
    { name = "shifted prefix counted exchange", keys = "<C-S-W>2x" },
    { name = "shifted prefix rotation", keys = "<C-S-W>r" },
    { name = "existing shifted prefix mapping", keys = "<C-S-W>", mapping = "prefix" },
    { name = "existing shifted command mapping", keys = "<C-S-W>x", mapping = "command" },
    { name = "modified suffix macro", keys = "qa<C-W><M-x>q@a", focus = 3 },
    { name = "modified count", keys = "<C-W><M-2>x" },
    {
      name = "exchange callback sees suffix count",
      keys = "3l<C-W>2x",
      callback = "exchange_count",
      expected_count = 2,
    },
    {
      name = "exchange callback sees multiplied count",
      keys = "3l2<C-W>2x",
      callback = "exchange_count",
      expected_count = 4,
      count = 4,
    },
    {
      name = "rotation callback sees suffix count",
      keys = "3lV<C-W>2r",
      callback = "rotation_count",
      expected_count = 2,
    },
  }

  for _, case in ipairs(cases) do
    local native
    for _, centered in ipairs({ false, true }) do
      local context = case.name .. " centered=" .. tostring(centered)
      local child = dofile("tests/child.lua").start({ name = context })
      local request, settle = child.request, child.settle
      local ok, err = xpcall(function()
        request("nvim_ui_attach", { 400, 40, { ext_linegrid = true } })
        request("nvim_exec_lua", {
          [=[
            local root, centered, case = ...
            vim.opt.runtimepath:prepend(root)
            vim.o.swapfile = false
            _G.editors = { vim.api.nvim_get_current_win() }
            for index = 2, case.count or 3 do
              vim.cmd('rightbelow vnew')
              editors[index] = vim.api.nvim_get_current_win()
            end
            for index, win in ipairs(editors) do
              vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false,
                { 'abcdefghijk', 'x', 'abcdefghijk' })
              vim.api.nvim_win_set_cursor(win, { 1, index - 1 })
            end
            _G.original_tab = vim.api.nvim_get_current_tabpage()
            _G.tabs = { original_tab }
            _G.calls, _G.seen = 0, {}
            if case.mapping then
              vim.keymap.set('n', case.mapping == 'prefix' and '<C-S-W>' or '<C-S-W>x',
                function() calls = calls + 1 end)
            end
            vim.api.nvim_set_current_win(editors[case.focus or 1])
            local centerish = require('centerish')
            centerish.setup({ width = 80 })
            if centered then centerish.enable() end
            vim.api.nvim_set_current_win(editors[#editors])
            vim.api.nvim_set_current_win(editors[case.focus or 1])
            if case.callback == 'tab' then
              vim.cmd.tabnew()
              tabs[2] = vim.api.nvim_get_current_tabpage()
              vim.api.nvim_set_current_tabpage(original_tab)
            elseif case.callback == 'nested' or case.callback == 'centered_tab' then
              vim.cmd.tabnew()
              tabs[2] = vim.api.nvim_get_current_tabpage()
              editors[4] = vim.api.nvim_get_current_win()
              vim.cmd(case.callback == 'nested' and 'belowright new' or 'rightbelow vnew')
              editors[5] = vim.api.nvim_get_current_win()
              if case.callback == 'centered_tab' then
                vim.cmd('rightbelow vnew')
                editors[6] = vim.api.nvim_get_current_win()
                if centered then centerish.enable() end
              end
              vim.api.nvim_set_current_tabpage(original_tab)
            elseif case.callback == 'float' then
              _G.floating = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false,
                { relative = 'editor', row = 1, col = 1, width = 20, height = 4 })
            end
            local done = false
            local function callback()
              if done then return end
              done = true
              seen[#seen + 1] = { vim.v.count, vim.v.count1, vim.v.prevcount }
              if case.callback == 'tab' or case.callback == 'centered_tab' then
                vim.api.nvim_set_current_tabpage(tabs[2])
              elseif case.callback == 'close' then
                vim.api.nvim_win_close(editors[1], true)
              elseif case.callback == 'disable' then
                centerish.disable()
              elseif case.callback == 'nested' then
                vim.api.nvim_set_current_win(editors[4])
              elseif case.callback == 'float' then
                vim.api.nvim_set_current_win(floating)
              elseif case.callback == 'error' then
                error('expected rotation callback failure')
              elseif case.callback == 'exchange_count' or case.callback == 'rotation_count' then
                vim.api.nvim_set_current_win(editors[vim.v.count == case.expected_count and 3 or 1])
              end
            end
            if case.callback == 'exchange_count' then
              vim.api.nvim_create_autocmd('WinEnter', { callback = callback })
            elseif case.callback then
              vim.api.nvim_create_autocmd('ModeChanged', { pattern = 'V:n', callback = callback })
            end
            vim.fn.setreg('a', '')
            vim.v.errmsg = ''
          ]=],
          { vim.fn.getcwd(), centered, case },
        })
        settle()
        request("nvim_input", { case.keys })
        settle()
        if case.callback == "error" or case.callback == "float" then
          request("nvim_input", { "<Esc>" })
          settle()
        end
        if case.refresh then
          request("nvim_exec_lua", { "require('centerish').setup({ width = 80 })", {} })
          settle()
        end
        local result = request("nvim_exec_lua", {
          [=[
            local ids, orders, cursors, text = {}, {}, {}, {}
            for index, win in ipairs(editors) do
              ids[win] = index
              if vim.api.nvim_win_is_valid(win) then
                cursors[tostring(index)] = vim.api.nvim_win_call(win, vim.fn.getcurpos)
                text[tostring(index)] = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
              end
            end
            local tab_index = 0
            for index, tab in ipairs(tabs) do
              if tab == vim.api.nvim_get_current_tabpage() then tab_index = index end
              orders[index] = {}
              for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
                if ids[win] then orders[index][#orders[index] + 1] = ids[win] end
              end
            end
            local error = vim.v.errmsg:match('E%d+:[^\n]*')
              or vim.v.errmsg:match('expected rotation callback failure') or vim.v.errmsg
            return {
              orders = orders, focused = ids[vim.api.nvim_get_current_win()] or 0,
              previous = ids[vim.fn.win_getid(vim.fn.winnr('#'))] or 0,
              tab = tab_index, cursors = cursors, text = text, seen = seen, calls = calls,
              mode = vim.fn.mode(1), register = vim.fn.getreg('a'), error = error,
            }
          ]=],
          {},
        })
        if centered then
          assert(
            vim.deep_equal(result, native),
            context .. "\nexpected: " .. vim.inspect(native) .. "\nactual: " .. vim.inspect(result)
          )
        else
          native = result
        end
      end, debug.traceback)
      child.close()
      assert(ok, err)
    end
  end
end
