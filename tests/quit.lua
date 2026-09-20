return function()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local root = vim.fn.getcwd()
  local sample = directory .. "/sample.txt"
  vim.fn.writefile({ "saved" }, sample)
  for _, right in ipairs({ false, true }) do
    for _, command in ipairs({ "quit", "quit!", "wq", "qall", "qall!" }) do
      local log = directory .. "/hooks.txt"
      vim.fn.writefile({}, log)
      local code = [[
        local root, sample, log, right, force = ...
        vim.opt.runtimepath:prepend(root)
        vim.o.columns = 240
        vim.o.swapfile = false
        vim.cmd.edit(sample)
        local editor = vim.api.nvim_get_current_win()
        for _, label in ipairs({ "before", "after" }) do
          for _, event in ipairs({ "QuitPre", "ExitPre", "VimLeavePre", "VimLeave" }) do
            vim.api.nvim_create_autocmd(event, { callback = function()
              assert(vim.api.nvim_get_current_win() == editor, "shutdown changed current window")
              assert(vim.o.eventignore == "", "shutdown changed eventignore")
              vim.fn.writefile({ label .. " " .. event }, log, "a")
              vim.cmd.redraw()
            end })
          end
          if label == "before" then
            require("centerish").setup({ width = 80, padding = { right = right } })
            require("centerish").enable()
          end
        end
        if force then vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" }) end
      ]]
      local setup = "lua assert(loadstring("
        .. string.format("%q", code)
        .. "))("
        .. string.format(
          "%q,%q,%q,%s,%s",
          root,
          sample,
          log,
          tostring(right),
          tostring(command:find("!") ~= nil)
        )
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
          setup,
          "-c",
          command,
          "-c",
          "cquit 42",
        }, { text = true })
        :wait(5000)
      assert(result.code == 0, command .. ": " .. result.stderr)
      assert(
        vim.deep_equal(vim.fn.readfile(log), {
          "before QuitPre",
          "after QuitPre",
          "before ExitPre",
          "after ExitPre",
          "before VimLeavePre",
          "after VimLeavePre",
          "before VimLeave",
          "after VimLeave",
        }),
        command .. ": shutdown hook counts or order changed"
      )
    end
  end
  vim.fn.delete(directory, "rf")
end
