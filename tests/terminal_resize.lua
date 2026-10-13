-- Resize the attached UI while another layout callback sizes a full-width editor.
local function run(callback_first)
  local scenario = "initialization"
  local child = dofile("tests/child.lua").start({
    name = "terminal resize",
    context = function()
      return scenario
    end,
  })
  local request, settle = child.request, child.settle
  local setup = [[
    local root, side, padding, callback_first, preserve = ...
    vim.opt.runtimepath:prepend(root)
    _G.native_set_width = _G.native_set_width or vim.api.nvim_win_set_width
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
    _G.wanted_width = 40
    _G.layout_mode = nil
    _G.switch_buffer = nil
    _G.defer_twice = false
    _G.native_buffer_resize = false
    local function install_layout()
      if _G.layout_hook then return end
      _G.layout_hook = vim.api.nvim_create_autocmd('VimResized', {
        callback = function()
          if layout_mode == 'snapshot' then
            local sizes = {}
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
              sizes[#sizes + 1] = { win, vim.api.nvim_win_get_width(win) }
            end
            local completed = 0
            local ok, err = pcall(function()
              for _, item in ipairs(sizes) do
                vim.api.nvim_win_set_width(item[1], item[2])
                completed = completed + 1
              end
            end)
            loop_results[#loop_results + 1] = { ok = ok, error = err, completed = completed, total = #sizes }
            return
          end
          vim.api.nvim_win_set_width(sidebar, wanted_width)
          vim.api.nvim_win_set_width(editor, vim.o.columns - wanted_width - 1)
        end,
      })
    end
    local function install_buffer_layout()
      if _G.buffer_layout_hook then return end
      _G.buffer_layout_hook = vim.api.nvim_create_autocmd('BufWinEnter', {
        callback = function(event)
          if event.buf ~= switch_buffer then return end
          vim.schedule(function()
            local resize = function()
              if native_buffer_resize then
                local current = vim.api.nvim_get_current_win()
                vim.api.nvim_set_current_win(sidebar)
                vim.cmd('vertical resize ' .. wanted_width)
                vim.api.nvim_set_current_win(current)
              else
                vim.api.nvim_win_set_width(sidebar, wanted_width)
              end
            end
            if defer_twice then vim.schedule(resize) else resize() end
          end)
        end,
      })
    end
    if callback_first then install_layout(); install_buffer_layout() end
    centerish.setup({
      width = 120, min_padding_width = 20, padding = padding,
      sidebars = { ['test-sidebar'] = preserve and { side = side, preserve_width = true } or side },
    })
    if not callback_first then install_layout(); install_buffer_layout() end
    centerish.enable()
    _G.geometry = function()
      return {
        sidebar = vim.api.nvim_win_get_width(sidebar),
        editor = vim.api.nvim_win_get_width(editor),
        focus = vim.api.nvim_get_current_win(),
        fixed = vim.wo[sidebar].winfixwidth,
        error = vim.v.errmsg,
      }
    end
    vim.v.errmsg = ''
  ]]
  local ok, err = xpcall(function()
    request("nvim_ui_attach", { 315, 45, { ext_linegrid = true, rgb = true } })
    for _, side in ipairs({ "left", "right" }) do
      for _, padding in ipairs({
        { left = true, right = true },
        { left = true, right = false },
        { left = false, right = true },
      }) do
        scenario = side .. ", callback first=" .. tostring(callback_first) .. vim.inspect(padding)
        request("nvim_ui_try_resize", { 315, 45 })
        settle()
        request("nvim_exec_lua", { setup, { vim.fn.getcwd(), side, padding, callback_first } })
        settle()
        for _, size in ipairs({ { 300, 45 }, { 400, 45 }, { 240, 45 }, { 315, 45 }, { 315, 35 } }) do
          request("nvim_ui_try_resize", size)
          settle()
          local geometry = request("nvim_exec_lua", { "return geometry()", {} })
          assert(geometry.error == "", geometry.error)
          assert(geometry.sidebar == 40, "sidebar collapsed: " .. scenario .. vim.inspect(geometry))
          assert(geometry.fixed, "sidebar lost winfixwidth")
          local sidebar = request("nvim_exec_lua", { "return sidebar", {} })
          assert(geometry.focus == sidebar, "terminal resizing changed focus")
        end
        -- An explicit plugin width request still wins with preservation off.
        request("nvim_input", { ":vertical resize 50<CR>" })
        settle()
        request("nvim_ui_try_resize", { 300, 45 })
        settle()
        assert(request("nvim_exec_lua", { "return geometry().sidebar", {} }) == 40)
        request("nvim_exec_lua", { "wanted_width = 15", {} })
        request("nvim_ui_try_resize", { 315, 45 })
        settle()
        assert(request("nvim_exec_lua", { "return geometry().sidebar", {} }) == 15)
      end
    end
    scenario = "preservation enabled, callback first=" .. tostring(callback_first)
    request("nvim_exec_lua", {
      setup,
      { vim.fn.getcwd(), "left", { left = true, right = true }, callback_first, true },
    })
    settle()
    request("nvim_input", { ":vertical resize 50<CR>" })
    settle()
    for _, size in ipairs({ { 300, 45 }, { 315, 45 }, { 315, 35 } }) do
      request("nvim_ui_try_resize", size)
      settle()
      assert(request("nvim_exec_lua", { "return geometry().sidebar", {} }) == 50)
    end
    scenario = "resize callback iterating window handles, callback first="
      .. tostring(callback_first)
    request("nvim_exec_lua", { "layout_mode = 'snapshot'; loop_results = {}", {} })
    request("nvim_ui_try_resize", { 315, 45 })
    settle()
    local results = request("nvim_exec_lua", { "return loop_results", {} })
    assert(#results > 0, "snapshot callback did not run")
    for _, result in ipairs(results) do
      assert(result.ok, "window iteration failed: " .. tostring(result.error))
      assert(result.completed == result.total, "a width request invalidated a later window")
    end
    request("nvim_exec_lua", { "layout_mode = nil", {} })
    request("nvim_exec_lua", { "require('centerish').disable(); wanted_width = 40", {} })
    settle()
    request("nvim_ui_try_resize", { 300, 45 })
    settle()
    assert(request("nvim_exec_lua", { "return geometry().sidebar", {} }) == 40)

    for _, side in ipairs({ "left", "right" }) do
      for _, preserve in ipairs({ false, true }) do
        for _, method in ipairs({ "resize_first", "navigation_first", "mapping" }) do
          scenario = "manual sidebar resize and buffer switch, "
            .. side
            .. ", preserve="
            .. tostring(preserve)
            .. ", method="
            .. method
          request("nvim_exec_lua", {
            setup,
            { vim.fn.getcwd(), side, { left = true, right = true }, callback_first, preserve },
          })
          settle()
          local buf =
            request("nvim_exec_lua", { "return vim.api.nvim_create_buf(true, false)", {} })
          local command = "vertical resize 50 | wincmd "
            .. (side == "left" and "l" or "h")
            .. " | buffer "
            .. buf
          if method == "navigation_first" then
            request("nvim_exec_lua", { "vim.api.nvim_set_current_win(editor)", {} })
            settle()
            command = "wincmd " .. (side == "left" and "h" or "l") .. " | " .. command
          end
          if method == "mapping" then
            request("nvim_exec_lua", {
              "local command = ...; vim.keymap.set('n', '<F6>', function() vim.cmd(command) end)",
              { command },
            })
            request("nvim_input", { "<F6>" })
          else
            request("nvim_input", { ":" .. command .. "<CR>" })
          end
          settle()
          assert(request("nvim_exec_lua", { "return geometry().sidebar", {} }) == 50, scenario)
          assert(request("nvim_exec_lua", { "return vim.api.nvim_win_get_buf(editor)", {} }) == buf)
        end
      end
    end

    for _, side in ipairs({ "left", "right" }) do
      for _, preserve in ipairs({ false, true }) do
        for _, method in ipairs({ "vimscript", "cached_api" }) do
          scenario = "idle width request followed by "
            .. method
            .. ", "
            .. side
            .. ", preserve="
            .. tostring(preserve)
          request("nvim_exec_lua", {
            setup,
            { vim.fn.getcwd(), side, { left = true, right = true }, callback_first, preserve },
          })
          settle()
          request("nvim_exec_lua", { "vim.api.nvim_win_set_width(sidebar, 40)", {} })
          settle()
          request("nvim_exec_lua", {
            [[
              local method = ...
              if method == 'cached_api' then native_set_width(sidebar, 50)
              else vim.api.nvim_win_call(sidebar, function() vim.cmd('vertical resize 50') end) end
            ]],
            { method },
          })
          settle()
          assert(request("nvim_exec_lua", { "return geometry().sidebar", {} }) == 50, scenario)
        end
      end
    end

    for _, preserve in ipairs({ false, true }) do
      for _, twice in ipairs({ false, true }) do
        for _, focus_editor in ipairs({ false, true }) do
          for _, native in ipairs({ false, true }) do
            scenario = "deferred sidebar resize, callback first="
              .. tostring(callback_first)
              .. ", preserve="
              .. tostring(preserve)
              .. ", twice="
              .. tostring(twice)
              .. ", editor focused="
              .. tostring(focus_editor)
              .. ", native sizing="
              .. tostring(native)
            request("nvim_exec_lua", {
              setup,
              { vim.fn.getcwd(), "left", { left = true, right = true }, callback_first, preserve },
            })
            settle()
            request("nvim_input", { ":vertical resize 50<CR>" })
            settle()
            request("nvim_exec_lua", {
              [[
              local twice, focus, native = ...
              switch_buffer = vim.api.nvim_create_buf(true, false)
              defer_twice = twice
              native_buffer_resize = native
              if focus then vim.api.nvim_set_current_win(editor) end
              vim.api.nvim_win_set_buf(editor, switch_buffer)
            ]],
              { twice, focus_editor, native },
            })
            settle(200)
            assert(
              request("nvim_exec_lua", { "return geometry().sidebar", {} })
                == (preserve and 50 or 40),
              scenario
            )
            -- Once the file switch is idle, an independent Lua resize remains allowed.
            request("nvim_exec_lua", { "vim.api.nvim_win_set_width(sidebar, 55)", {} })
            settle()
            assert(request("nvim_exec_lua", { "return geometry().sidebar", {} }) == 55, scenario)
          end
        end
      end
    end
  end, debug.traceback)
  child.close()
  assert(ok, tostring(err) .. "\n" .. child.stderr)
end

return function()
  for _, callback_first in ipairs({ true, false }) do
    run(callback_first)
  end
end
