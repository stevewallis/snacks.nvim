local Async = require("snacks.picker.util.async")

---@class snacks.picker.Finder
---@field _find snacks.picker.finder
---@field task snacks.picker.Async
---@field items snacks.picker.finder.Item[]
---@field filter? snacks.picker.Filter
local M = {}
M.__index = M

---@class snacks.picker.finder.ctx
---@field picker snacks.Picker
---@field filter snacks.picker.Filter
---@field async snacks.picker.Async
---@field meta table<string, any>

---@alias snacks.picker.finder.async fun(cb:async fun(item:snacks.picker.finder.Item))
---@alias snacks.picker.finder.result snacks.picker.finder.Item[] | snacks.picker.finder.async
---@alias snacks.picker.finder fun(opts: snacks.picker.Config, ctx: snacks.picker.finder.ctx): snacks.picker.finder.result
---@alias snacks.picker.finder.multi (snacks.picker.finder|string)[]

local YIELD_FIND = 1 -- ms

---@param find snacks.picker.finder
function M.new(find)
  local self = setmetatable({}, M)
  self._find = find
  self.task = Async.nop()
  self.items = {}
  return self
end

function M:running()
  return self.task:running()
end

function M:abort()
  self.task:abort()
end

function M:count()
  return #self.items
end

function M:close()
  self.task:abort()
  self.task = Async.nop()
  self._find = function()
    return {}
  end
end

---@param picker snacks.Picker
function M:ctx(picker)
  local notified = false
  ---@type snacks.picker.finder.ctx
  local ret = {
    picker = picker,
    async = setmetatable({}, {
      __index = function()
        if not notified then
          notified = true
          Snacks.notify.warn("You can only use the `async` object in async functions")
        end
      end,
    }),
    filter = self.filter,
    meta = {},
  }
  setmetatable(ret, { __index = M:deprecated(self.filter) })
  return ret
end

---@param filter snacks.picker.Filter
---@return boolean changed
function M:init(filter)
  if self.filter and (self.filter.search == filter.search and self.filter.fid == filter.fid) then
    return false
  end
  self.filter = filter
  return true
end

---@generic T: table
---@param t T
---@return T
function M:deprecated(t)
  local notified = false
  return setmetatable({}, {
    __index = function(_, k)
      if not notified then
        notified = true
        Snacks.notify.warn({
          "# API changed",
          "",
          "- Snacks finder signature changed.",
          "```lua",
          "fun(opts: snacks.picker.Config, ctx: snacks.picker.finder.ctx)",
          "```",
        })
        Snacks.debug.backtrace()
      end
      return t[k]
    end,
  })
end

---@param picker snacks.Picker
function M:run(picker)
  local default_score = require("snacks.picker.core.matcher").DEFAULT_SCORE
  self.task:abort()
  self.items = {}
  local yield ---@type fun()
  local ctx = self:ctx(picker)
  local finder = self._find(picker.opts, ctx, self:deprecated(picker))
  local limit = picker.opts.limit or math.huge

  ---@param item snacks.picker.finder.Item
  local function add(item)
    item.idx, item.score = #self.items + 1, default_score
    self.items[item.idx] = item
  end

  if picker.opts.transform then
    local transform = Snacks.picker.config.transform(picker.opts)
    ---@param item snacks.picker.finder.Item
    function add(item)
      local t = transform(item, ctx)
      item = type(t) == "table" and t or item
      if t ~= false then
        item.idx, item.score = #self.items + 1, default_score
        self.items[item.idx] = item
      end
    end
  end

  -- PERF: if finder is a table, we can skip the async part
  if type(finder) == "table" then
    local items = finder --[[@as snacks.picker.finder.Item[] ]]
    for _, item in ipairs(items) do
      add(item)
    end
    return
  end

  collectgarbage("stop") -- moar speed
  ---@cast finder snacks.picker.finder.async
  ---@diagnostic disable-next-line: await-in-sync
  self.task = Async.new(function()
    ctx.async = Async.running()
    ---@async
    finder(function(item)
      if #self.items >= limit then
        return self.task:abort()
      end
      add(item)
      picker.matcher.task:resume()
      yield = yield or Async.yielder(YIELD_FIND)
      yield()
    end, self:deprecated(ctx.async))
  end):on("done", function()
    collectgarbage("restart")
    if not self.task:aborted() then
      picker.matcher.task:resume()
      picker:update()
    end
  end)
end

---@param finders snacks.picker.finder[]
---@return snacks.picker.finder
function M.multi(finders)
  return function(opts, ctx)
    local filter = ctx.filter
    ---@type snacks.picker.finder.result[]
    local results = {}
    local need_async = false
    for fid, finder in ipairs(finders) do
      if filter.fid == nil or filter.fid == fid then
        results[#results + 1] = finder(opts, ctx) or {}
      else
        results[#results + 1] = {}
      end
      need_async = need_async or type(results[#results]) == "function"
    end

    ---@async
    ---@type snacks.picker.finder.async
    local function collect(cb)
      for fid, find in ipairs(results) do
        if type(find) == "table" then
          for _, item in ipairs(find) do
            item.fid = fid
            cb(item)
          end
        else
          ---@async
          find(function(item)
            item.fid = fid
            cb(item)
          end)
        end
      end
    end

    if need_async then
      return collect
    end

    -- not async, so collect all items
    local items = {} ---@type snacks.picker.finder.Item[]
    collect(function(item)
      items[#items + 1] = item
    end)
    return items
  end
end

---@param finder snacks.picker.finder
---@param transform snacks.picker.transform
---@return snacks.picker.finder
function M.wrap(finder, transform)
  return function(opts, filter, picker)
    local find = finder(opts, filter, picker)
    return function(cb, task)
      ---@param item snacks.picker.finder.Item
      local function add(item)
        local t = transform(item)
        if t ~= false then
          cb(type(t) == "table" and t or item)
        end
      end
      if type(find) == "table" then
        ---@cast find snacks.picker.finder.Item[]
        for _, item in ipairs(find) do
          add(item)
        end
        return
      end
      find(add, task)
    end
  end
end

return M
