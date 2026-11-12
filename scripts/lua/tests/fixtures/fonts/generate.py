"""Generate small, self-contained font fixtures. Requires fontTools."""
from pathlib import Path
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.colorLib.builder import buildCOLR, buildCPAL
from fontTools.ttLib.tables.otTables import PaintFormat, CompositeMode

HERE = Path(__file__).resolve().parent


def outline(box=None):
    pen = TTGlyphPen(None)
    if box:
        x1, y1, x2, y2 = box
        pen.moveTo((x1, y1))
        pen.lineTo((x2, y1))
        pen.lineTo((x2, y2))
        pen.lineTo((x1, y2))
        pen.closePath()
    return pen.glyph()


def make_font(family, cmap, boxes, advances):
    order = ['.notdef', 'space'] + list(boxes)
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({32: 'space', **cmap})
    fb.setupGlyf({'.notdef': outline((50, 0, 450, 700)), 'space': outline(),
                 **{g: outline(box) for g, box in boxes.items()}})
    fb.setupHorizontalMetrics({g: (advances.get(g, 600), boxes[g][0] if boxes.get(g) else 0) for g in order})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({'familyName': family, 'styleName': 'Regular',
                       'uniqueFontIdentifier': family, 'fullName': family,
                       'psName': family.replace(' ', '')})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    fb.setupMaxp()
    fb.font['head'].created = fb.font['head'].modified = 3660681600
    fb.font.recalcTimestamp = False
    return fb.font


primary = make_font('Pragtical Test Primary', {65: 'A'},
                    {'A': (0, 0, 500, 700)}, {})
primary.save(HERE / 'primary.ttf')
blank = make_font('Pragtical Test Blank', {66: 'B'}, {'B': None}, {'B': 0})
blank.save(HERE / 'blank.ttf')
visible = make_font('Pragtical Test Visible',
                    {65: 'A', 66: 'B', 0x301: 'acute', 0x1F680: 'rocket', 0x1F3FB: 'modifier'},
                    {'A': (0, 0, 500, 700), 'B': (0, 0, 600, 700), 'acute': (100, 600, 300, 750),
                     'rocket': (100, 100, 500, 650), 'modifier': (100, 200, 400, 600)},
                    {'B': 700, 'acute': 0})
visible.save(HERE / 'visible.ttf')

names = ['solid', 'linear', 'radial', 'sweep', 'unrenderable', 'translated']
color = make_font('Pragtical Test Color',
                  {0xE000 + i: name for i, name in enumerate(names)},
                  {'mask': (200, 200, 800, 800), **{name: None for name in names}},
                  {name: 1000 for name in names})


def solid(index=0):
    return {'Format': PaintFormat.PaintSolid, 'PaletteIndex': index, 'Alpha': 1.0}


def colorline():
    return {'ColorStop': [{'StopOffset': 0.0, 'PaletteIndex': 0, 'Alpha': 1.0},
                           {'StopOffset': 1.0, 'PaletteIndex': 1, 'Alpha': 1.0}], 'Extend': 'pad'}


def linear():
    return {'Format': PaintFormat.PaintLinearGradient, 'ColorLine': colorline(),
            'x0': 0, 'y0': 0, 'x1': 1000, 'y1': 0, 'x2': 0, 'y2': 1000}


fills = [solid(), linear(),
         {'Format': PaintFormat.PaintRadialGradient, 'ColorLine': colorline(),
          'x0': 500, 'y0': 500, 'r0': 0, 'x1': 500, 'y1': 500, 'r1': 500},
         {'Format': PaintFormat.PaintSweepGradient, 'ColorLine': colorline(),
          'centerX': 500, 'centerY': 500, 'startAngle': 0, 'endAngle': 360},
         solid(),
         {'Format': PaintFormat.PaintTranslate, 'Paint': linear(), 'dx': 100, 'dy': 0}]
paints = {name: {'Format': PaintFormat.PaintComposite, 'SourcePaint': fill,
                 'BackdropPaint': {'Format': PaintFormat.PaintGlyph, 'Glyph': 'mask', 'Paint': solid()},
                 'CompositeMode': CompositeMode.SRC_IN}
          for name, fill in zip(names, fills)}
color['COLR'] = buildCOLR(paints, version=1, glyphMap=color.getReverseGlyphMap(),
                          clipBoxes={name: (0, 0, 1000, 1000) for name in names if name != 'unrenderable'})
color['CPAL'] = buildCPAL([[(1, 0, 0, 1), (0, 0, 1, 1)]])
color.save(HERE / 'color.ttf')
