-- Use built-in bit operators for lua 5.3 and up

if bit then return end

bit = {}

bit.tobit = function(x)
  return math.tointeger(x)
end

bit.bnot = function(x)
  return ~x
end

bit.band = function(x, n)
  return x & n
end

bit.bor = function(x, n)
  return x | n
end

bit.bxor = function(x, n)
  return x ~ n
end

bit.lshift = function(x, n)
  return x << n
end

bit.rshift = function(x, n)
  return x >> n
end

bit.rol = function(x, n)
  return ((x << n) | (x >> (32-n)))
end

bit.ror = function(x, n)
  return ((x << (32-n)) | (x >> n))
end

bit.bswap = function(x)
  return (x >> 24) | ((x >> 8) & 0xff00) | ((x & 0xff00) << 8) | (x << 24);
end

bit.tohex = function(x)
  return string.format("%x", x);
end
