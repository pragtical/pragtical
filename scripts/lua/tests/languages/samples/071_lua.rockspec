local Widget = {}
Widget.__index = Widget

function Widget:new(name)
  return setmetatable({ name = name or "demo" }, self)
end

function Widget:render(items)
  for index, item in ipairs(items) do
    if item.enabled then
      print(string.format("%d:%s", index, item.label))
    else
      goto continue
    end
    ::continue::
  end
end

return Widget:new("main")

local function configure(opts)
  local result = {}
  for key, value in pairs(opts or {}) do
    if type(value) == "string" then
      result[key] = value:upper()
    elseif value == nil then
      result[key] = false
    end
  end
  return result
end

local ok, err = pcall(function()
  return configure { mode = "debug", path = [[C:\tmp\file]] }
end)

and break do else elseif end false for function goto if in local nil not or repeat return self then true until while ;
