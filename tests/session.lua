return function(stage, case, directory)
  local root = vim.fn.getcwd()
  local function equal(actual, expected)
    assert(
      vim.deep_equal(actual, expected),
      "expected " .. vim.inspect(expected) .. "\nactual " .. vim.inspect(actual)
    )
  end
  local function settle()
    vim.wait(80, function()
      return false
    end)
    assert(vim.v.errmsg == "", vim.v.errmsg)
  end

  if not stage then
    directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    for _, scenario in ipairs({
      "default",
      "real_blank",
      "multi_tabs",
      "one_side",
      "no_blank",
      "localoptions",
      "options",
      "no_tabpages",
      "adaptive",
      "manual_grow",
      "manual_shrink",
      "manual_adaptive",
      "manual_fixed",
      "changed_width",
      "already_enabled",
      "repeat_source",
      "bootstrap",
      "pending_refresh",
      "quit_save",
      "fixed_buffer_close",
      "disable_before",
      "disable_after",
      "waiting_after",
      "toggle_before",
      "toggle_after",
      "ordered_before",
      "ordered_after",
      "no_padding_before",
      "no_padding_after",
      "queued_after",
    }) do
      for _, operation in ipairs({ "save", "restore" }) do
        local command = "lua dofile("
          .. string.format("%q", root .. "/tests/session.lua")
          .. ")("
          .. string.format("%q,%q,%q", operation, scenario, directory)
          .. ")"
        local result = vim
          .system({
            vim.v.progpath,
            "--clean",
            "--headless",
            "-n",
            "-i",
            "NONE",
            "-c",
            command,
            "-c",
            "cquit 42",
          }, { text = true })
          :wait(5000)
        assert(result.code == 0, scenario .. " " .. operation .. ": " .. result.stderr)
      end
    end
    vim.fn.delete(directory, "rf")
    return
  end

  vim.opt.runtimepath:prepend(root)
  local hook_action, hook_order = case:match("^(.*)_(%a+)$")
  if hook_order ~= "before" and hook_order ~= "after" then
    hook_action, hook_order = nil, nil
  end
  local hook_called = false
  local function install_hook()
    vim.api.nvim_create_autocmd("SessionLoadPost", {
      once = true,
      callback = function()
        hook_called = true
        local restored = require("centerish")
        if hook_action == "ordered" then
          restored.disable()
          restored.enable()
          restored.toggle()
        elseif hook_action == "no_padding" then
          restored.enable()
        elseif hook_action == "disable" then
          restored.disable()
        elseif hook_action == "waiting" then
          restored.disable()
          vim.wait(20, function()
            return false
          end)
        elseif hook_action == "queued" then
          vim.wait(20, function()
            return false
          end)
        else
          restored.toggle()
        end
      end,
    })
  end
  if stage == "restore" and hook_order == "before" then
    install_hook()
  end
  vim.cmd("runtime plugin/centerish.lua")
  vim.o.columns = 400
  vim.o.lines = 50
  vim.o.swapfile = false
  local centerish
  if case ~= "bootstrap" or stage == "save" then
    centerish = require("centerish")
    centerish.setup({
      width = case == "bootstrap" and 120
        or (stage == "restore" and case == "changed_width" and 50 or 80),
      min_padding_width = 0,
      padding = { right = case ~= "one_side" },
      adaptive = { enabled = case == "adaptive" or case == "manual_adaptive" },
    })
  end
  if stage == "restore" and hook_order == "after" then
    install_hook()
  end

  ---Record ordinary windows and include chosen edges for manual session cases.
  ---@param include_geometry? boolean
  local function snapshot(include_geometry)
    local result = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      local windows, padding = {}, 0
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_get_config(win).relative == "" then
          local buf = vim.api.nvim_win_get_buf(win)
          if require("centerish.session").read(buf) then
            padding = padding + 1
            equal(vim.bo[buf].buftype, "nofile")
            equal(vim.bo[buf].buflisted, false)
            equal(vim.bo[buf].modified, false)
            equal(vim.wo[win].previewwindow, false)
          else
            windows[#windows + 1] = {
              name = vim.api.nvim_buf_get_name(buf),
              text = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
              buftype = vim.bo[buf].buftype,
              width = include_geometry and vim.api.nvim_win_get_width(win) or nil,
              col = include_geometry and vim.api.nvim_win_get_position(win)[2] or nil,
            }
          end
        end
      end
      result[#result + 1] = { windows = windows, padding = padding }
    end
    return result
  end

  local path = directory .. "/" .. case .. ".vim"
  local expected_path = directory .. "/" .. case .. ".json"
  if stage == "save" then
    local sample = directory .. "/" .. case .. "-one.txt"
    vim.fn.writefile({ "one" }, sample)
    vim.cmd.edit(sample)
    if case == "fixed_buffer_close" then
      vim.wo.winfixbuf = true
    end
    if case == "real_blank" then
      vim.cmd("rightbelow vnew")
      vim.bo.filetype = "centerish" -- Filetype alone is not padding ownership.
    end
    centerish.enable()
    if case == "multi_tabs" or case == "no_tabpages" then
      for index = 2, 3 do
        vim.cmd.tabnew()
        local file = directory .. "/" .. case .. "-" .. index .. ".txt"
        vim.fn.writefile({ tostring(index) }, file)
        vim.cmd.edit(file)
        if index == 3 then
          centerish.enable()
        end
      end
    elseif case:match("^manual_") then
      if case == "manual_adaptive" then
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 120) })
        vim.api.nvim_exec_autocmds("TextChanged", {})
        settle()
        vim.cmd.write()
      end
      settle()
      if case == "manual_fixed" then
        vim.wo.winfixwidth = true
      end
      vim.cmd(case == "manual_grow" and "10wincmd >" or "vertical resize 70")
      local chosen_col = vim.api.nvim_win_get_position(0)[2]
      vim.api.nvim_exec_autocmds("WinResized", {})
      settle()
      equal(vim.api.nvim_win_get_width(0), case == "manual_grow" and 90 or 70)
      equal(vim.api.nvim_win_get_position(0)[2], chosen_col)
    elseif case == "adaptive" then
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 120) })
      vim.api.nvim_exec_autocmds("TextChanged", {})
      settle()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "short" })
      vim.cmd.write()
      vim.api.nvim_exec_autocmds("TextChanged", {})
      settle()
      equal(vim.api.nvim_win_get_width(0), 120)
    end
    settle()
    local expected = snapshot(case:match("^manual_") ~= nil)
    if case == "no_blank" or hook_action == "no_padding" or hook_action == "queued" then
      vim.opt.sessionoptions:remove("blank")
      expected[1].padding = 0
    elseif case == "no_tabpages" then
      vim.opt.sessionoptions:remove("tabpages")
      expected = { expected[3] }
    elseif case == "localoptions" or case == "fixed_buffer_close" then
      vim.opt.sessionoptions:append("localoptions")
    elseif case == "options" or case == "quit_save" then
      vim.opt.sessionoptions:append({ "options", "skiprtp" })
    end
    vim.fn.writefile({ vim.json.encode(expected) }, expected_path)
    if case == "quit_save" then
      vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
          vim.cmd.mksession({ path, bang = true })
        end,
      })
      vim.cmd.quit()
    else
      vim.cmd.mksession({ path, bang = true })
      vim.cmd("qa!")
    end
  else
    if case == "already_enabled" or case == "pending_refresh" then
      centerish.enable()
      if case == "pending_refresh" then
        centerish.setup({ width = 80 })
      end
    elseif case == "bootstrap" then
      equal(package.loaded.centerish, nil)
    elseif hook_action == "queued" then
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "centerish",
        once = true,
        callback = function()
          centerish.enable()
        end,
      })
      centerish.enable()
    end
    vim.cmd.source(path)
    settle()
    centerish = require("centerish")
    if case == "repeat_source" then
      vim.cmd.source(path)
      settle()
    end
    local expected = vim.json.decode(table.concat(vim.fn.readfile(expected_path), "\n"))
    if hook_action then
      equal(hook_called, true)
      expected[1].padding = (hook_action == "no_padding" or hook_action == "queued") and 2 or 0
    end
    equal(snapshot(case:match("^manual_") ~= nil), expected)
    equal(vim.o.eventignore, "")
    if case:match("^manual_") then
      vim.api.nvim_exec_autocmds("TextChanged", {})
      settle()
      equal(snapshot(true), expected)
    end
    if case == "adaptive" then
      equal(vim.api.nvim_win_get_width(0), 120)
    end
    if case == "changed_width" then
      equal(vim.api.nvim_win_get_width(0), 50)
    end
    if case == "fixed_buffer_close" then
      equal(vim.wo.winfixbuf, true)
      vim.cmd("close!")
      settle()
      equal(#vim.api.nvim_tabpage_list_wins(0), 1)
      equal(vim.bo.buftype, "")
      equal(vim.bo.modifiable, true)
      equal(vim.wo.winfixbuf, true)
      equal(snapshot()[1].padding, 0)
      centerish.disable()
      settle()
      vim.cmd("qa!")
      return
    end

    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      vim.api.nvim_set_current_tabpage(tab)
      centerish.disable()
    end
    for _, tab in ipairs(expected) do
      tab.padding = 0
      for _, win in ipairs(tab.windows) do
        win.width, win.col = nil, nil
      end
    end
    settle()
    equal(snapshot(), expected)
    vim.cmd("qa!")
  end
end
