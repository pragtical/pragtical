BEGIN {
  FS = ","
  total = 0
}

function add(label, value,    parsed) {
  parsed = value + 0
  totals[label] += parsed
  return parsed
}

/^[^#]/ {
  total += add($1, $2)
}

END {
  for (name in totals) print name, totals[name]
  print "total", total
}
