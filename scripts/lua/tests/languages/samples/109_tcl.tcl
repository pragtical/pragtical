namespace eval demo {
  oo::class create Widget {
    variable name
    constructor {{value demo}} {
      set name $value
    }
    method render {items} {
      set out {}
      foreach item $items {
        lappend out "$name:$item"
      }
      return [join $out ", "]
    }
  }
}
