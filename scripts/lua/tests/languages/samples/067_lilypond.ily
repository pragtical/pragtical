\version "2.24.0"

melody = \relative c' {
  \key c \major
  \time 4/4
  c4 d e f
  g2 g
}

\score {
  \new Staff \melody
  \layout { }
}
