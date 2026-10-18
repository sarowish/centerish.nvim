-- Temporary split widths must not truncate or reflow terminal output.
return function()
  local cases = {
    { name = "focused terminal screen", focus = 1, terminal = 1, content = "hard" },
    { name = "inactive terminal screen", focus = 3, terminal = 2, content = "hard" },
    { name = "terminal scrollback", focus = 1, terminal = 3, content = "wrapped" },
    {
      name = "terminal shared with another tab",
      focus = 1,
      terminal = 2,
      content = "hard",
      other_tab = true,
    },
    {
      name = "alternate screen in temporary Normal mode",
      focus = 3,
      terminal = 3,
      content = "alternate",
      temporary = true,
    },
  }

  for _, case in ipairs(cases) do
    for _, command in ipairs({ "r", "R" }) do
      local native
      for _, centered in ipairs({ false, true }) do
        local context = case.name .. " command=" .. command .. " centered=" .. tostring(centered)
        local child = dofile("tests/child.lua").start({ name = context })
        local request, settle = child.request, child.settle
        local ok, err = xpcall(function()
          request("nvim_ui_attach", { centered and 400 or 242, 40, { ext_linegrid = true } })
          request("nvim_exec_lua", {
            [=[
              local root, case, centered = ...
              vim.opt.runtimepath:prepend(root)
              vim.o.swapfile = false
              _G.editors = { vim.api.nvim_get_current_win() }
              for index = 2, 3 do
                vim.cmd('rightbelow vnew')
                editors[index] = vim.api.nvim_get_current_win()
              end
              require('centerish').setup({ width = 80, min_padding_width = 0 })
              if centered then require('centerish').enable() end
              _G.terminal_window = editors[case.terminal]
              vim.api.nvim_set_current_win(terminal_window)
              _G.terminal_input = {}
              local channel = vim.api.nvim_open_term(0, { on_input = function(_, _, _, data)
                terminal_input[#terminal_input + 1] = data
              end })
              local text = {}
              for row = 1, case.content == 'wrapped' and 19 or 37 do
                text[row] = string.format('%02d:', row)
                  .. string.rep('abcdefghi', case.content == 'wrapped' and 28 or 8)
                  .. 'abcd'
              end
              vim.api.nvim_chan_send(channel,
                (case.content == 'alternate' and '\027[?1049h' or '')
                  .. table.concat(text, '\r\n') .. '\r\ncursor-marker')
              if case.other_tab then
                local tab = vim.api.nvim_get_current_tabpage()
                local buffer = vim.api.nvim_win_get_buf(terminal_window)
                vim.cmd('noautocmd tabnew')
                vim.cmd('noautocmd buffer ' .. buffer)
                vim.api.nvim_set_current_tabpage(tab)
              end
              vim.api.nvim_set_current_win(editors[case.focus])
              _G.snapshot = function()
                local ids, order = {}, {}
                for index, win in ipairs(editors) do ids[win] = index end
                for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                  if ids[win] then order[#order + 1] = ids[win] end
                end
                return {
                  terminal = {
                    text = vim.api.nvim_buf_get_lines(
                      vim.api.nvim_win_get_buf(terminal_window), 0, -1, false
                    ),
                    cursor = vim.api.nvim_win_get_cursor(terminal_window),
                    width = vim.api.nvim_win_get_width(terminal_window),
                    height = vim.api.nvim_win_get_height(terminal_window),
                    topline = vim.fn.getwininfo(terminal_window)[1].topline,
                  },
                  mode = vim.fn.mode(1), focused = ids[vim.api.nvim_get_current_win()],
                  order = order, input = table.concat(terminal_input), error = vim.v.errmsg,
                }
              end
              vim.v.errmsg = ''
            ]=],
            { vim.fn.getcwd(), case, centered },
          })
          settle()
          if case.other_tab then
            request("nvim_exec_lua", {
              "vim.api.nvim_win_set_cursor(terminal_window, { 20, 10 })",
              {},
            })
          end
          if case.temporary then
            request("nvim_input", { "i" })
            settle()
          end
          local before = request("nvim_exec_lua", { "return snapshot()", {} })
          local prefix = case.temporary and "<C-\\><C-O>" or ""
          request("nvim_input", { prefix .. "<C-W>" .. command })
          settle()
          local after = request("nvim_exec_lua", { "return snapshot()", {} })
          assert(
            vim.deep_equal(after.terminal, before.terminal),
            context .. ": rotation changed terminal output, cursor or dimensions"
          )
          local result = { after }
          if case.temporary then
            request("nvim_input", { "abc" })
            settle()
            result[#result + 1] = request("nvim_exec_lua", { "return snapshot()", {} })
          end
          if centered then
            assert(
              vim.deep_equal(result, native),
              context
                .. "\nexpected: "
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

  -- A temporary terminal view must preserve the mark and local options used
  -- when the buffer is opened later, including a mark unlike its live cursor.
  for _, focus in ipairs({ 1, 3 }) do
    for _, command in ipairs({ "r", "R" }) do
      local baseline
      for _, reordered in ipairs({ false, true }) do
        local context = "terminal restoration focus=" .. focus .. " command=" .. command
        local child = dofile("tests/child.lua").start({ name = context })
        local request, settle = child.request, child.settle
        local ok, err = xpcall(function()
          request("nvim_ui_attach", { 400, 40, { ext_linegrid = true } })
          request("nvim_exec_lua", {
            [=[
              local root, focus = ...
              vim.opt.runtimepath:prepend(root)
              vim.o.swapfile = false
              _G.editors = { vim.api.nvim_get_current_win() }
              for index = 2, 3 do
                vim.cmd('rightbelow vnew')
                editors[index] = vim.api.nvim_get_current_win()
              end
              require('centerish').setup({ width = 80, min_padding_width = 0 })
              require('centerish').enable()
              vim.api.nvim_set_current_win(editors[3])
              _G.terminal_buffer = vim.api.nvim_get_current_buf()
              local channel = vim.api.nvim_open_term(0, {})
              local text = {}
              for row = 1, 80 do text[row] = row .. string.rep('x', 75) end
              vim.api.nvim_chan_send(channel, table.concat(text, '\r\n'))
              vim.wo.number = true
              vim.wo.relativenumber = true
              vim.wo.wrap = false
              vim.wo.foldmethod = 'marker'
              vim.wo.signcolumn = 'yes:2'
              vim.wo.winhighlight = 'Normal:ErrorMsg'
              vim.wo.scrolloff = 3
              vim.wo.sidescrolloff = 4
              vim.api.nvim_set_current_win(editors[focus])
              vim.cmd('lcd /tmp')
              _G.events = {}
              vim.api.nvim_create_autocmd({
                'WinNew', 'WinClosed', 'BufWinEnter', 'BufWinLeave', 'OptionSet',
              }, { callback = function(ev) events[#events + 1] = ev.event end })
              _G.context = function()
                return {
                  current = vim.api.nvim_get_current_win(),
                  previous = vim.fn.win_getid(vim.fn.winnr('#')),
                  cwd = vim.fn.getcwd(), localdir = vim.fn.haslocaldir(), events = events,
                  windows = #vim.api.nvim_list_wins(), buffers = #vim.api.nvim_list_bufs(),
                }
              end
              vim.v.errmsg = ''
            ]=],
            { vim.fn.getcwd(), focus },
          })
          settle()
          request("nvim_exec_lua", {
            "vim.api.nvim_win_set_cursor(editors[3], { 20, 10 })",
            {},
          })
          local before = request("nvim_exec_lua", { "return context()", {} })
          if reordered then
            request("nvim_input", { "<C-W>" .. command })
            settle()
          end
          assert(
            vim.deep_equal(request("nvim_exec_lua", { "return context()", {} }), before),
            context .. ": correction changed history, directories or emitted helper events"
          )
          request("nvim_exec_lua", {
            "vim.cmd('noautocmd tabnew'); vim.cmd('noautocmd buffer ' .. terminal_buffer)",
            {},
          })
          settle()
          local restored = request("nvim_exec_lua", {
            [=[return {
              cursor = vim.api.nvim_win_get_cursor(0), view = vim.fn.winsaveview(),
              number = vim.wo.number, relativenumber = vim.wo.relativenumber,
              wrap = vim.wo.wrap, foldmethod = vim.wo.foldmethod, signcolumn = vim.wo.signcolumn,
              winhighlight = vim.wo.winhighlight, scrolloff = vim.wo.scrolloff,
              sidescrolloff = vim.wo.sidescrolloff, error = vim.v.errmsg,
            }]=],
            {},
          })
          if reordered then
            assert(
              vim.deep_equal(restored, baseline),
              context
                .. ": correction changed later terminal restoration\nexpected: "
                .. vim.inspect(baseline)
                .. "\nactual: "
                .. vim.inspect(restored)
            )
          else
            baseline = restored
          end
        end, debug.traceback)
        child.close()
        assert(ok, err)
      end
    end
  end
end
