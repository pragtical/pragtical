---@meta

---
---Mike Pall bit operations library included on every Lua runtime for
---consistency with the patch https://github.com/LuaJIT/LuaJIT/issues/384
---applied for newer Lua versions support.
---
---See: https://bitop.luajit.org/
---@class bit
bit = {}

---
---Normalizes a number to the numeric range for bit operations and returns it.
---This function is usually not needed since all bit operations already
---normalize all of their input arguments.
---@param x integer
---@return integer y
---@nodiscard
function bit.tobit(x) end

---
---Converts its first argument to a hex string. The number of hex digits is
---given by the absolute value of the optional second argument. Positive
---numbers between 1 and 8 generate lowercase hex digits. Negative numbers
---generate uppercase hex digits. Only the least-significant 4*|n| bits are
---used. The default is to generate 8 lowercase hex digits.
---@param x  integer
---@param n? integer
---@return integer y
---@nodiscard
function bit.tohex(x, n) end

---
---Returns the bitwise `not` of its argument.
---@param x integer
---@return integer y
---@nodiscard
function bit.bnot(x) end

---Returns the bitwise `or` of all of its arguments.
---@param x   integer
---@param x2  integer
---@param ... integer
---@return integer y
---@nodiscard
function bit.bor(x, x2, ...) end

---Returns the bitwise `and` of all of its arguments.
---@param x   integer
---@param x2  integer
---@param ... integer
---@return integer y
---@nodiscard
function bit.band(x, x2, ...) end

---Returns the bitwise `xor` of all of its arguments.
---@param x   integer
---@param x2  integer
---@param ... integer
---@return integer y
---@nodiscard
function bit.bxor(x, x2, ...) end

---
---Returns either the bitwise logical left-shift of its first argument by the
---number of bits given by the second argument.
---@param x integer
---@param n integer
---@return integer y
---@nodiscard
function bit.lshift(x, n) end

---
---Returns either the bitwise logical right-shift of its first argument by the
---number of bits given by the second argument.
---@param x integer
---@param n integer
---@return integer y
---@nodiscard
function bit.rshift(x, n) end

---
---Returns either the bitwise logical arithmetic right-shift of its first
---argument by the number of bits given by the second argument.
---@param x integer
---@param n integer
---@return integer y
---@nodiscard
function bit.arshift(x, n) end

---
---Returns the bitwise left rotation of its first argument by the number of
---bits given by the second argument. Bits shifted out on one side are
---shifted back in on the other side.
---@param x integer
---@param n integer
---@return integer y
---@nodiscard
function bit.rol(x, n) end

---
---Returns the bitwise right rotation of its first argument by the number of
---bits given by the second argument. Bits shifted out on one side are
---shifted back in on the other side.
---@param x integer
---@param n integer
---@return integer y
---@nodiscard
function bit.ror(x, n) end

---
---Swaps the bytes of its argument and returns it. This can be used to
---convert little-endian 32 bit numbers to big-endian 32 bit numbers or
---vice versa.
---@param x integer
---@return integer y
---@nodiscard
function bit.bswap(x) end


return bit
