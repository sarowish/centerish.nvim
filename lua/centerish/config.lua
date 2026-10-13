local M = {}

---@alias centerish.Side "left" | "right"
---@alias centerish.GrowthDirection "right" | "both"

---@class (exact) centerish.PaddingConfig
---@field left? boolean Show left padding. Defaults to true.
---@field right? boolean Show right padding. Defaults to true.

---@class (exact) centerish.AdaptiveConfig
---@field enabled? boolean Grow to fit visible lines using padding. Defaults to false.
---@field direction? centerish.GrowthDirection Padding to consume. Defaults to "right".
---@field max_width? integer Maximum requested width per editor. Defaults to 160.

---@class (exact) centerish.SidebarConfig
---@field side centerish.Side Sidebar position.
---@field preserve_width? boolean Keep settled width across editor and screen changes. Defaults to false.

---@class centerish.ResolvedSidebarConfig: centerish.SidebarConfig
---@field preserve_width boolean

---@class (exact) centerish.Config
---@field width? integer Centered target width, including gutters. Defaults to 120.
---@field min_padding_width? integer Minimum padding width, excluding separators. Defaults to 10.
---@field padding? centerish.PaddingConfig
---@field sidebars? table<string, centerish.Side|centerish.SidebarConfig|false> Filetype settings; false disables recognition.
---@field adaptive? centerish.AdaptiveConfig

---@class centerish.MergedConfig
---@field width integer
---@field min_padding_width integer
---@field padding { left: boolean, right: boolean }
---@field sidebars table<string, centerish.Side|centerish.SidebarConfig|false>
---@field adaptive { enabled: boolean, direction: centerish.GrowthDirection, max_width: integer }

---@class centerish.ResolvedConfig: centerish.MergedConfig
---@field sidebars table<string, centerish.ResolvedSidebarConfig|false>

---@type centerish.MergedConfig
local defaults = {
  width = 120,
  min_padding_width = 10,
  padding = { left = true, right = true },
  sidebars = { NvimTree = "left", ["neo-tree"] = "left" },
  adaptive = { enabled = false, direction = "right", max_width = 160 },
}

---Merge options with fresh defaults and validate the resolved configuration.
---@param opts? centerish.Config
---@return centerish.ResolvedConfig
function M.resolve(opts)
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  assert(
    type(candidate.width) == "number" and candidate.width >= 1 and candidate.width % 1 == 0,
    "centerish: width must be a positive integer"
  )

  assert(
    type(candidate.min_padding_width) == "number"
      and candidate.min_padding_width >= 0
      and candidate.min_padding_width % 1 == 0,
    "centerish: min_padding_width must be a non-negative integer"
  )

  for _, side in ipairs({ "left", "right" }) do
    assert(type(candidate.padding[side]) == "boolean", "centerish: padding values must be booleans")
  end

  for filetype, value in pairs(candidate.sidebars) do
    if value ~= false then
      local sidebar = type(value) == "table" and value or { side = value }
      assert(
        sidebar.side == "left" or sidebar.side == "right",
        "centerish: sidebar side must be left or right"
      )
      assert(
        sidebar.preserve_width == nil or type(sidebar.preserve_width) == "boolean",
        "centerish: sidebar preserve_width must be a boolean"
      )
      candidate.sidebars[filetype] = {
        side = sidebar.side,
        preserve_width = sidebar.preserve_width == true,
      }
    end
  end

  assert(
    type(candidate.adaptive.enabled) == "boolean",
    "centerish: adaptive.enabled must be a boolean"
  )
  assert(
    candidate.adaptive.direction == "right" or candidate.adaptive.direction == "both",
    "centerish: adaptive.direction must be right or both"
  )
  assert(
    type(candidate.adaptive.max_width) == "number"
      and candidate.adaptive.max_width >= 1
      and candidate.adaptive.max_width % 1 == 0,
    "centerish: adaptive.max_width must be a positive integer"
  )

  ---@cast candidate centerish.ResolvedConfig
  return candidate
end

return M
