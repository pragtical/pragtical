These tiny fonts are authored for Pragtical's renderer tests and use the
repository's MIT license. They contain only simple geometric outlines.

- `primary.ttf`: one covered letter and a visible missing-glyph box.
- `blank.ttf`: a mapped letter with no outline or advance.
- `visible.ttf`: visible fallback letters, a zero-advance combining mark, and
  two emoji components without a composed-sequence substitution.
- `color.ttf`: COLRv1 solid, linear, radial, sweep, and transformed fills inside
  composites. One glyph intentionally lacks a clip box to exercise failed
  bitmap rendering while retaining its advance.

Regenerate with `python generate.py` after installing FontTools. Tests use the
checked-in fonts directly and require no Python packages at runtime.
