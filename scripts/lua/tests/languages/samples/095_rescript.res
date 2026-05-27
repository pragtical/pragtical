type item = {
  label: string,
  enabled: bool,
}

type status =
  | Ready
  | Disabled(string)

exception EmptyItems

module Widget = {
  let make = (~name="demo", ()) => name
  let render = (name, items) => {
    switch items {
    | [] => raise(EmptyItems)
    | _ =>
      items
      ->Array.keep(item => item.enabled)
      ->Array.map(item => `${name}:${item.label}`)
    }
  }
}

module type Renderer = {
  let render: (string, array<item>) => array<string>
}

let status = Ready
let message = switch status {
| Ready => Widget.render("main", [{label: "alpha", enabled: true}])
| Disabled(reason) => [reason]
}
