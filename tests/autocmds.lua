return function(scenario)
  if not scenario then
    for _, case in ipairs({
      "defaults",
      "startup",
      "startup_save",
      "startup_splits",
      "startup_tabs",
      "cancel_startup",
      "manual_early_startup",
      "manual_in_init",
      "manual_early_tab",
      "manual_tabnew",
      "tab_switch",
      "tab_close",
      "quiet_tab",
      "quiet_split",
      "callback_tab",
      "quiet_tabnew_hook",
      "nested_winnew",
      "nested_tabnew",
      "winnew_quiet",
      "winnew_plain",
      "winnew_shared",
      "ambiguous_nested",
      "api_tabs",
      "dashboard",
      "scheduled_dashboard",
      "new_tabs",
      "background",
      "reconfigure",
      "manual",
      "exclusions",
      "session",
      "session_wait",
      "validation",
    }) do
      local args = {
        vim.v.progpath,
        "--clean",
        "--headless",
        "-i",
        "NONE",
        "--cmd",
        "lua dofile('tests/autocmds.lua')(" .. string.format("%q", case) .. ")",
      }
      if case == "startup_splits" then
        vim.list_extend(args, { "-O", "README.md", "LICENSE" })
      elseif case == "startup_tabs" then
        vim.list_extend(args, { "-p", "README.md", "LICENSE" })
      end
      local result = vim.system(args, { text = true }):wait(5000)
      assert(result.code == 0, case .. ": " .. result.stderr)
    end
    return
  end

  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.columns = 240
  vim.o.lines = 40
  local centerish = require("centerish")
  local tab_scenario = scenario == "manual_early_tab"
    or scenario == "manual_tabnew"
    or scenario == "tab_switch"
    or scenario == "tab_close"
  local quiet_scenario = scenario == "quiet_tab"
    or scenario == "quiet_split"
    or scenario == "callback_tab"
  local creation_scenario = scenario == "quiet_tabnew_hook"
    or scenario == "nested_winnew"
    or scenario == "nested_tabnew"
    or scenario == "winnew_quiet"
    or scenario == "winnew_plain"
    or scenario == "winnew_shared"
  if scenario == "manual_early_startup" then
    vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = centerish.disable })
  elseif creation_scenario then
    vim.api.nvim_create_autocmd(
      (scenario == "nested_winnew" or scenario:match("^winnew_")) and "WinNew" or "TabNew",
      {
        once = true,
        nested = scenario == "nested_winnew" or scenario == "nested_tabnew",
        callback = function()
          if scenario == "winnew_shared" then
            vim.cmd("noautocmd tab split")
          else
            vim.cmd(
              (scenario == "quiet_tabnew_hook" or scenario == "winnew_quiet") and "noautocmd tabnew"
                or "tabnew"
            )
          end
        end,
      }
    )
  elseif scenario == "ambiguous_nested" then
    local ambiguous = false
    vim.api.nvim_create_autocmd("WinNew", {
      callback = function()
        if ambiguous then
          ambiguous = false
          vim.cmd("noautocmd tab split")
        end
      end,
    })
    vim.api.nvim_create_autocmd("TabNew", {
      once = true,
      nested = true,
      callback = function()
        ambiguous = true
        vim.cmd("tab split")
      end,
    })
  elseif tab_scenario then
    local origin = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_create_autocmd(scenario == "manual_tabnew" and "TabNew" or "TabNewEntered", {
      once = true,
      callback = function()
        if scenario == "tab_switch" then
          vim.api.nvim_set_current_tabpage(origin)
        elseif scenario == "tab_close" then
          vim.cmd.tabclose()
        else
          centerish.disable()
        end
      end,
    })
  end
  local options = {
    width = 80,
    autocmds = {
      enable_on_startup = scenario ~= "defaults"
        and scenario ~= "new_tabs"
        and not tab_scenario
        and not quiet_scenario
        and not creation_scenario
        and scenario ~= "ambiguous_nested"
        and scenario ~= "api_tabs",
      enable_on_tab = scenario ~= "defaults",
    },
  }
  if scenario == "exclusions" then
    options.exclude_filetypes = { "custom_dashboard" }
  end
  centerish.setup(options)
  if scenario == "startup_save" then
    local path = vim.fn.tempname() .. ".vim"
    vim.cmd.mksession({ path, bang = true })
    vim.fn.delete(path)
  end
  if scenario == "manual_in_init" then
    centerish.disable()
  end

  local function equal(actual, expected)
    assert(
      vim.deep_equal(actual, expected),
      "expected " .. vim.inspect(expected) .. "\nactual " .. vim.inspect(actual)
    )
  end
  local function pads(tab)
    local count = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab or 0)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "centerish" then
        count = count + 1
      end
    end
    return count
  end
  local function settle()
    vim.wait(30, function()
      return false
    end)
    assert(vim.v.errmsg == "", vim.v.errmsg)
  end

  local dashboard = scenario == "dashboard"
    or scenario == "background"
    or scenario == "reconfigure"
    or scenario == "manual"
    or scenario == "session_wait"
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
      if dashboard then
        vim.bo.filetype = "dashboard"
      elseif scenario == "scheduled_dashboard" then
        vim.schedule(function()
          vim.bo.filetype = "snacks_dashboard"
        end)
      elseif scenario == "exclusions" then
        vim.bo.filetype = "custom_dashboard"
      elseif scenario == "cancel_startup" then
        centerish.disable()
      end

      vim.defer_fn(function()
        local ok, err = xpcall(function()
          if scenario == "defaults" then
            equal(pads(), 0)
            vim.cmd.tabnew()
            settle()
            equal(pads(), 0)
          elseif
            scenario == "cancel_startup"
            or scenario == "manual_early_startup"
            or scenario == "manual_in_init"
          then
            equal(pads(), 0)
          elseif creation_scenario then
            equal(pads(), 0)
            vim.cmd(scenario == "winnew_shared" and "tab split" or "tabnew")
            settle()
            local tabs = vim.api.nvim_list_tabpages()
            equal(#tabs, 3)
            equal(pads(tabs[1]), 0)
            local outer = (scenario == "nested_winnew" or scenario:match("^winnew_")) and 0 or 2
            local inner = (scenario == "nested_winnew" or scenario == "nested_tabnew") and 2 or 0
            equal(pads(tabs[2]), outer)
            equal(pads(tabs[3]), inner)
            vim.cmd.tabnew()
            settle()
            equal(pads(), 2)
            equal(pads(tabs[2]), outer)
            equal(pads(tabs[3]), inner)
          elseif scenario == "ambiguous_nested" then
            vim.cmd.tabnew()
            settle()
            local tabs = vim.api.nvim_list_tabpages()
            equal(#tabs, 4)
            for index, tab in ipairs(tabs) do
              equal(pads(tab), index == 2 and 2 or 0)
            end
            vim.cmd.tabnew()
            settle()
            equal(pads(), 2)
          elseif scenario == "api_tabs" then
            equal(pads(), 0)
            if vim.api.nvim_open_tabpage then
              local first = vim.api.nvim_get_current_tabpage()
              local tab = vim.api.nvim_open_tabpage(0, false, {})
              settle()
              equal(vim.api.nvim_get_current_tabpage(), first)
              equal(pads(first), 0)
              equal(pads(tab), 2)
            end
          elseif quiet_scenario then
            local first = vim.api.nvim_get_current_tabpage()
            equal(pads(first), 0)
            if scenario == "callback_tab" then
              vim.api.nvim_create_autocmd("User", {
                pattern = "CenterishTestQuietTab",
                once = true,
                callback = function()
                  vim.cmd.tabnew()
                end,
              })
              vim.api.nvim_exec_autocmds("User", { pattern = "CenterishTestQuietTab" })
            else
              vim.cmd(scenario == "quiet_split" and "noautocmd tab split" or "noautocmd tabnew")
            end
            local quiet = vim.api.nvim_get_current_tabpage()
            vim.cmd.vnew()
            vim.cmd.tabnew()
            settle()
            equal(pads(first), 0)
            equal(pads(quiet), 0)
            equal(pads(), 2)
          elseif tab_scenario then
            equal(pads(), 0)
            local first = vim.api.nvim_get_current_tabpage()
            vim.cmd.tabnew()
            settle()
            local tabs = vim.api.nvim_list_tabpages()
            equal(#tabs, scenario == "tab_close" and 1 or 2)
            equal(pads(first), 0)
            if scenario == "tab_switch" then
              equal(vim.api.nvim_get_current_tabpage(), first)
              equal(pads(tabs[2]), 2)
            else
              equal(pads(), 0)
            end
          elseif scenario == "startup_tabs" then
            local tabs = vim.api.nvim_list_tabpages()
            equal(#tabs, 2)
            local current = vim.api.nvim_get_current_tabpage()
            for _, tab in ipairs(tabs) do
              equal(pads(tab), tab == current and 2 or 0)
            end
          elseif
            scenario == "startup"
            or scenario == "startup_save"
            or scenario == "startup_splits"
          then
            equal(pads(), 2)
            if scenario == "startup_splits" then
              local files = {}
              for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                local buf = vim.api.nvim_win_get_buf(win)
                if vim.bo[buf].filetype ~= "centerish" then
                  files[#files + 1] = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
                end
              end
              table.sort(files)
              equal(files, { "LICENSE", "README.md" })
            end
            centerish.disable()
            vim.cmd.enew()
            settle()
            equal(pads(), 0)
          elseif scenario == "dashboard" then
            equal(pads(), 0)
            local main = vim.api.nvim_get_current_win()
            local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
              relative = "editor",
              row = 1,
              col = 1,
              width = 20,
              height = 5,
            })
            settle()
            equal(pads(), 0)
            vim.api.nvim_win_close(float, true)
            vim.cmd("topleft 20vnew")
            local tree = vim.api.nvim_get_current_win()
            vim.bo.filetype = "NvimTree"
            settle()
            equal(pads(), 0)
            vim.api.nvim_win_close(tree, true)
            vim.cmd("rightbelow vnew")
            vim.api.nvim_set_current_win(main)
            settle()
            equal(pads(), 2)
            equal(vim.api.nvim_get_current_win(), main)
          elseif scenario == "scheduled_dashboard" then
            equal(pads(), 0)
            -- A filetype change can make the same buffer eligible without BufEnter.
            vim.bo.filetype = "lua"
            settle()
            equal(pads(), 2)
          elseif scenario == "new_tabs" then
            equal(pads(), 0)
            local first = vim.api.nvim_get_current_tabpage()
            vim.cmd.tabnew()
            vim.bo.filetype = "alpha"
            settle()
            equal(pads(), 0)
            vim.cmd.enew()
            settle()
            equal(pads(), 2)
            local second = vim.api.nvim_get_current_tabpage()
            centerish.disable()
            vim.api.nvim_set_current_tabpage(first)
            vim.api.nvim_set_current_tabpage(second)
            settle()
            equal(pads(), 0)
            vim.cmd.tabnew()
            vim.cmd.tabclose()
            settle()
            equal(pads(), 0)
          elseif scenario == "background" then
            equal(pads(), 0)
            local first, buf = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_buf()
            vim.cmd.tabnew()
            local focused = vim.api.nvim_get_current_win()
            vim.bo[buf].filetype = "lua"
            settle()
            equal(pads(first), 2)
            equal(pads(), 2)
            equal(vim.api.nvim_get_current_win(), focused)
          elseif scenario == "reconfigure" then
            equal(pads(), 0)
            centerish.setup({})
            vim.cmd.enew()
            settle()
            equal(pads(), 0)
            centerish.setup({ width = 80, autocmds = { enable_on_startup = true } })
            settle()
            equal(pads(), 2)
            vim.cmd.tabnew()
            settle()
            equal(pads(), 0)
          elseif scenario == "manual" then
            equal(pads(), 0)
            centerish.disable()
            vim.bo.filetype = "lua"
            settle()
            equal(pads(), 0)
            vim.bo.filetype = "dashboard"
            centerish.toggle()
            settle()
            equal(pads(), 2)
            centerish.toggle()
            vim.cmd.enew()
            settle()
            equal(pads(), 0)
          elseif scenario == "exclusions" then
            equal(pads(), 0)
            centerish.setup({
              width = 80,
              autocmds = { enable_on_startup = true },
              exclude_filetypes = {},
            })
            settle()
            equal(pads(), 2)
          elseif scenario == "session" then
            equal(pads(), 2)
            vim.cmd.tabnew()
            settle()
            centerish.disable()
            local path = vim.fn.tempname() .. ".vim"
            vim.cmd.mksession({ path, bang = true })
            vim.cmd.source(path)
            settle()
            vim.fn.delete(path)
            local tabs = vim.api.nvim_list_tabpages()
            equal(#tabs, 2)
            equal(pads(tabs[1]), 2)
            equal(pads(tabs[2]), 0)
          elseif scenario == "session_wait" then
            equal(pads(), 0)
            local path = vim.fn.tempname() .. ".vim"
            vim.cmd.mksession({ path, bang = true })
            vim.cmd.source(path)
            settle()
            vim.fn.delete(path)
            vim.cmd.enew()
            settle()
            equal(pads(), 0)
          elseif scenario == "validation" then
            for _, opts in ipairs({
              { autocmds = false },
              { autocmds = { enable_on_startup = "yes" } },
              { autocmds = { enable_on_tab = 1 } },
              { exclude_filetypes = false },
              { exclude_filetypes = { dashboard = true } },
              { exclude_filetypes = { "dashboard", 1 } },
            }) do
              local valid, message = pcall(centerish.setup, opts)
              equal(valid, false)
              assert(tostring(message):find("centerish:", 1, true), tostring(message))
            end
          end
        end, debug.traceback)
        if not ok then
          io.stderr:write(err .. "\n")
          vim.cmd("cquit 1")
        end
        vim.cmd("qa!")
      end, 30)
    end,
  })
end
