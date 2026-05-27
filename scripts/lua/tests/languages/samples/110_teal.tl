record Item
  label: string
  enabled: boolean
end

local record Widget
  name: string
  render: function(Widget, {Item}): {string}
end

function Widget:render(items: {Item}): {string}
  local out: {string} = {}
  for _, item in ipairs(items) do
    if item.enabled then table.insert(out, self.name .. ":" .. item.label) end
  end
  return out
end
