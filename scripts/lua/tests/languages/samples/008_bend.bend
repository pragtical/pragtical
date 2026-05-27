def map(xs, f):
  match xs:
    case []:
      []
    case [x, ...rest]:
      [f(x), ...map(rest, f)]

def main:
  values = [1, 2, 3]
  map(values, lambda x: x + 1)
