return function()
  local scenario = "initialization"
  local child = dofile("tests/child.lua").start({
    name = "narrow sidebar",
    context = function()
      return scenario
    end,
  })
  local request, settle = child.request, child.settle
  local setup = [[
    local root, side, preserve = ...
    vim.opt.runtimepath:prepend(root)
    local centerish = require('centerish')
    centerish.disable()
    vim.cmd('silent! only!')
    vim.cmd('enew!')
    vim.o.equalalways = false
    vim.o.winwidth = 20
    vim.o.winminwidth = 1
    _G.editor = vim.api.nvim_get_current_win()
    vim.wo.winfixwidth = false
    vim.cmd(side == 'left' and 'topleft 40vnew' or 'botright 40vnew')
    _G.sidebar = vim.api.nvim_get_current_win()
    vim.bo.filetype = 'test-sidebar'
    vim.wo.winfixwidth = true
    centerish.setup({width = 80, min_padding_width = 0,
      sidebars = {['test-sidebar'] = preserve and {side = side, preserve_width = true} or side}})
    centerish.enable()
    _G.geometry = function()
      local pads = 0
      for _,win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'centerish' then pads = pads + 1 end
      end
      return {sidebar = vim.api.nvim_win_get_width(sidebar), editor = vim.api.nvim_win_get_width(editor),
        column = vim.api.nvim_win_get_position(editor)[2], focus = vim.api.nvim_get_current_win(),
        fixed = vim.wo[sidebar].winfixwidth, pads = pads, error = vim.v.errmsg}
    end
    vim.v.errmsg = ''
  ]]
  local direct_setup = [[
    local side, minimum, moving, fixed = ...
    require('centerish').disable()
    vim.o.winminwidth = 1
    vim.cmd('silent! only!')
    vim.cmd('enew!')
    vim.o.winminwidth = minimum
    _G.editor = vim.api.nvim_get_current_win()
    vim.wo.winfixwidth = false
    vim.cmd(side == 'left' and 'topleft 20vnew' or 'botright 20vnew')
    _G.sidebar = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(editor)
    vim.api.nvim_win_set_width(sidebar, minimum)
    vim.wo[sidebar].winfixwidth = fixed
    _G.padding = require('centerish.padding')
    _G.test_number = (_G.test_number or 0) + 1
    _G.state = {pads = {}, growth = {left = 0, right = 0}, owner = 'narrow-test-' .. test_number}
    _G.sidebars = {left = {}, right = {}}
    sidebars[side] = {sidebar}
    _G.spans = {left = 0, right = 0}
    spans[side] = minimum + 10
    _G.widths = {[sidebar] = minimum}
    if moving then
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {split = side == 'left' and 'right' or 'left', win = -1, width = 20})
      state.pads[side] = {win = win, buf = buf, options = {}}
      padding.style(state.pads[side])
    end
    vim.v.errmsg = ''
  ]]
  local ok, err = xpcall(function()
    request("nvim_ui_attach", { 315, 45, { ext_linegrid = true, ext_messages = true, rgb = true } })
    request("nvim_exec_lua", { "vim.opt.runtimepath:prepend(...)", { vim.fn.getcwd() } })
    for _, side in ipairs({ "left", "right" }) do
      for _, preserve in ipairs({ false, true }) do
        scenario = "terminal shrink and widening, " .. side .. ", preserve=" .. tostring(preserve)
        request("nvim_exec_lua", { "require('centerish').disable()", {} })
        request("nvim_ui_try_resize", { 315, 45 })
        request("nvim_exec_lua", { setup, { vim.fn.getcwd(), side, preserve } })
        settle()
        request("nvim_input", { ":vertical resize 50<CR>" })
        settle()
        request("nvim_ui_try_resize", { 20, 45 })
        settle()
        request("nvim_input", { "<C-W>" .. (side == "left" and "l" or "h") })
        settle()
        local narrow = request("nvim_exec_lua", { "return geometry()", {} })
        assert(narrow.sidebar == 1, "sidebar did not reach the split failure boundary")
        request("nvim_ui_try_resize", { 315, 45 })
        settle()
        local wide = request("nvim_exec_lua", { "return geometry()", {} })
        assert(wide.error == "", wide.error)
        assert(wide.sidebar == narrow.sidebar, "padding creation changed the sidebar width")
        assert(
          wide.editor == 80 and wide.column == 117,
          "editor did not return to its centered target"
        )
        assert(wide.pads == 2 and wide.fixed, "padding or sidebar options were not restored")
        assert(wide.focus == request("nvim_exec_lua", { "return editor", {} }), "focus changed")
      end
    end
    for _, side in ipairs({ "left", "right" }) do
      for _, minimum in ipairs({ 1, 5 }) do
        for _, moving in ipairs({ false, true }) do
          for _, fixed in ipairs({ false, true }) do
            scenario = "padding placement, "
              .. side
              .. ", minimum="
              .. minimum
              .. ", moving="
              .. tostring(moving)
              .. ", fixed="
              .. tostring(fixed)
            request("nvim_exec_lua", { direct_setup, { side, minimum, moving, fixed } })
            request("nvim_exec_lua", {
              [[
              local side, minimum, fixed = ...
              padding.apply(state, spans, sidebars, widths)
              local pad = state.pads[side].win
              assert(vim.api.nvim_win_get_width(sidebar) == minimum, 'sidebar width changed')
              assert(vim.wo[sidebar].winfixwidth == fixed, 'winfixwidth changed')
              assert(vim.api.nvim_get_current_win() == editor, 'focus changed')
              local tree = vim.fn.winlayout()
              assert(tree[1] == 'row' and #tree[2] == 3, 'split structure changed')
              assert(tree[2][2][2] == pad, 'padding was not placed between sidebar and editor')
            ]],
              { side, minimum, fixed },
            })
          end
        end
      end
    end
    for _, moving in ipairs({ false, true }) do
      for _, failure in ipairs({ "placement", "widening" }) do
        scenario = "failed padding " .. failure .. ", moving=" .. tostring(moving)
        request("nvim_exec_lua", { direct_setup, { "left", 1, moving, true } })
        request("nvim_exec_lua", {
          [[
        local moving, failure = ...
        local api = failure == 'widening' and 'nvim_win_set_width'
          or (moving and 'nvim_win_set_config' or 'nvim_open_win')
        local original = vim.api[api]
        local buffers = #vim.api.nvim_list_bufs()
        vim.api[api] = function(win, ...)
          if failure == 'widening' and win ~= sidebar then return original(win, ...) end
          error('rejected padding ' .. failure)
        end
        local ok, err = pcall(padding.apply, state, spans, sidebars, widths)
        vim.api[api] = original
        assert(not ok and tostring(err):find('rejected padding ' .. failure, 1, true), 'placement error was lost')
        assert(vim.api.nvim_win_get_width(sidebar) == 1, 'failed placement leaked the temporary width')
        assert(vim.wo[sidebar].winfixwidth, 'failed placement leaked winfixwidth')
        assert(#vim.api.nvim_list_bufs() == buffers, 'failed placement leaked a scratch buffer')
        padding.apply(state, spans, sidebars, widths)
        assert(vim.api.nvim_win_get_width(sidebar) == 1, 'placement did not recover')
      ]],
          { moving, failure },
        })
      end
    end
  end, debug.traceback)
  child.close()
  assert(ok, tostring(err) .. "\n" .. child.stderr)
end
