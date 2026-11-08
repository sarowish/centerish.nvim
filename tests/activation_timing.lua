-- Exercise the real input loop as well as independent startup/tab policies.
return function()
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "abc" }, path)
  local ok, err = xpcall(function()
    for _, timing in ipairs({ true, "immediate" }) do
      for _, scenario in ipairs({
        "startup_insert",
        "startup_insert_file",
        "tab_insert",
        "tab_insert_file",
        "startup_cancel",
        "tab_cancel",
        "terminal",
        "dashboard_startup",
        "dashboard_tab",
        "mixed",
        "scheduled_error",
      }) do
        local tab_scenario = scenario:match("^tab_") ~= nil
          or scenario == "terminal"
          or scenario == "dashboard_tab"
        local dashboard = scenario:match("^dashboard_") ~= nil
        local startup = not tab_scenario and timing or false
        local tab = tab_scenario and timing or false
        if scenario == "mixed" then
          startup = false
        end
        local init = string.format(
          [[
          vim.opt.runtimepath:prepend(%q)
          vim.o.swapfile = false
          require('centerish').setup({width=80,autocmds={enable_on_startup=%s,enable_on_tab=%s}})
        ]],
          vim.fn.getcwd(),
          vim.inspect(startup),
          vim.inspect(tab)
        )
        if dashboard then
          init = init
            .. string.format(
              [[vim.api.nvim_create_autocmd(%q, {once=true,callback=function()
                vim.api.nvim_create_autocmd('SafeState', {once=true,callback=function()
                  vim.g.dashboard_windows = #vim.api.nvim_tabpage_list_wins(0)
                  if vim.g.dashboard_windows == 1 then vim.bo.filetype = 'dashboard' end
                end})
              end})]],
              tab_scenario and "TabNewEntered" or "VimEnter"
            )
        elseif scenario == "scheduled_error" then
          init = init
            .. [[vim.api.nvim_create_autocmd('VimEnter', {once=true,callback=function()
              vim.schedule(function() error('CENTERISH_TEST_SCHEDULED_ERROR') end)
            end})]]
        elseif scenario:match("_cancel$") then
          init = init
            .. string.format(
              [[vim.api.nvim_create_autocmd(%q, {once=true,callback=function()
                vim.schedule(function() require('centerish').disable() end)
              end})]],
              tab_scenario and "TabNewEntered" or "VimEnter"
            )
        elseif scenario ~= "mixed" then
          init = init
            .. string.format(
              [[vim.api.nvim_create_autocmd(%q, {once=true,callback=function()
                vim.schedule(function() vim.cmd.startinsert() end)
              end})]],
              scenario == "terminal" and "TermOpen"
                or tab_scenario and "TabNewEntered"
                or "VimEnter"
            )
        end
        local args = { "--clean", "--embed", "-i", "NONE", "--cmd", "lua " .. init }
        if scenario == "startup_insert_file" then
          args[#args + 1] = path
        end
        local child = dofile("tests/child.lua").start({
          name = "activation timing: " .. scenario .. " (" .. tostring(timing) .. ")",
          args = args,
        })
        local passed, message = xpcall(function()
          child.request("nvim_ui_attach", { 240, 40, { ext_linegrid = true } })
          child.settle()
          if tab_scenario then
            local command = scenario == "tab_insert_file" and "tabedit " .. vim.fn.fnameescape(path)
              or "tabnew"
            if scenario == "terminal" then
              command = command .. [[ | lua vim.fn.jobstart({'/bin/sh','-c','cat'},{term=true})]]
            end
            child.request("nvim_input", { ":" .. command .. "\r" })
            child.settle()
          end
          if scenario == "mixed" then
            local states = child.request("nvim_exec_lua", {
              [[
              local startup = ...
              local tab = startup == true and 'immediate' or true
              require('centerish').setup({width=80,autocmds={enable_on_startup=startup,enable_on_tab=tab}})
              vim.api.nvim_exec_autocmds('SafeState', {})
              local first = #vim.api.nvim_tabpage_list_wins(0)
              vim.cmd.tabnew()
              vim.api.nvim_exec_autocmds('SafeState', {})
              return {first, #vim.api.nvim_tabpage_list_wins(0)}
            ]],
              { timing },
            })
            local expected = timing == true and { 1, 3 } or { 3, 1 }
            assert(
              vim.deep_equal(states, expected),
              "timing policies leaked: " .. vim.inspect(states)
            )
            child.settle()
            local counts = child.request("nvim_exec_lua", {
              [[return vim.tbl_map(function(tab) return #vim.api.nvim_tabpage_list_wins(tab) end,
                vim.api.nvim_list_tabpages())]],
              {},
            })
            assert(vim.deep_equal(counts, { 3, 3 }), "deferred fallback did not activate both tabs")
          elseif scenario:match("_cancel$") then
            assert(
              child.request("nvim_exec_lua", { "return #vim.api.nvim_tabpage_list_wins(0)", {} })
                == 1,
              "queued disable did not cancel activation"
            )
          elseif dashboard then
            local state = child.request("nvim_exec_lua", {
              "return {vim.g.dashboard_windows, #vim.api.nvim_tabpage_list_wins(0), vim.bo.filetype}",
              {},
            })
            local expected = timing == true and { 1, 1, "dashboard" } or { 3, 3, "" }
            assert(
              vim.deep_equal(state, expected),
              "dashboard hook ordering: " .. vim.inspect(state)
            )
          elseif scenario == "scheduled_error" then
            child.request("nvim_input", { "<CR>" })
            child.settle()
            local messages = child.request("nvim_exec_lua", {
              "return vim.api.nvim_exec2('messages', {output=true}).output",
              {},
            })
            assert(messages:find("CENTERISH_TEST_SCHEDULED_ERROR", 1, true), messages)
            assert(messages:find("vim.schedule", 1, true), messages)
            assert(not messages:find("SafeState Autocommands", 1, true), messages)
          else
            -- get_mode is fast. Do not run a Lua RPC before the next native key:
            -- it can itself apply a startinsert that an autocmd stranded.
            local mode = child.request("nvim_get_mode", {}).mode
            assert(mode == (scenario == "terminal" and "t" or "i"), "unexpected mode: " .. mode)
            child.request("nvim_input", { scenario == "terminal" and "XYZ\r" or "x" })
            child.settle()
            if scenario == "terminal" then
              child.request("nvim_input", { "<C-\\><C-n>" })
              child.settle()
              local lines = child.request("nvim_buf_get_lines", { 0, 0, -1, false })
              local echoes = vim.tbl_filter(function(line)
                return line:find("XYZ", 1, true) ~= nil
              end, lines)
              assert(#echoes >= 2, "terminal did not receive input: " .. vim.inspect(lines))
            else
              local line = child.request("nvim_get_current_line", {})
              local expected = scenario:match("_file$") and "xabc" or "x"
              assert(line == expected, "next key changed text incorrectly: " .. line)
            end
            assert(
              child.request("nvim_exec_lua", { "return #vim.api.nvim_tabpage_list_wins(0)", {} })
                == 3,
              "automatic activation did not finish"
            )
          end
        end, debug.traceback)
        child.close()
        assert(passed, scenario .. " (" .. tostring(timing) .. "): " .. tostring(message))
      end
    end
  end, debug.traceback)
  vim.fn.delete(path)
  assert(ok, err)
end
