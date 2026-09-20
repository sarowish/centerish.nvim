if vim.g.loaded_centerish then
  return
end

vim.g.loaded_centerish = true
require("centerish.session").install()

for _, action in ipairs({ "enable", "disable", "toggle" }) do
  local command = "Centerish" .. action:sub(1, 1):upper() .. action:sub(2)
  vim.api.nvim_create_user_command(command, function()
    require("centerish")[action]()
  end, { desc = action .. " horizontal editor positioning" })
end
