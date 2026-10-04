"""Which library runs which operation workload, and why the others cannot.

A value of None means the library runs the workload; a string is the
one-line reason it has no equivalent API. `pulldown-cmark` runs from the
Rust comparison program.
"""
NEW = 'new after the before pin'
NO_PICTURES_R = 'no graphics-protocol API'
NO_PICTURES_N = 'pixel blitting needs a negotiated graphics terminal; the headless profile has none'

PLAN = {
    # task: (ratatui, notcurses, before)
    'cell_writes': (None, None, None),
    'print_rows': (None, None, None),
    'wide_print': (None, None, None),
    'wide_repaint': (None, None, None),
    'fill_clear': (None, None, None),
    'scroll_rows': ('Buffer has no scroll; ratatui re-renders the frame (see scroll_repaint)', None, None),
    'scroll_repaint': (None, None, None),
    'resize': (None, None, None),
    'copy_cells': (None, None, None),
    'copy_text': ('no text read-out of a buffer region', None, None),
    'links': ('no OSC 8 hyperlink API in 0.30', 'no OSC 8 hyperlink API', None),
    'grapheme_pool': ('cells own their strings; there is no shared pool to compact', 'the EGC pool is internal; no compaction API', None),
    'modes': (None, 'modes are set by notcurses_init/stop on a real terminal', None),
    'text_width': (None, None, None),
    'graphemes': (None, 'no public grapheme-cluster iterator', None),
    'width_models': ('one width model (unicode-width); no per-codepoint parts', 'one width model (wcwidth); no per-codepoint parts', None),
    'text_wrap': (None, 'ncplane_puttext wraps only while drawing (see paragraph)', None),
    'text_fit': ('no ellipsis truncation API', 'no ellipsis truncation API', None),
    'text_fit_end': ('no ellipsis truncation API', 'no ellipsis truncation API', NEW),
    'layout_split': (None, 'no layout solver', None),
    'layout_repeat': ('no repeated-tile layout', 'no layout solver', None),
    'block': (None, None, None),
    'paragraph': (None, None, None),
    'markdown_parse': ('no markdown parser (pulldown-cmark runs instead)', 'no markdown parser', NEW),
    'markdown_draw': ('no markdown widget', 'no markdown widget', NEW),
    'markdown_table_parse': ('no markdown parser (pulldown-cmark runs instead)', 'no markdown parser', NEW),
    'markdown_table_draw': ('no markdown widget', 'no markdown widget', NEW),
    'tree': ('no tree widget in ratatui (tui-tree-widget runs instead)', 'nctree draws each item through a caller callback into planes it makes; no draw-from-state tree', NEW),
    'print_above': (None, 'no inline mode: notcurses takes the whole terminal or writes through ncdirect', NEW),
    'text_edit': ('no text editing in ratatui (ratatui-textarea runs instead)', 'ncreader edits only through input events it reads', NEW),
    'list': (None, 'ncselector is an input-driven menu with its own frame; no draw-from-state list', None),
    'table': (None, 'no table widget', None),
    'tabs': (None, 'nctabbed is a tab container with its own content plane, not one header row', None),
    'gauge': (None, None, None),
    'line_gauge': (None, 'one progress bar (ncprogbar, see gauge)', None),
    'sparkline': (None, None, None),
    'barchart': (None, 'no bar chart widget (ncuplot plots one series, see sparkline)', None),
    'chart': (None, 'no axes chart widget', None),
    'scrollbar': (None, 'no scrollbar widget', None),
    'canvas': (None, 'no vector-shape canvas', None),
    'canvas_raster': ('no pixel rasterizer', 'ncvisual blits pixels but has no shape rasterizer', NEW),
    'calendar': (None, 'no calendar widget', None),
    'text_input': ('no text input widget', 'ncreader is driven by input events; no draw-from-text API', None),
    'keys': ('no key-hint widget', 'no key-hint widget', None),
    'rule': ('no rule widget', None, None),
    'edges': ('no two-edge row widget', 'no two-edge row widget', None),
    'sextants': ('no pixel blitter', 'the headless profile does not advertise sextants; NCBLIT_3x2 with NODEGRADE refuses', None),
    'input_events': ("crossterm's parser is private and event::read needs a terminal", 'input is read by its own thread from the terminal it opened', None),
    'term_feed': ('TestBackend is not a terminal emulator', 'no terminal emulator', None),
    'picture_frame_kitty': (NO_PICTURES_R, NO_PICTURES_N, None),
    'picture_frame_sixel': (NO_PICTURES_R, NO_PICTURES_N, NEW),
    'picture_frame_iterm': (NO_PICTURES_R, NO_PICTURES_N, NEW),
    'picture_frame_cells': ('no pixel blitter', 'headless profile does not advertise sextants', None),
    'picture_transmit': (NO_PICTURES_R, NO_PICTURES_N, None),
    'picture_replace': (NO_PICTURES_R, NO_PICTURES_N, NEW),
}
EXTRA = {'markdown_parse': ['pulldown-cmark'], 'markdown_table_parse': ['pulldown-cmark'],
         'tree': ['tui-tree-widget'], 'text_edit': ['ratatui-textarea']}

def sides(task):
    ratatui, notcurses, before = PLAN[task]
    out = ([] if before else ['visor-before']) + ['visor']
    out += ([] if ratatui else ['ratatui']) + EXTRA.get(task, []) + ([] if notcurses else ['notcurses'])
    return out

def unavailable(task):
    ratatui, notcurses, before = PLAN[task]
    rows = []
    if before: rows.append(('visor-before', before))
    if ratatui: rows.append(('ratatui', ratatui))
    if notcurses: rows.append(('notcurses', notcurses))
    if task.startswith('picture_frame_'):
        rows.append(('ratatui-image', 'not installed in the pinned Rust comparison manifest/lock'))
    return rows
