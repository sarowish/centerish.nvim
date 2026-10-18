-- Rotations retain viewport, directory and previous-window state through padding repair.
return function()
  local previous_directory = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
  local scenarios = {
    { name = "horizontal view below winwidth", view = true, winwidth = 100 },
    { name = "wrapped fixed-window view", view = true, wrap = true, fixed = true },
    {
      name = "window directory without a previous window",
      count = 1,
      scope = "window",
      history = "closed",
      command = "<C-W>R",
    },
    { name = "tab directory with the current window as previous", scope = "tab", history = "self" },
    { name = "global directory history", scope = "global", command = "2<C-W>r" },
    { name = "autochdir window directory", scope = "window", autochdir = true },
    {
      name = "autochdir without a previous window",
      scope = "global",
      autochdir = true,
      history = "closed",
      command = "<C-W>R",
    },
  }

  for _, scenario in ipairs(scenarios) do
    local native
    for _, centered in ipairs({ false, true }) do
      local count = scenario.count or 3
      local child = dofile("tests/child.lua").start({ name = scenario.name })
      local request, settle = child.request, child.settle
      local ok, err = xpcall(function()
        -- Give native windows the same 80-column view as centered windows.
        request("nvim_ui_attach", {
          centered and 400 or count * 80 + count - 1,
          40,
          { ext_linegrid = true },
        })
        request("nvim_exec_lua", {
          [=[
            local root, count, centered, scenario, previous_directory = ...
            vim.opt.runtimepath:prepend(root)
            vim.o.swapfile = false
            _G.editors = { vim.api.nvim_get_current_win() }
            for index = 2, count do
              vim.cmd('rightbelow vnew')
              editors[index] = vim.api.nvim_get_current_win()
            end
            vim.api.nvim_set_current_win(editors[1])
            vim.o.winwidth = scenario.winwidth or 20
            require('centerish').setup({ width = 80, min_padding_width = 0 })
            if centered then require('centerish').enable() end
            if scenario.history == 'closed' then
              local current = vim.api.nvim_get_current_win()
              local previous = vim.api.nvim_open_win(0, false, {
                relative = 'editor', row = 0, col = 0, width = 1, height = 1,
                noautocmd = true,
              })
              vim.api.nvim_win_call(previous, function() vim.api.nvim_set_current_win(current) end)
              vim.api.nvim_win_close(previous, true)
            elseif scenario.history == 'self' then
              vim.api.nvim_win_call(editors[1], function() vim.api.nvim_set_current_win(editors[count]) end)
            end
            if scenario.view then
              for _, win in ipairs(editors) do vim.api.nvim_win_set_width(win, 80) end
              for _, win in ipairs(editors) do
                local lines = {}
                for line = 1, 100 do lines[line] = string.rep('abcdefghij', 60) end
                vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, lines)
                vim.wo[win].wrap = scenario.wrap or false
                vim.wo[win].smoothscroll = true
                vim.wo[win].winfixwidth = scenario.fixed or false
                vim.wo[win].winfixheight = scenario.fixed or false
                vim.api.nvim_win_call(win, function()
                  vim.fn.winrestview({
                    lnum = 60, col = 400, curswant = 400, topline = 59,
                    leftcol = scenario.wrap and 0 or 360,
                    skipcol = scenario.wrap and 240 or 0,
                  })
                end)
              end
            end
            if scenario.autochdir then
              for index, win in ipairs(editors) do
                vim.api.nvim_buf_set_name(vim.api.nvim_win_get_buf(win), root .. '/rotation-' .. index)
              end
              vim.o.autochdir = true
            end
            _G.directory_command = scenario.scope == 'window' and 'lcd'
              or scenario.scope == 'tab' and 'tcd' or 'cd'
            if scenario.scope then
              vim.cmd(directory_command .. ' ' .. vim.fn.fnameescape(previous_directory))
              vim.cmd(directory_command .. ' ' .. vim.fn.fnameescape(vim.fn.fnamemodify(root, ':h')))
            end
            _G.directory_events = {}
            vim.api.nvim_create_autocmd('DirChanged', { callback = function()
              directory_events[#directory_events + 1] = vim.deepcopy(vim.v.event)
            end })
            vim.v.errmsg = ''
            _G.snapshot = function()
              local ids, windows, order = {}, {}, {}
              for index, win in ipairs(editors) do
                ids[win] = index
                local number = vim.fn.win_id2win(win)
                windows[index] = scenario.view and {
                  view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
                  width = vim.api.nvim_win_get_width(win),
                  height = vim.api.nvim_win_get_height(win),
                  fixed_width = vim.wo[win].winfixwidth,
                  fixed_height = vim.wo[win].winfixheight,
                } or { directory = vim.fn.getcwd(number, 0), scope = vim.fn.haslocaldir(number, 0) }
              end
              for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                if ids[win] then order[#order + 1] = ids[win] end
              end
              return {
                windows = windows, order = order,
                focused = ids[vim.api.nvim_get_current_win()],
                previous = ids[vim.fn.win_getid(vim.fn.winnr('#'))] or 0,
                directory = { vim.fn.getcwd(), vim.uv.cwd(), vim.fn.getcwd(-1, -1), vim.fn.getcwd(-1, 0), vim.fn.haslocaldir() },
                events = directory_events, error = vim.v.errmsg,
              }
            end
          ]=],
          { vim.fn.getcwd(), count, centered, scenario, previous_directory },
        })
        settle()
        local before = request("nvim_exec_lua", { "return snapshot()", {} })
        request("nvim_input", { scenario.command or "<C-W>r" })
        settle()
        local after = request("nvim_exec_lua", { "return snapshot()", {} })
        assert(after.error == "", scenario.name .. ": " .. after.error)
        assert(
          vim.deep_equal(after.windows, before.windows),
          scenario.name .. ": rotation changed a window's view, size, fixed flags or directory"
        )
        local result = { after = after }
        if scenario.scope then
          request("nvim_exec_lua", { "vim.cmd(directory_command .. ' -')", {} })
          result.previous_directory =
            request("nvim_exec_lua", { "return snapshot().directory", {} })
        end
        if centered then
          assert(
            vim.deep_equal(result, native),
            scenario.name
              .. ": state differs from native rotation\nexpected: "
              .. vim.inspect(native)
              .. "\nactual: "
              .. vim.inspect(result)
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
