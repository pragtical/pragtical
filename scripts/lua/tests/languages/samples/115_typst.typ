#let widget(title, items) = [
  = #title
  #for item in items [
    - #item
  ]
]

#show heading: it => block(fill: luma(240), inset: 8pt, it)

#widget("Fixture", ("alpha", "beta"))
