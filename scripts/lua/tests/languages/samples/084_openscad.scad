module widget(size = [10, 20, 4], radius = 2) {
  difference() {
    cube(size, center = true);
    translate([0, 0, 1]) cylinder(h = 8, r = radius, center = true);
  }
}

for (i = [0 : 2]) {
  translate([i * 14, 0, 0]) widget();
}
