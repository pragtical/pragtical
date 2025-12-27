---Base class providing OOP functionality for Lua.
---All classes in Pragtical inherit from Object.
---@class core.object
---@overload fun():core.object
---@field super core.object
local Object = {}
Object.__index = Object

---Constructor called when creating new instances.
---Override in subclasses to initialize state. Always call super first:
---`MyClass.super.new(self)`
---Can be overridden by child objects to implement a constructor.
function Object:new() end


---Create a new class that inherits from this one.
---Returns a new class with this class as its parent.
---Example: `local MyClass = Object:extend()`
---@return core.object cls The new class table
function Object:extend()
  local cls = {}
  for k, v in pairs(self) do
    if k:find("__") == 1 then
      cls[k] = v
    end
  end
  cls.__index = cls
  cls.super = self
  setmetatable(cls, self)
  return cls
end


---Check if object is exactly of the given type (no inheritance check).
---Use this for strict type matching.
---Example: `view:is(DocView)` returns true only if view is a DocView, not a subclass
---@param T any Class to check against
---@return boolean is_exact True if object is exactly type T
function Object:is(T)
  return getmetatable(self) == T
end

---Check if the given object is exactly an instance of this class.
---Inverse of is() - checks if T is an instance of self.
---Example: `DocView:is_class_of(obj)` checks if obj is exactly a DocView
---@param T any Object to check
---@return boolean is_instance True if T is exactly an instance of this class
function Object:is_class_of(T)
  return getmetatable(T) == self
end


---Check if object inherits from the given type (inheritance-aware).
---Use this to check class hierarchy.
---Example: `view:extends(View)` returns true for View and all subclasses
---@param T any Class to check inheritance from
---@return boolean extends True if object is T or inherits from T
function Object:extends(T)
  local mt = getmetatable(self)
  while mt do
    if mt == T then
      return true
    end
    mt = getmetatable(mt)
  end
  return false
end


---Check if the given object/class inherits from this class.
---Inverse of extends() - checks if T is a subclass of self.
---Example: `View:is_extended_by(DocView)` checks if DocView inherits from View
---@param T any Object or class to check
---@return boolean is_extended True if T inherits from this class
function Object:is_extended_by(T)
  local mt = getmetatable(T)
  while mt do
    if mt == self then
      return true
    end
    local _mt = getmetatable(T)
    if mt == _mt then break end
    mt = _mt
  end
  return false
end


---Get string representation of the object (for debugging/logging).
---Override in subclasses to provide meaningful names.
---Example: `function MyClass:__tostring() return "MyClass" end`
---@return string str String representation (default: "Object")
function Object:__tostring()
  return "Object"
end


---Metamethod allowing class to be called like a constructor.
---Enables syntax: `local obj = MyClass(args)` instead of `MyClass:new(args)`
---Automatically creates instance and calls new() with provided arguments.
---@return core.object obj The new instance of the class
function Object:__call(...)
  local obj = setmetatable({}, self)
  obj:new(...)
  return obj
end


return Object
