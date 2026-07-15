---@class List<T>
---@field first integer index of the leftmost element
---@field last integer index of the rightmost element

local List = {}

---@generic T
---@return List<T>
function List.new()
  return {first = 0, last = -1}
end

---@generic T
---@param list List<T>
---@param value T
function List.pushleft(list, value)
  local first = list.first - 1
  list.first = first
  list[first] = value
end

---@generic T
---@param list List<T>
---@param value T
function List.pushright(list, value)
  local last = list.last + 1
  list.last = last
  list[last] = value
end

---@generic T
---@param list List<T>
---@return T
function List.popleft(list)
  local first = list.first
  if first > list.last then error("list is empty") end
  local value = list[first]
  list[first] = nil
  list.first = first + 1
  return value
end

---@generic T
---@param list List<T>
---@return T
function List.popright(list)
  local last = list.last
  if list.first > last then error("list is empty") end
  local value = list[last]
  list[last] = nil
  list.last = last - 1
  return value
end

---@param list List
---@return integer
function List.length(list)
    return list.last - list.first + 1
end

return List