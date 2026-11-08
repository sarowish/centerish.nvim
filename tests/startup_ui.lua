-- Observe startup and new-tab frames through an attached UI.
local function check(timing)
  for _, scenario in ipairs({
    "enabled",
    "disabled",
    "hidden",
    "dashboard",
    "narrow",
    "options",
    "intro_vimenter",
    "intro_uienter",
    "intro_scheduled",
    "dashboard_direct",
    "insert",
    "cancelled",
    "cancel_scheduled",
    "redraw_scheduled",
    "startup_file",
    "startup_empty",
    "tab_file",
    "tab_empty",
    "tab_filled",
  }) do
    local grid, intro_frames, dashboard_frames = {}, 0, 0
    local dashboard_seen = false
    local tab_scenario = scenario:match("^tab_") ~= nil
    local empty_scenario = scenario == "startup_empty" or scenario == "tab_empty"
    local observe_empty = not tab_scenario
    local enabled = scenario ~= "disabled" and not tab_scenario
    local editor_columns = {}
    local editor_marker = "CENTERISH_EDITOR"
    local path
    if scenario == "startup_file" or scenario == "tab_file" then
      path = vim.fn.tempname() .. ".txt"
      vim.fn.writefile({ editor_marker }, path)
    end
    local init = string.format(
      [[
      vim.opt.runtimepath:prepend(%q)
      vim.cmd('language messages C')
      vim.o.swapfile = false
      vim.opt.shortmess:remove('I')
    ]],
      vim.fn.getcwd()
    )
    if scenario == "hidden" then
      init = init .. "vim.opt.shortmess:append('I')\n"
    end
    init = init
      .. "require('centerish').setup({width=80,autocmds={enable_on_startup="
      .. vim.inspect(enabled and timing or false)
      .. ",enable_on_tab="
      .. vim.inspect(tab_scenario and timing or false)
      .. "}})\n"
    if scenario == "tab_filled" then
      init = init
        .. string.format(
          [[vim.api.nvim_create_autocmd('TabNewEntered', {callback=function()
            vim.api.nvim_buf_set_lines(0,0,-1,false,{%q})
            vim.bo.modified = false
          end})]],
          editor_marker
        )
    elseif scenario == "tab_empty" then
      init = init
        .. [[vim.api.nvim_create_autocmd('TabNewEntered', {callback=function()
          vim.rpcnotify(1, 'centerish_test_tab_entered')
        end})]]
    end
    if scenario == "cancelled" then
      init = init
        .. [[vim.api.nvim_create_autocmd('VimEnter', {callback=function() require('centerish').disable() end})]]
    elseif scenario == "cancel_scheduled" then
      init = init
        .. [[vim.api.nvim_create_autocmd('VimEnter', {callback=function()
          vim.schedule(function() require('centerish').disable() end)
        end})]]
    elseif scenario == "dashboard_direct" then
      init = init
        .. [[
        vim.api.nvim_create_autocmd('VimEnter', {callback=function()
          vim.api.nvim_buf_set_lines(0,0,-1,false,{'CENTERISH_DASHBOARD'})
          vim.bo.modified = false
          vim.bo.filetype = 'dashboard'
        end})
      ]]
    elseif scenario == "dashboard" then
      init = init
        .. [[
        vim.api.nvim_create_autocmd('VimEnter', {callback=function()
          vim.schedule(function()
            vim.g.dashboard_windows = #vim.api.nvim_tabpage_list_wins(0)
            if vim.g.dashboard_windows == 1 then vim.bo.filetype = 'dashboard' end
          end)
        end})
      ]]
    elseif scenario == "redraw_scheduled" then
      init = init
        .. [[vim.api.nvim_create_autocmd('VimEnter', {callback=function()
          vim.schedule(function() vim.cmd.redrawstatus() end)
        end})]]
    elseif scenario == "options" then
      init = init
        .. [[
        vim.api.nvim_create_autocmd('VimEnter', {callback=function()
          vim.opt.shortmess:append('S')
        end})
      ]]
    elseif scenario == "intro_vimenter" or scenario == "intro_uienter" then
      init = init
        .. string.format(
          [[
        vim.api.nvim_create_autocmd(%q, {callback=function()
          vim.opt.shortmess:append('I')
        end})
      ]],
          scenario == "intro_vimenter" and "VimEnter" or "UIEnter"
        )
    elseif scenario == "intro_scheduled" then
      init = init
        .. [[
        vim.api.nvim_create_autocmd('UIEnter', {callback=function()
          vim.schedule(function() vim.opt.shortmess:append('I') end)
        end})
      ]]
    end
    local args = { "--clean", "--embed", "-i", "NONE", "--cmd", "lua " .. init }
    if scenario == "startup_file" then
      args[#args + 1] = path
    end
    if scenario == "insert" then
      vim.list_extend(args, { "-c", "startinsert" })
    end
    local child = dofile("tests/child.lua").start({
      name = "startup UI: " .. scenario .. " (" .. tostring(timing) .. ")",
      args = args,
      on_notification = function(name, args)
        if name == "centerish_test_tab_entered" then
          observe_empty = true
        end
        if name ~= "redraw" then
          return
        end
        for _, event in ipairs(args) do
          if event[1] == "grid_clear" then
            grid = {}
          elseif event[1] == "grid_line" then
            for index = 2, #event do
              local line = event[index]
              if line[1] == 1 then
                grid[line[2]] = grid[line[2]] or {}
                local col = line[3] + 1
                for _, cell in ipairs(line[4]) do
                  for _ = 1, cell[3] or 1 do
                    grid[line[2]][col] = cell[1]
                    col = col + 1
                  end
                end
              end
            end
          elseif event[1] == "flush" then
            if empty_scenario and observe_empty then
              local col = table.concat(grid[5] or {}):find("~", 1, true)
              if col and editor_columns[#editor_columns] ~= col - 1 then
                editor_columns[#editor_columns + 1] = col - 1
              end
            end
            for _, row in pairs(grid) do
              local editor_col = table.concat(row):find(editor_marker, 1, true)
              if editor_col and editor_columns[#editor_columns] ~= editor_col - 1 then
                editor_columns[#editor_columns + 1] = editor_col - 1
              end
              if table.concat(row):find("Nvim is open source", 1, true) then
                intro_frames = intro_frames + 1
              end
              if table.concat(row):find("CENTERISH_DASHBOARD", 1, true) then
                dashboard_seen = true
              end
            end
            if scenario == "dashboard_direct" and not dashboard_seen then
              dashboard_frames = dashboard_frames + 1
            end
          end
        end
      end,
    })
    local ok, err = xpcall(function()
      child.request("nvim_ui_attach", {
        scenario == "narrow" and 90 or 240,
        40,
        { ext_linegrid = true, rgb = true },
      })
      child.settle(80)
      if tab_scenario then
        -- Native command input exposes the redraw before deferred callbacks;
        -- nvim_command can process those callbacks before flushing the screen.
        local command = scenario ~= "tab_file" and "tabnew"
          or "tabedit " .. vim.fn.fnameescape(path)
        child.request("nvim_input", { ":" .. command .. "\r" })
        child.settle(80)
      end
      if scenario == "insert" then
        assert(child.request("nvim_get_mode", {}).mode == "i", "startup lost Insert mode")
        child.request("nvim_input", { "x" })
        child.settle()
        assert(
          child.request("nvim_get_current_line", {}) == "x",
          "startup lost the first typed key"
        )
      end
      local state = child.request("nvim_exec_lua", {
        [[
        local pads = 0
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'centerish' then pads = pads + 1 end
        end
        return {pads=pads,shortmess=vim.o.shortmess,error=vim.v.errmsg,
          filetype=vim.bo.filetype,dashboard_windows=vim.g.dashboard_windows}
      ]],
        {},
      })
      assert(state.error == "", state.error)
      if scenario == "startup_file" or empty_scenario or tab_scenario then
        if timing == "immediate" then
          assert(
            #editor_columns == 1 and editor_columns[1] > 0,
            "editor moved between visible frames: " .. vim.inspect(editor_columns)
          )
        else
          assert(
            #editor_columns >= 2 and editor_columns[1] == 0 and editor_columns[#editor_columns] > 0,
            "deferred frame ordering changed: " .. vim.inspect(editor_columns)
          )
        end
      end
      local active = enabled and scenario ~= "cancelled" and scenario ~= "cancel_scheduled"
      -- Queued cancellation cannot undo intro suppression in an earlier frame.
      if scenario ~= "cancel_scheduled" then
        assert((intro_frames > 0) == not active, "unexpected intro frames: " .. intro_frames)
      end
      assert(
        (state.shortmess:find("I", 1, true) ~= nil)
          == (scenario == "hidden" or scenario:match("^intro_") ~= nil),
        "startup changed the user's intro setting"
      )
      if scenario == "options" then
        assert(state.shortmess:find("S", 1, true), "startup reverted another shortmess change")
      end
      if scenario == "dashboard" or scenario == "dashboard_direct" then
        if scenario == "dashboard" and timing == "immediate" then
          assert(
            state.dashboard_windows == 3 and state.pads == 2,
            "immediate hook ordering changed"
          )
          return
        end
        if scenario == "dashboard" then
          assert(state.dashboard_windows == 1, "padding blocked the dashboard")
        end
        if scenario == "dashboard_direct" then
          assert(dashboard_seen and dashboard_frames == 0, "blank frame before the dashboard")
        end
        assert(state.filetype == "dashboard" and state.pads == 0, "dashboard was centered")
        child.request("nvim_command", { "enew" })
        child.settle(80)
        assert(
          child.request("nvim_exec_lua", { "return #vim.api.nvim_tabpage_list_wins(0)", {} }) == 3,
          "activation did not resume after leaving the dashboard"
        )
      else
        local expected = (active and scenario ~= "narrow" or tab_scenario) and 2 or 0
        assert(state.pads == expected, "unexpected padding count: " .. state.pads)
      end
    end, debug.traceback)
    child.close()
    if path then
      vim.fn.delete(path)
    end
    assert(ok, scenario .. ": " .. tostring(err))
  end
end

return function()
  check(true)
  check("immediate")
end
