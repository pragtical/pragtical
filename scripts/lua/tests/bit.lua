local test = require "core.test"

test.describe("bit", function()
  test.test("exports the documented functions", function()
    for _, name in ipairs({
      "tobit", "tohex", "bnot", "bor", "band", "bxor",
      "lshift", "rshift", "arshift", "rol", "ror", "bswap"
    }) do
      test.type(bit[name], "function", "missing bit." .. name)
    end
  end)

  test.test("performs boolean bitwise operations", function()
    test.equal(bit.band(0xf0, 0x0f), 0x00)
    test.equal(bit.bor(0xf0, 0x0f), 0xff)
    test.equal(bit.bxor(0xaa, 0xff), 0x55)
    test.equal(bit.tohex(bit.bnot(0)), "ffffffff")
  end)

  test.test("normalizes, shifts and rotates integers", function()
    test.equal(bit.tobit(0xffffffff), -1)
    test.equal(bit.tohex(255, -4), "00FF")
    test.equal(bit.lshift(3, 4), 48)
    test.equal(bit.rshift(48, 4), 3)
    test.equal(bit.arshift(-16, 2), -4)
    test.equal(bit.tohex(bit.rol(0x12345678, 8)), "34567812")
    test.equal(bit.tohex(bit.ror(0x12345678, 8)), "78123456")
    test.equal(bit.tohex(bit.bswap(0x11223344)), "44332211")
  end)
end)
