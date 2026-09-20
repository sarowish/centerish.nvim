return function()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  vim.fn.writefile({ "main" }, directory .. "/main.txt")
  vim.fn.writefile({ "preview" }, directory .. "/preview.txt")
  local code = [[
    local root, directory, centered, right, modified = ...
    vim.opt.runtimepath:prepend(root)
    vim.o.columns = 240
    vim.o.swapfile = false
    vim.cmd.edit(directory .. '/main.txt')
    local main = vim.api.nvim_get_current_buf()
    if centered then
      require('centerish').setup({width = 80, padding = {right = right}})
      require('centerish').enable()
    end
    vim.cmd.pedit(directory .. '/preview.txt')
    local preview
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[win].previewwindow then
        preview = vim.api.nvim_win_get_buf(win)
        break
      end
    end
    assert(preview, 'preview window did not open')
    if modified == 'main' then
      vim.api.nvim_buf_set_lines(main, 0, -1, false, {'unsaved main'})
    elseif modified == 'preview' then
      vim.api.nvim_buf_set_lines(preview, 0, -1, false, {'unsaved preview'})
    end
    vim.cmd.quit()
  ]]
  for _, modified in ipairs({ "none", "main", "preview" }) do
    for _, right in ipairs({ false, true }) do
      local native
      for _, centered in ipairs({ false, true }) do
        local command = "lua assert(loadstring("
          .. string.format("%q", code)
          .. "))("
          .. string.format(
            "%q,%q,%s,%s,%q",
            vim.fn.getcwd(),
            directory,
            tostring(centered),
            tostring(right),
            modified
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
            command,
            "-c",
            "cquit 42",
          }, { text = true })
          :wait(5000)
        if centered then
          assert(
            result.code == native,
            modified .. ": native preview quit behavior changed: " .. result.stderr
          )
        else
          native = result.code
          assert(native == (modified == "none" and 0 or 42), result.stderr)
        end
      end
    end
  end
  vim.fn.delete(directory, "rf")
end
