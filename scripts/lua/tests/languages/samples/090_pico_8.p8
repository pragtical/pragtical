pico-8 cartridge // http://www.pico-8.com
version 42
__lua__
player = { x = 64, y = 64, speed = 2 }

function _init()
  score = 0
end

function _update()
  if btn(0) then player.x -= player.speed end
  if btn(1) then player.x += player.speed end
  if btnp(4) then score += 1 end
end

function _draw()
  cls(0)
  spr(1, player.x, player.y)
  print("score:"..score, 2, 2, 7)
end
__gfx__
0000000001111110
