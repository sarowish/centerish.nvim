-- Exercise adaptive growth during native completion and focus-driven resizing.
return function()
  local scenario = "initialization"
  local child = dofile("tests/child.lua").start({
    name = "adaptive",
    context = function()
      return scenario
    end,
  })
  local request, settle = child.request, child.settle

  local setup = [[
    local root, count = ...
    vim.opt.runtimepath:prepend(root)
    local centerish = require('centerish')
    centerish.disable()
    vim.cmd('silent! only!')
    vim.cmd('enew!')
    vim.o.equalalways = false
    vim.o.laststatus = 0
    vim.o.winwidth = 20
    vim.o.winminwidth = 1
    vim.o.completeopt = 'menuone,noselect,noinsert'
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.signcolumn = 'no'
    vim.wo.wrap = false
    vim.wo.winfixwidth = false
    vim.v.errmsg = ''
    _G.editors = { vim.api.nvim_get_current_win() }
    if count == 2 then
      vim.cmd('rightbelow vnew')
      editors[2] = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(editors[1])
    _G.events = { TextChangedI = 0, TextChangedP = 0, WinResized = 0 }
    _G.resize_widths = {}
    if not _G.input_hook then
      _G.input_hook = vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChangedP', 'WinResized' }, {
        callback = function(args)
          events[args.event] = events[args.event] + 1
          if args.event == 'WinResized' then
            resize_widths[#resize_widths + 1] = vim.api.nvim_win_get_width(0)
          end
        end,
      })
    end
    centerish.setup({ width = 80, min_padding_width = 0, adaptive = { enabled = true } })
    centerish.enable()
  ]]

  local ok, err = xpcall(function()
    request("nvim_ui_attach", { 400, 40, { ext_linegrid = true, rgb = true } })

    scenario = "typing while the completion menu is visible"
    request("nvim_exec_lua", { setup, { vim.fn.getcwd(), 1 } })
    request("nvim_exec_lua", {
      "vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep('z', 70) })",
      {},
    })
    settle()
    request("nvim_input", { "ix" })
    settle()
    request("nvim_exec_lua", {
      "vim.fn.complete(1, { string.rep('x', 120), string.rep('x', 130) })",
      {},
    })
    settle()
    local before = request("nvim_exec_lua", {
      "return { menu = vim.fn.pumvisible(), changed = events.TextChangedI, popup = events.TextChangedP }",
      {},
    })
    assert(before.menu == 1, "completion menu did not open")
    -- The cursor stays near the start of the line, so horizontal scrolling cannot
    -- trigger growth on behalf of the completion-specific text change event.
    request("nvim_input", { string.rep("x", 19) })
    settle()
    local completed = request("nvim_exec_lua", {
      "return { menu = vim.fn.pumvisible(), width = vim.api.nvim_win_get_width(editors[1]), "
        .. "length = #vim.api.nvim_get_current_line(), changed = events.TextChangedI, "
        .. "popup = events.TextChangedP, error = vim.v.errmsg }",
      {},
    })
    assert(completed.error == "", completed.error)
    assert(completed.menu == 1, "completion menu closed during typing")
    assert(completed.popup > before.popup, "typing did not emit TextChangedP")
    assert(completed.changed == before.changed, "typing unexpectedly emitted TextChangedI")
    assert(completed.length == 90, "completion input changed the wrong text")
    assert(
      completed.width == 90,
      "adaptive growth missed completion input: " .. vim.inspect(completed)
    )
    request("nvim_input", { "<Esc>" })
    settle()

    scenario = "adaptive growth after automatic winwidth resizing"
    request("nvim_exec_lua", { setup, { vim.fn.getcwd(), 2 } })
    settle()
    request("nvim_exec_lua", { "vim.o.winwidth = 100", {} })
    settle()
    request("nvim_exec_lua", { "events.WinResized = 0", {} })
    request("nvim_input", { "<C-W>l" })
    settle()
    local focused = request("nvim_exec_lua", {
      "return { current = vim.api.nvim_get_current_win(), width = vim.api.nvim_win_get_width(editors[2]), "
        .. "resized = events.WinResized, editor = editors[2] }",
      {},
    })
    assert(focused.current == focused.editor, "native navigation did not reach the second editor")
    assert(focused.width == 100, "winwidth did not resize the focused editor")
    assert(focused.resized > 0, "focus did not emit a native resize event")
    request("nvim_input", { "i" .. string.rep("x", 120) })
    settle()
    local grown = request("nvim_exec_lua", {
      "return { width = vim.api.nvim_win_get_width(editors[2]), length = #vim.api.nvim_get_current_line(), "
        .. "changed = events.TextChangedI, error = vim.v.errmsg }",
      {},
    })
    assert(grown.error == "", grown.error)
    assert(grown.changed > 0, "typing did not emit TextChangedI")
    assert(grown.length == 120, "native input did not write the requested line")
    assert(grown.width == 120, "automatic resizing paused adaptive growth: " .. vim.inspect(grown))

    -- Focus sizing may also consume padding when stacked editors share a column.
    request("nvim_input", { "<Esc>" })
    settle()
    scenario = "adaptive growth after focus sizing consumes padding"
    request("nvim_exec_lua", { setup, { vim.fn.getcwd(), 1 } })
    request("nvim_exec_lua", {
      "vim.cmd('belowright new'); editors[2] = vim.api.nvim_get_current_win()",
      {},
    })
    settle()
    request("nvim_exec_lua", {
      [[
        _G.floating = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
          relative = 'editor', row = 3, col = 4, width = 20, height = 3,
        })
        vim.o.winwidth = 100
      ]],
      {},
    })
    settle()
    request("nvim_exec_lua", { "resize_widths = {}", {} })
    request("nvim_input", { "<C-W>p" })
    settle()
    local returned = request("nvim_exec_lua", {
      "return { current = vim.api.nvim_get_current_win(), editor = editors[2], widths = resize_widths }",
      {},
    })
    assert(
      returned.current == returned.editor,
      "navigation did not return from the floating window"
    )
    assert(vim.tbl_contains(returned.widths, 100), "winwidth did not consume padding on focus")
    request("nvim_input", { "i" .. string.rep("x", 130) })
    settle()
    local stacked = request("nvim_exec_lua", {
      "return { first = vim.api.nvim_win_get_width(editors[1]), "
        .. "second = vim.api.nvim_win_get_width(editors[2]), error = vim.v.errmsg }",
      {},
    })
    assert(stacked.error == "", stacked.error)
    assert(stacked.first == 130 and stacked.second == 130, "focus sizing paused stacked growth")

    for _, count in ipairs({ 1, 2 }) do
      for _, direction in ipairs({ "h", "l" }) do
        request("nvim_input", { "<Esc>" })
        settle()
        scenario = "adaptive growth after padding navigation, editors="
          .. count
          .. ", "
          .. direction
        request("nvim_exec_lua", { setup, { vim.fn.getcwd(), 1 } })
        request("nvim_exec_lua", {
          [[
            require('centerish').disable()
            if ... == 2 then
              vim.cmd('belowright new')
              editors[2] = vim.api.nvim_get_current_win()
            end
            vim.o.winwidth = 100
            require('centerish').enable()
          ]],
          { count },
        })
        settle()
        request("nvim_exec_lua", { "resize_widths = {}", {} })
        request("nvim_input", { "<C-W>" .. direction })
        settle()
        local widths = request("nvim_exec_lua", { "return resize_widths", {} })
        assert(vim.tbl_contains(widths, 100), "padding navigation did not trigger focus sizing")
        request("nvim_input", { "i" .. string.rep("x", 130) })
        settle()
        local result = request("nvim_exec_lua", {
          [[
            local widths = {}
            for _, win in ipairs(editors) do
              widths[#widths + 1] = vim.api.nvim_win_get_width(win)
            end
            return { widths = widths, length = #vim.api.nvim_get_current_line(), error = vim.v.errmsg }
          ]],
          {},
        })
        assert(result.error == "", result.error)
        assert(result.length == 130, "native input did not write the requested line")
        for _, width in ipairs(result.widths) do
          assert(width == 130, "padding navigation paused adaptive growth: " .. vim.inspect(result))
        end
      end
    end

    request("nvim_input", { "<Esc>" })
    settle()
    scenario = "adaptive growth after changing winwidth"
    request("nvim_exec_lua", { setup, { vim.fn.getcwd(), 1 } })
    settle()
    request("nvim_exec_lua", { "resize_widths = {}", {} })
    request("nvim_input", { ":set winwidth=100<CR>" })
    settle()
    local widths = request("nvim_exec_lua", { "return resize_widths", {} })
    assert(vim.tbl_contains(widths, 100), "changing winwidth did not resize the editor")
    request("nvim_input", { "i" .. string.rep("x", 130) })
    settle()
    local result = request("nvim_exec_lua", {
      "return { width = vim.api.nvim_win_get_width(editors[1]), length = #vim.api.nvim_get_current_line(), "
        .. "error = vim.v.errmsg }",
      {},
    })
    assert(result.error == "", result.error)
    assert(result.length == 130, "native input did not write the requested line")
    assert(result.width == 130, "changing winwidth paused adaptive growth: " .. vim.inspect(result))

    scenario = "manual resizing after an automatic option resize"
    request("nvim_input", { "<Esc>30<C-W><LT>" })
    settle()
    local chosen = request("nvim_exec_lua", {
      "return { width = vim.api.nvim_win_get_width(editors[1]), col = vim.api.nvim_win_get_position(editors[1])[2] }",
      {},
    })
    assert(chosen.width == 100, "native resize did not choose the requested width")
    request("nvim_input", { "A" .. string.rep("x", 10) })
    settle()
    local manual = request("nvim_exec_lua", {
      "return { width = vim.api.nvim_win_get_width(editors[1]), col = vim.api.nvim_win_get_position(editors[1])[2], "
        .. "length = #vim.api.nvim_get_current_line(), error = vim.v.errmsg }",
      {},
    })
    assert(manual.error == "", manual.error)
    assert(manual.length == 140, "native input did not extend the requested line")
    assert(
      manual.width == chosen.width and manual.col == chosen.col,
      "manual resizing lost priority"
    )
  end, debug.traceback)

  child.close()
  assert(ok, err)
end
