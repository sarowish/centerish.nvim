-- Observe startup redraws before VimEnter and deferred activation have completed.
return function()
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
  }) do
    local grid, intro_frames, dashboard_frames = {}, 0, 0
    local dashboard_seen = false
    local enabled = scenario ~= "disabled"
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
      .. tostring(enabled)
      .. ",enable_on_tab=false}})\n"
    if scenario == "cancelled" then
      init = init
        .. [[vim.api.nvim_create_autocmd('VimEnter', {callback=function() require('centerish').disable() end})]]
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
            assert(#vim.api.nvim_tabpage_list_wins(0) == 1, 'padding blocked the dashboard')
            vim.bo.filetype = 'dashboard'
          end)
        end})
      ]]
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
    if scenario == "insert" then
      vim.list_extend(args, { "-c", "startinsert" })
    end
    local child = dofile("tests/child.lua").start({
      name = "startup intro: " .. scenario,
      args = args,
      on_notification = function(name, args)
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
            for _, row in pairs(grid) do
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
      local state = child.request("nvim_exec_lua", {
        [[
        local pads = 0
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'centerish' then pads = pads + 1 end
        end
        return {pads=pads,shortmess=vim.o.shortmess,error=vim.v.errmsg,filetype=vim.bo.filetype}
      ]],
        {},
      })
      assert(state.error == "", state.error)
      local active = enabled and scenario ~= "cancelled"
      assert((intro_frames > 0) == not active, "unexpected intro frames: " .. intro_frames)
      assert(
        (state.shortmess:find("I", 1, true) ~= nil)
          == (scenario == "hidden" or scenario:match("^intro_") ~= nil),
        "startup changed the user's intro setting"
      )
      if scenario == "options" then
        assert(state.shortmess:find("S", 1, true), "startup reverted another shortmess change")
      end
      if scenario == "dashboard" or scenario == "dashboard_direct" then
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
        local expected = active and scenario ~= "narrow" and 2 or 0
        assert(state.pads == expected, "unexpected padding count: " .. state.pads)
      end
    end, debug.traceback)
    child.close()
    assert(ok, scenario .. ": " .. tostring(err))
  end
end
