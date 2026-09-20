local M = {}

---@class centerish.PaddingGeometry
---@field columns integer Screen width.
---@field editor_width integer Target span of the complete editor tree.
---@field sidebars centerish.Spans Sidebar widths including separators.
---@field growth centerish.Spans Previously consumed padding.
---@field enabled { left: boolean, right: boolean } Padding sides to keep.
---@field minimum_span integer Minimum padding width including its separator.

---@class centerish.PaddingLimits
---@field enabled { left: boolean, right: boolean } Padding sides to keep.
---@field available integer Maximum combined padding span after reserving editor and sidebar space.
---@field minimum_span integer Minimum padding width including its separator.

---Calculate centered padding spans, including each pad's separator.
---Account for sidebars and saved growth, then omit pads below the minimum width.
---@param geometry centerish.PaddingGeometry
---@return centerish.Spans
function M.padding(geometry)
  local columns, editor_width = geometry.columns, geometry.editor_width
  local sidebars, growth = geometry.sidebars, geometry.growth
  local spare = math.max(0, columns - editor_width)
  local left = math.floor(spare / 2)
  local right = spare - left

  -- Always calculate the centered margins. A disabled padding side gives its
  -- space to the editor without changing the opposite margin.
  local padding = {
    left = geometry.enabled.left and math.max(0, left - sidebars.left - growth.left) or 0,
    right = geometry.enabled.right and math.max(0, right - sidebars.right - growth.right) or 0,
  }

  -- A sidebar wider than its margin also consumes space on the other side.
  -- Drop that padding before reducing the editor below its target width.
  local available = math.max(0, columns - editor_width - sidebars.left - sidebars.right)
  local excess = math.max(0, padding.left + padding.right - available)
  local side = sidebars.left > left and "right" or "left"
  padding[side] = math.max(0, padding[side] - excess)

  for key, value in pairs(padding) do
    if value < geometry.minimum_span then
      padding[key] = 0
    end
  end

  return padding
end

---Apply manual offsets to baseline padding without changing the input spans.
---Reduce right padding first when space is limited, then omit pads below the minimum width.
---@param padding centerish.Spans
---@param adjustment centerish.Spans Manual changes relative to the baseline padding.
---@param limits centerish.PaddingLimits
---@return centerish.Spans
function M.adjust_padding(padding, adjustment, limits)
  local result = {
    left = limits.enabled.left and math.max(0, padding.left + adjustment.left) or 0,
    right = limits.enabled.right and math.max(0, padding.right + adjustment.right) or 0,
  }
  local excess = math.max(0, result.left + result.right - limits.available)
  for _, key in ipairs({ "right", "left" }) do
    local removed = math.min(excess, result[key])
    result[key] = result[key] - removed
    excess = excess - removed
    if result[key] < limits.minimum_span then
      result[key] = 0
    end
  end

  return result
end

---Measure the editor span in a split tree using the supplied widths.
---Side-by-side editors add their widths and separators; stacked editors share
---the widest span. Leaves outside the editor set do not contribute.
---@param node vim.fn.winlayout.ret Current tab's layout.
---@param editors centerish.WindowSet
---@param width integer|centerish.WidthMap A shared width or a map containing every editor's width.
---@return integer
function M.editor_width(node, editors, width)
  if node[1] == "leaf" then
    return (editors[node[2]] and (type(width) == "table" and width[node[2]] or width) or 0) --[[@as integer]]
  end

  ---@cast node vim.fn.winlayout.branch
  local total, count = 0, 0
  for _, child in ipairs(node[2]) do
    local child_width = M.editor_width(child, editors, width)
    if child_width > 0 then
      count = count + 1
      if node[1] == "row" then
        total = total + child_width
      else
        total = math.max(total, child_width)
      end
    end
  end

  return total + (node[1] == "row" and math.max(0, count - 1) or 0)
end

---Extract the editors' layout while preserving their split order.
---Collapse single-child branches and return nil when no editor leaves remain.
---@param node vim.fn.winlayout.ret
---@param editors centerish.WindowSet
---@return vim.fn.winlayout.leaf|vim.fn.winlayout.branch|nil
function M.editors(node, editors)
  if node[1] == "leaf" then
    return editors[node[2]] and { "leaf", node[2] } or nil
  end
  ---@cast node vim.fn.winlayout.branch
  ---@type (vim.fn.winlayout.leaf|vim.fn.winlayout.branch)[]
  local children = {}
  for _, child in ipairs(node[2]) do
    local kept = M.editors(child, editors)
    if kept then
      children[#children + 1] = kept
    end
  end
  if #children == 1 then
    return children[1]
  end
  return #children > 0 and { node[1], children } or nil
end

---Allocate the available editor span while preserving existing split proportions.
---Respect fixed and minimum widths when space permits; stacked editors receive
---the same span. Return a map of allocated widths for each editor window.
---@param node vim.fn.winlayout.ret Editor-only layout.
---@param current centerish.WidthMap Widths before Neovim redistributes space.
---@param fixed centerish.WindowSet
---@param minimum integer
---@param width integer
---@return centerish.WidthMap
function M.fit(node, current, fixed, minimum, width)
  local result = {}
  ---Measure a branch's minimum span and whether it can change width.
  ---Count fixed widths only when honor_fixed is true.
  local function measure(tree, honor_fixed)
    if tree[1] == "leaf" then
      local pinned = honor_fixed and fixed[tree[2]]
      return pinned and current[tree[2]] or minimum, not pinned
    end
    local span, flexible = 0, tree[1] == "col"
    for _, child in ipairs(tree[2]) do
      local size, elastic = measure(child, honor_fixed)
      if tree[1] == "row" then
        span = span + size
        flexible = flexible or elastic
      else
        span = math.max(span, size)
        flexible = flexible and elastic
      end
    end
    return span + (tree[1] == "row" and #tree[2] - 1 or 0), flexible
  end

  if measure(node, false) > width then
    minimum = 1
  end

  ---Measure a branch's current span for proportional allocation.
  local function span(tree)
    if tree[1] == "leaf" then
      return current[tree[2]]
    end
    local size = 0
    for _, child in ipairs(tree[2]) do
      size = tree[1] == "row" and size + span(child) or math.max(size, span(child))
    end
    return size + (tree[1] == "row" and #tree[2] - 1 or 0)
  end

  ---Write this branch's allocated widths into the result map.
  ---Clamp constrained branches before dividing the remaining space proportionally.
  local function allocate(tree, available)
    if tree[1] == "leaf" then
      result[tree[2]] = math.max(1, available)
      return
    end
    if tree[1] == "col" then
      for _, child in ipairs(tree[2]) do
        allocate(child, available)
      end
      return
    end

    local honor_fixed = measure(tree, true) <= available
    local remaining = available - #tree[2] + 1
    local active, sizes = {}, {}
    for index, child in ipairs(tree[2]) do
      local floor, flexible = measure(child, honor_fixed)
      if flexible then
        active[#active + 1] = { index = index, floor = floor, weight = span(child) }
      else
        sizes[index] = floor
        remaining = remaining - floor
      end
    end

    -- Clamp narrow branches before distributing the rest proportionally.
    while #active > 0 do
      local weight = 0
      for _, child in ipairs(active) do
        weight = weight + child.weight
      end
      local clamped = false
      for index = #active, 1, -1 do
        local child = active[index]
        if remaining * child.weight / weight < child.floor then
          sizes[child.index] = child.floor
          remaining = remaining - child.floor
          table.remove(active, index)
          clamped = true
          break
        end
      end
      if not clamped then
        local fractions, spent = {}, 0
        for _, child in ipairs(active) do
          local share = remaining * child.weight / weight
          sizes[child.index] = math.floor(share)
          spent = spent + sizes[child.index]
          fractions[#fractions + 1] = { index = child.index, value = share - sizes[child.index] }
        end
        table.sort(fractions, function(a, b)
          return a.value == b.value and a.index < b.index or a.value > b.value
        end)
        for index = 1, remaining - spent do
          local child = fractions[index]
          sizes[child.index] = sizes[child.index] + 1
        end
        remaining = 0
        break
      end
    end
    if remaining > 0 then
      sizes[#tree[2]] = sizes[#tree[2]] + remaining
    end
    for index, child in ipairs(tree[2]) do
      allocate(child, sizes[index])
    end
  end

  allocate(node, width)
  return result
end

---Choose how much padding to consume for the requested editor growth.
---Right mode uses the right pad; both mode takes equal amounts from each side.
---@param padding centerish.Spans
---@param needed integer
---@param direction centerish.GrowthDirection
---@return centerish.Spans
function M.grow(padding, needed, direction)
  if direction == "right" then
    return { left = 0, right = math.min(needed, padding.right) }
  end

  local each = math.min(math.ceil(needed / 2), padding.left, padding.right)
  return { left = each, right = each }
end

---Determine whether an editor branch can grow without resizing a fixed window.
---A row needs one flexible child; every child in a stacked column must be flexible.
---@param node vim.fn.winlayout.ret Editor-only layout.
---@param fixed centerish.WindowSet
---@return boolean
local function flexible(node, fixed)
  if node[1] == "leaf" then
    return not fixed[node[2]]
  end
  ---@cast node vim.fn.winlayout.branch
  for _, child in ipairs(node[2]) do
    local elastic = flexible(child, fixed)
    if node[1] == "row" and elastic then
      return true
    elseif node[1] == "col" and not elastic then
      return false
    end
  end
  return node[1] == "col"
end

---Suppress adaptive requests for fixed editors and columns sharing a fixed span.
---@param node vim.fn.winlayout.ret Editor-only layout.
---@param current centerish.WidthMap
---@param desired centerish.WidthMap
---@param fixed centerish.WindowSet
---@param result? centerish.WidthMap
---@return centerish.WidthMap
function M.constrain_growth(node, current, desired, fixed, result)
  result = result or {}
  if not flexible(node, fixed) then
    desired = current
  end
  if node[1] == "leaf" then
    result[node[2]] = desired[node[2]]
  else
    ---@cast node vim.fn.winlayout.branch
    for _, child in ipairs(node[2]) do
      M.constrain_growth(child, current, desired, fixed, result)
    end
  end
  return result
end

---Allocate reclaimed padding through the current split tree.
---Stacked editors share a width; rows fund requested growth before assigning
---rounding space to their last flexible branch.
---@param node vim.fn.winlayout.ret Current tab's layout.
---@param editors centerish.WindowSet
---@param current centerish.WidthMap
---@param desired centerish.WidthMap
---@param width integer Total available editor span, including internal separators.
---@param fixed centerish.WindowSet
---@param result? centerish.WidthMap
---@return centerish.WidthMap
function M.allocate(node, editors, current, desired, width, fixed, result)
  result = result or {}
  if node[1] == "leaf" then
    if editors[node[2]] then
      result[node[2]] = width
    end
    return result
  end

  ---@cast node vim.fn.winlayout.branch
  local children = {}
  for _, child in ipairs(node[2]) do
    local size = M.editor_width(child, editors, current)
    if size > 0 then
      table.insert(children, { node = child, width = size, flexible = flexible(child, fixed) })
    end
  end

  local spare = math.max(0, width - M.editor_width(node, editors, current))
  for _, child in ipairs(children) do
    if node[1] == "col" then
      child.width = width
    else
      local wanted = M.editor_width(child.node, editors, desired) - child.width
      local extra = child.flexible and math.min(spare, math.max(0, wanted)) or 0
      child.width = child.width + extra
      spare = spare - extra
    end
  end
  if node[1] == "row" and spare > 0 then
    for index = #children, 1, -1 do
      if children[index].flexible then
        children[index].width = children[index].width + spare
        break
      end
    end
  end
  for _, child in ipairs(children) do
    M.allocate(child.node, editors, current, desired, child.width, fixed, result)
  end

  return result
end

return M
