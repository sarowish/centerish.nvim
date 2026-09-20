local M = {}
local prefix = "centerish://padding/v1/"
local instance = tostring(vim.uv.os_getpid()) .. "-" .. string.format("%.0f", vim.uv.hrtime())
local installed = false

---Build a stable tab identity for the current plugin instance.
---@param tab integer Tabpage handle.
---@return string owner Unique identity for this tab's padding.
function M.owner(tab)
  return instance .. "-" .. tostring(tab)
end

---Decode saved padding identity, growth and manual resizing from a reserved name.
---Only empty buffers with a valid v1 name qualify as padding.
---@param buf integer Buffer handle.
---@return centerish.SessionMetadata? metadata Nil unless the buffer is reserved empty padding.
function M.read(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local owner, side, left, right, manual =
    name:match("^centerish://padding/v1/([%w%-]+)/(%a+)/(%d+)/(%d+)(.*)$")
  if not owner or (side ~= "left" and side ~= "right") then
    return
  end
  if
    vim.api.nvim_buf_line_count(buf) ~= 1 or vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= ""
  then
    return
  end
  left, right = tonumber(left), tonumber(right)
  if not left or not right or left == math.huge or right == math.huge then
    return
  end
  local adjustment, target
  if manual ~= "" then
    local adjusted_left, adjusted_right, saved_target = manual:match("^/(%-?%d+)/(%-?%d+)/(%d+)$")
    adjusted_left, adjusted_right = tonumber(adjusted_left), tonumber(adjusted_right)
    target = tonumber(saved_target)
    if
      not adjusted_left
      or not adjusted_right
      or math.abs(adjusted_left) == math.huge
      or math.abs(adjusted_right) == math.huge
      or not target
      or target < 1
      or target == math.huge
    then
      return
    end
    adjustment = { left = adjusted_left, right = adjusted_right }
  end
  return {
    owner = owner,
    side = side,
    growth = { left = left, right = right },
    adjustment = adjustment,
    target = target,
  }
end

---Configure an unlisted, noneditable buffer that Neovim wipes when hidden.
---@param buf integer Buffer handle to configure as scratch padding.
function M.buffer(buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = "centerish"
end

---Encode tab identity, padding side, growth and optional manual resizing in the name.
---Native :mksession preserves this name so a later process can recover owned padding.
---@param buf integer Padding buffer handle.
---@param owner string Identity shared by this tab's padding.
---@param side centerish.Side
---@param growth centerish.Spans Current adaptive growth to encode in the name.
---@param adjustment? centerish.Spans Manual padding changes to preserve across sessions.
---@param target? integer Editor target required when saving a manual adjustment.
function M.name(buf, owner, side, growth, adjustment, target)
  local name = prefix .. owner .. "/" .. side .. "/" .. growth.left .. "/" .. growth.right
  if adjustment then
    name = name .. "/" .. adjustment.left .. "/" .. adjustment.right .. "/" .. assert(target)
  end
  if vim.api.nvim_buf_get_name(buf) ~= name then
    vim.api.nvim_buf_set_name(buf, name)
  end
end

---Install hooks for reserved padding names and native session recovery once.
---Registering at plugin startup lets sessions recover padding before an explicit
---setup or enable call.
function M.install()
  if installed then
    return
  end
  installed = true
  local group = vim.api.nvim_create_augroup("centerish_session", { clear = true })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    pattern = prefix .. "*",
    callback = function(args)
      if M.read(args.buf) then
        M.buffer(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("SessionLoadPost", {
    group = group,
    callback = function()
      -- Loaded instances must discard old tab state and resume queued work even
      -- when this session has no saved padding.
      if package.loaded.centerish then
        require("centerish")._restore_session()
        return
      end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if
          vim.api.nvim_win_get_config(win).relative == "" and M.read(vim.api.nvim_win_get_buf(win))
        then
          require("centerish")._restore_session()
          return
        end
      end
    end,
  })
end

return M
