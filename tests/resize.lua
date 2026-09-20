-- Drive real keyboard input and separator drags through an attached Neovim UI.
return function()
  local mouse_events = 0
  local scenario = "initialization"
  local child = dofile("tests/child.lua").start({
    name = "resize",
    context = function()
      return scenario
    end,
    on_notification = function(name)
      if name == "resize_mouse_processed" then
        mouse_events = mouse_events + 1
      end
    end,
  })
  local request, settle = child.request, child.settle

  ---Wait until native input processing finishes before sending the next mouse event.
  ---@param action string
  ---@param col integer
  ---@param modifier? string
  local function mouse_input(action, col, modifier)
    local before = mouse_events
    request("nvim_input_mouse", { "left", action, modifier or "", 0, 5, col })
    assert(
      vim.wait(3000, function()
        return mouse_events > before or child.finished
      end),
      "mouse input was not processed: " .. scenario .. " (" .. action .. ")"
    )
    assert(not child.finished, "resize child stopped: " .. child.stderr)
  end

  local setup = [[
    local root, count, ea, fixed, padding = ...
    vim.opt.runtimepath:prepend(root)
    local centerish = require('centerish')
    centerish.disable()
    vim.cmd('silent! only!')
    vim.cmd('enew!')
    vim.o.equalalways = ea
    vim.o.mouse = 'a'
    vim.o.laststatus = 0
    vim.o.winwidth = 20
    vim.o.winminwidth = 1
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.signcolumn = 'no'
    vim.wo.winfixwidth = false
    _G.editors = { vim.api.nvim_get_current_win() }
    if count == 2 then
      vim.cmd('rightbelow vnew')
      editors[2] = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(editors[1])
    _G.snapshot = function()
      local result = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        result[#result + 1] = {
          win = win, width = vim.api.nvim_win_get_width(win),
          col = vim.api.nvim_win_get_position(win)[2],
          fixed = vim.wo[win].winfixwidth,
        }
      end
      return result
    end
    _G.resize_events = {}
    if not _G.mouse_hook then
      _G.mouse_hook = vim.on_key(function(key)
        if vim.fn.keytrans(key):match('Left[%a]+>$') then
          vim.schedule(function() vim.rpcnotify(1, 'resize_mouse_processed') end)
        end
      end, vim.api.nvim_create_namespace('centerish.resize_test'))
    end
    -- Observe native geometry before Centerish's synchronous resize handler.
    if not _G.resize_hook then
      _G.resize_hook = vim.api.nvim_create_autocmd('WinResized', {
        callback = function() resize_events[#resize_events + 1] = snapshot() end,
      })
    end
    centerish.setup({ width = 80, min_padding_width = 0, padding = padding })
    centerish.enable()
    vim.wo.winfixwidth = fixed
    _G.resize_events = {}
  ]]

  local function check()
    settle()
    local result = request("nvim_exec_lua", {
      "return { windows = snapshot(), events = resize_events, error = vim.v.errmsg }",
      {},
    })
    assert(result.error == "", result.error)
    local chosen = assert(result.events[1], "native input did not resize a window: " .. scenario)
    assert(
      vim.deep_equal(result.windows, chosen),
      "manual edges changed: " .. vim.inspect(result.windows) .. " expected " .. vim.inspect(chosen)
    )
  end

  local ok, err = xpcall(function()
    request("nvim_ui_attach", { 300, 40, { ext_linegrid = true, rgb = true } })
    for _, ea in ipairs({ false, true }) do
      for _, count in ipairs({ 1, 2 }) do
        for _, method in ipairs({ "keyboard", "mouse" }) do
          for _, index in ipairs(count == 1 and { 1 } or { 1, 2 }) do
            scenario = method
              .. " editor "
              .. index
              .. "/"
              .. count
              .. " equalalways="
              .. tostring(ea)
            request("nvim_exec_lua", { setup, { vim.fn.getcwd(), count, ea, false, {} } })
            request("nvim_exec_lua", { "vim.api.nvim_set_current_win(editors[...])", { index } })
            settle()
            for _, amount in ipairs({ 10, -20, 10 }) do
              request("nvim_exec_lua", { "resize_events = {}", {} })
              if method == "keyboard" then
                request(
                  "nvim_input",
                  { math.abs(amount) .. "<C-W>" .. (amount > 0 and ">" or "<LT>") }
                )
              else
                local boundary = request("nvim_exec_lua", {
                  "local win = editors[...]; return vim.api.nvim_win_get_position(win)[2] + vim.api.nvim_win_get_width(win)",
                  { index },
                })
                mouse_input("press", boundary)
                mouse_input("drag", boundary + amount)
                mouse_input("release", boundary + amount)
              end
              check()
            end
          end
        end
      end
    end

    -- A held drag must not snap back between successive mouse events.
    for _, mode in ipairs({ "both", "left", "right", "fixed" }) do
      scenario = "held drag: " .. mode
      local padding = { left = mode ~= "right", right = mode ~= "left" }
      request("nvim_exec_lua", { setup, { vim.fn.getcwd(), 1, false, mode == "fixed", padding } })
      settle()
      local boundary = request("nvim_exec_lua", {
        "local win = editors[1]; return vim.api.nvim_win_get_position(win)[2] + ("
          .. (mode == "left" and "-1" or "vim.api.nvim_win_get_width(win)")
          .. ")",
        {},
      })
      mouse_input("press", boundary)
      for _, amount in ipairs({ 10, 20, -10 }) do
        request("nvim_exec_lua", { "resize_events = {}", {} })
        mouse_input("drag", boundary + amount)
        check()
      end
      mouse_input("release", boundary - 10)
      settle()
    end

    -- A keyboard resize may borrow sidebar space as well as padding space.
    for _, command in ipairs({ "10<C-W>>", ":vert res +10<CR>" }) do
      scenario = "native resize beside a sidebar: " .. command
      request("nvim_ui_try_resize", { 400, 40 })
      request("nvim_exec_lua", { setup, { vim.fn.getcwd(), 1, false, false, {} } })
      request("nvim_exec_lua", {
        [[
          vim.cmd('topleft 20vnew')
          vim.bo.filetype = 'NvimTree'
          vim.wo.winfixwidth = true
          vim.api.nvim_set_current_win(editors[1])
        ]],
        {},
      })
      settle()
      request("nvim_exec_lua", { "resize_events = {}", {} })
      request("nvim_input", { command })
      check()
      local width = request("nvim_exec_lua", {
        "return vim.api.nvim_win_get_width(editors[1])",
        {},
      })
      assert(width == 90, "editor resize beside sidebar was reverted")
    end

    -- Crossing the padding threshold must keep the native drag target alive
    -- until release, including when the mouse reaches an adjacent sidebar.
    for _, drag in ipairs({
      { sidebar = false, modifier = "" },
      { sidebar = true, modifier = "" },
      { sidebar = true, modifier = "2" },
    }) do
      local with_sidebar, modifier = drag.sidebar, drag.modifier
      scenario = "held drag across minimum padding, sidebar="
        .. tostring(with_sidebar)
        .. ", click modifier="
        .. modifier
      request("nvim_ui_try_resize", { 300, 40 })
      request("nvim_exec_lua", { setup, { vim.fn.getcwd(), 1, false, false, {} } })
      request("nvim_exec_lua", {
        [[
          require('centerish').setup({ width = 80, min_padding_width = 10 })
          if ... then
            vim.cmd('topleft 20vnew')
            vim.bo.filetype = 'neo-tree'
            vim.wo.winfixwidth = true
            vim.api.nvim_set_current_win(editors[1])
          end
        ]],
        { with_sidebar },
      })
      settle()
      local boundary = request("nvim_exec_lua", {
        "return vim.api.nvim_win_get_position(editors[1])[2] - 1",
        {},
      })
      local target = request("nvim_exec_lua", {
        [[
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_position(win)[2] + vim.api.nvim_win_get_width(win) == ... then
              return win
            end
          end
        ]],
        { boundary },
      })
      assert(type(target) == "number", "left padding separator not found")
      mouse_input("press", boundary, modifier)
      for _, col in ipairs({ 5, 6, 4 }) do
        mouse_input("drag", col, modifier)
        settle()
        assert(
          request("nvim_win_is_valid", { target }),
          "padding drag target was removed while the button was held"
        )
      end
      if modifier == "2" then
        request("nvim_exec_lua", { "require('centerish').disable()", {} })
        settle()
        assert(request("nvim_win_is_valid", { target }), "disable removed a held drag target")
      end
      mouse_input("release", 4, modifier)
      settle()
      assert(request("nvim_eval", { "v:errmsg" }) == "", "error after releasing separator")
      assert(not request("nvim_win_is_valid", { target }), "undersized padding survived release")
      if modifier == "2" then
        local count = request("nvim_exec_lua", {
          [[
            local count = 0
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
              if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'centerish' then count = count + 1 end
            end
            return count
          ]],
          {},
        })
        assert(count == 0, "queued disable did not run after release")
      end
    end
  end, debug.traceback)

  child.close()
  assert(ok, err)
end
