"""Correctness of the operation workloads, untimed.

Every side prints canonical evidence (`grid`: rows as text, covered columns
skipped; `value`/`text`/`rects`; `wire`: frame bytes). Before and after must
agree exactly. A comparison library must reproduce visor's evidence exactly
where the two implement the same rule; where the libraries legitimately lay
out differently (solver, glyph choice, alignment) a stated invariant holds
for every side instead. Frame bytes are replayed by verify.Terminal and must
rebuild the side's own grid.
"""
import re
from pathlib import Path
from verify import Terminal

R, N = 'ratatui', 'notcurses'
P, TT, TA = 'pulldown-cmark', 'tui-tree-widget', 'ratatui-textarea'
# Evidence a comparison library must reproduce byte for byte.
EXACT = {
    'markdown_table_parse': [P], 'tree': [TT], 'text_edit': [TA], 'print_above': [R],
    'cell_writes': [R, N], 'print_rows': [R, N], 'wide_print': [R, N], 'wide_repaint': [R, N],
    'fill_clear': [R, N], 'scroll_rows': [N], 'scroll_repaint': [R, N], 'resize': [N],
    'copy_cells': [R, N], 'copy_text': [N], 'block': [R, N], 'list': [R], 'tabs': [R],
    'rule': [N], 'text_width': [R, N], 'graphemes': [R],
}

# Tasks whose invariant also holds for visor itself.
INVARIANT_TOO = {'paragraph', 'table', 'gauge', 'line_gauge', 'sparkline', 'chart', 'canvas', 'calendar',
                 'layout_split', 'text_wrap', 'modes', 'barchart', 'scrollbar'}

def parse(lines):
    out = {}
    for line in lines:
        tag, _, value = line.partition('\t')
        out.setdefault(tag, []).append(value)
    return out

def text_of(hexed):
    return bytes.fromhex(hexed).decode()

def grid(ev):
    return text_of(ev['grid'][-1])

def replay(cols, rows, wires, each=None):
    t = Terminal(cols, rows)
    for k, w in enumerate(wires):
        t.feed(bytes.fromhex(w))
        if each: each(k, t)
    return t

def words_prefix(text, prose):
    got = text.split()
    want = prose.split()
    assert got and got == want[:len(got)], (got[:8], want[:8])
    return len(got)

def invariant(task, side, ev, cols, rows, corpus):
    """Checks a library that lays the same content out by its own rules."""
    if task == 'paragraph':
        g = grid(ev)
        assert all(len(l) <= cols for l in g.split('\n'))
        return {'words_shown': words_prefix(g, (corpus / 'prose.txt').read_text())}
    if task == 'table':
        g = grid(ev).split('\n')
        n = rows * 8
        assert 'id' in g[0] and 'value' in g[0] and 'state' in g[0], g[0]
        ids = [int(m) for l in g[1:] for m in re.findall(r'\br(\d+)\b', l)]
        assert ids == list(range(ids[0], ids[0] + len(ids))) and ids[0] <= n // 2 <= ids[-1], ids
        return {'rows_shown': len(ids)}
    if task == 'line_gauge':
        g = grid(ev).split('\n')
        assert all(l.startswith('disk') for l in g), g[:2]
        return {'rows': len(g)}
    if task == 'gauge':
        first = grid(ev).split('\n')[0]
        filled = max((i for i, ch in enumerate(first) if 0x2580 <= ord(ch) <= 0x259f), default=-1) + 1
        assert abs(filled - 0.6180339887 * cols) <= 1.5, (filled, cols)
        return {'filled_columns': filled}
    if task == 'sparkline':
        cells = [ch for ch in grid(ev) if ch not in ' \n']
        assert cells and all(0x2581 <= ord(ch) <= 0x2588 for ch in cells)
        return {'bar_cells': len(cells)}
    if task in ('chart', 'canvas'):
        g = grid(ev)
        dots = sum(1 for ch in g if 0x2800 <= ord(ch) <= 0x28ff)
        assert dots > cols // 4, dots
        if task == 'chart': assert '100' in g and '-1' in g
        return {'braille_cells': dots}
    if task == 'calendar':
        g = grid(ev)
        months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
        shown = re.findall('(' + '|'.join(months) + r') 20\d\d', g)
        assert len(shown) == (rows + 1) // 9 * ((cols + 2) // 22), (shown, cols, rows)
        assert ('28' in g) == bool(shown)
        return {'months': len(shown)}
    if task == 'layout_split':
        rects = [tuple(map(int, r.lstrip('R').split(','))) for r in ev['rects'][0].split(';') if r]
        outer = [r for r, raw in zip(rects, [x for x in ev['rects'][0].split(';') if x]) if raw.startswith('R')]
        assert len(outer) == 6
        assert outer[0][3] == 3, outer
        for a, b in zip(outer, outer[1:]): assert b[1] == a[1] + a[3] + 1, outer
        assert outer[-1][1] + outer[-1][3] == rows, outer
        inner = [r for r, raw in zip(rects, [x for x in ev['rects'][0].split(';') if x]) if not raw.startswith('R')]
        for row in range(6):
            cells = inner[row * 5:(row + 1) * 5]
            assert cells[0][2] == 12 and cells[0][0] == 0, cells
            assert cells[-1][0] + cells[-1][2] == cols, cells
        return {'outer_heights': [r[3] for r in outer]}
    if task == 'barchart':
        last = grid(ev).split('\n')[-1].split()
        assert last == [f'b{i % 100}' for i in range(len(last))] and len(last) == cols // 4, last
        return {'bars': len(last)}
    if task == 'scrollbar':
        g = grid(ev).split('\n')
        right = ''.join(l[cols - 1] if len(l) >= cols else ' ' for l in g[:-1])
        bottom = g[-1]
        for track in (right, bottom):
            runs = re.findall('█+', track)
            assert len(runs) == 1, track
        return {'thumbs': [len(re.findall('█+', right)[0]), len(re.findall('█+', bottom)[0])]}
    if task == 'resize':
        assert text_of(ev['value'][0]) == f'area={cols}x{rows}'
        return {'area': f'{cols}x{rows}'}
    if task == 'modes':
        wire = bytes.fromhex(ev['wire'][-1])
        for mode in (b'1049', b'1004', b'2004', b'1006'):
            assert b'\x1b[?' + mode + b'h' in wire and b'\x1b[?' + mode + b'l' in wire, mode
        return {'bytes': len(wire)}
    if task == 'text_wrap':
        n = int(ev['value'][0].split('=')[1])
        prose = (corpus / 'prose.txt').read_text()
        assert n >= len(prose) // cols, n
        return {'rows': n}
    if task == 'markdown_parse':
        return {'blocks': int(ev['info'][0].split('=')[1])}
    raise AssertionError(('no invariant for', task, side))

WORDS = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta']

def print_above_screen(cols, rows, frames):
    """What the terminal shows after `frames` frames of two log lines printed
    above an inline view a quarter of it tall, worked out from the rule."""
    view_rows = max(2, rows // 4)
    printed = [f'log {i:06} {WORDS[i % 8]} {WORDS[(i + 3) % 8]}'[:cols] for i in range(2 * frames)]
    n = frames
    view = [f'working {n:06}'[:cols]] + ['#' * ((n + y) % (cols + 1)) for y in range(1, view_rows)]
    room = rows - view_rows
    above = printed[-room:] if len(printed) > room else printed
    screen = above + view
    return '\n'.join(r.rstrip(' ') for r in screen + [''] * (rows - len(screen)))

def own_wire(task, side, ev, cols, rows, corpus):
    """Frame bytes replayed by the independent decoder rebuild the side's grid."""
    if task == 'print_above':
        # The first frame enters and draws the view; each after prints two
        # rows above it. The decoder's screen after each is worked out from
        # the rule, and is then the side's grid for the exact comparison.
        def each(k, t):
            assert t.text() == print_above_screen(cols, rows, k), (side, k, t.text())
        t = replay(cols, rows, ev['wire'], each)
        ev['grid'] = [t.text().encode().hex()]
        return {'frames': len(ev['wire']), 'replayed_bytes': sum(len(w) // 2 for w in ev['wire'])}
    if task == 'scroll_repaint':
        log = (corpus / 'log.txt').read_text().rstrip('\n').split('\n')
        def each(k, t):
            want = '\n'.join(log[(k + y) % len(log)] for y in range(rows))
            assert t.text() == want, (side, k)
        t = replay(cols, rows, ev['wire'], each)
    else:
        t = replay(cols, rows, ev['wire'])
    assert t.text() == grid(ev), (task, side)
    if task == 'links':
        assert len(t.links) == rows, len(t.links)
    return {'frames': len(ev['wire']), 'replayed_bytes': sum(len(w) // 2 for w in ev['wire'])}

def verify(task, cols, rows, corpus, outputs):
    """outputs: library -> (result, lines). Returns evidence per library."""
    corpus = Path(corpus) / f'{cols}x{rows}'
    parsed = {side: parse(lines) for side, (result, lines) in outputs.items()}
    evidence = {}
    ours = parsed['visor']
    if 'visor-before' in parsed:
        before = parsed['visor-before']
        for tag in set(before) | set(ours):
            if tag == 'wire': continue
            assert before.get(tag) == ours.get(tag), (task, cols, rows, 'before/after differ', tag)
    for side, ev in parsed.items():
        e = {}
        if task.startswith('picture_frame_'):
            from verify_pictures import verify as verify_picture
            evidence[side] = verify_picture(task, cols, rows, ev, corpus)
            continue
        if task in ('wide_repaint', 'scroll_repaint', 'links', 'print_above') and 'wire' in ev:
            e.update(own_wire(task, side, ev, cols, rows, corpus))
        if side in ('visor', 'visor-before'):
            e['status'] = 'passed'
        elif side in EXACT.get(task, []):
            for tag in ('grid', 'value', 'text'):
                if tag in ours and tag in ev:
                    mine, theirs = text_of(ours[tag][-1]) if tag != 'value' else ours[tag][-1], text_of(ev[tag][-1]) if tag != 'value' else ev[tag][-1]
                    # ncplane_contents reads a region as one string, rows unseparated.
                    if task == 'copy_text': mine = mine.replace('\n', '')
                    assert theirs == mine, (task, cols, rows, side, 'differs from visor', tag)
            e['status'] = 'passed: identical to visor'
        elif (cols, rows) == (8, 4):
            e['status'] = 'passed: ran (invariants need a full-size grid)'
        else:
            e.update(invariant(task, side, ev, cols, rows, corpus))
            e['status'] = 'passed: invariant'
        if side in ('visor', 'visor-before') and task in INVARIANT_TOO and (cols, rows) != (8, 4):
            e.update(invariant(task, side, ev, cols, rows, corpus))
        evidence[side] = e
    return evidence
