# Line Wrapping

## 2026-08-14: Vertical movement must stay row-local

`DocView.translate.previous_line` and `next_line` preserve the caret's
horizontal offset by resolving that offset within the target visual row. The
linewrapping override of `get_visual_line_col_from_x` must therefore stop at
the requested wrapped row's final character. Scanning into a later wrapped row
can return a position whose `visual_row_from_position` is the current or a
subsequent row, making repeated Up or Down movement appear stuck.

For a soft wrap, the exact boundary column belongs to the following visual
row because document positions do not carry visual-row affinity. The maximum
position for the preceding row is consequently the start of its final UTF-8
character, obtained with `translate.previous_char`, rather than the next
row's starting column.

## 2026-08-31: DiffView alignment uses shared visual slots

DiffView cannot align wrapped panes by adding its logical-line gap totals to
each pane's independent visual-row number. Each logical diff slot must instead
have a shared height equal to the larger wrapped-row count on its two sides;
the shorter side leaves blank padding below its text. The existing cumulative
gap totals still identify which logical lines occupy the same slot.

The aligned layout is cached from the child visual-line model identities, gap
table identities/generation, document sizes, and line heights. Diff updates
must build fresh gap tables and publish them only when complete; mutating an
initially exposed empty table would leave an identity-based cache looking valid
while a long asynchronous diff is still filling that table. Direct gap edits
performed by sync operations explicitly invalidate the layout generation.

Screen hit testing maps aligned padding and missing-side slots to the nearest
preceding document line and clamps to that line's last actual wrapped row. This
preserves the old DiffView gap behavior without inventing document positions
for blank padding. F10 intentionally synchronizes wrapping across both children;
when their enabled states differ, toggling enables both.
