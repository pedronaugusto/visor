"""Decode every new picture frame against a common opaque-red fixture.

The byte forms differ, so agreement is on RGBA pixels and cell placement,
not on escape spellings. PNG generation, uploads and decoding are untimed.
"""
import base64
import re
import struct
import zlib
from verify import Terminal


def red_png(data, width, height):
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    pos, compressed = 8, bytearray()
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        tag, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        assert zlib.crc32(tag + body) == struct.unpack('>I', data[pos + 8 + length:pos + 12 + length])[0]
        if tag == b'IHDR': assert struct.unpack('>IIBBBBB', body) == (width, height, 8, 6, 0, 0, 0)
        if tag == b'IDAT': compressed.extend(body)
        pos += length + 12
    assert zlib.decompress(compressed) == (b'\0' + bytes((255, 0, 0, 255)) * width) * height


def red_sixel(body, width, height):
    raster = re.match(rb'0;1;0q"1;1;(\d+);(\d+)', body)
    assert raster and (int(raster[1]), int(raster[2])) == (width, height)
    i, x, y, color = raster.end(), 0, 0, None
    palette, covered = {}, bytearray(width * height)
    while i < len(body):
        ch = body[i]
        if ch == ord('#'):
            m = re.match(rb'#(\d+)(?:;2;(\d+);(\d+);(\d+))?', body[i:])
            assert m
            color = int(m[1])
            if m[2] is not None: palette[color] = tuple(int(v) for v in m.groups()[1:])
            i += m.end()
        elif ch in (ord('$'), ord('-')):
            x = 0
            if ch == ord('-'): y += 6
            i += 1
        else:
            if ch == ord('!'):
                m = re.match(rb'!(\d+)([?-~])', body[i:])
                assert m
                count, ch = int(m[1]), m[2][0]
                i += m.end()
            else:
                count = 1
                i += 1
            assert ord('?') <= ch <= ord('~') and x + count <= width
            mask = ch - ord('?')
            for bit in range(6):
                if mask & (1 << bit):
                    assert y + bit < height and palette[color] == (100, 0, 0)
                    start = (y + bit) * width + x
                    covered[start:start + count] = b'\1' * count
            x += count
    assert covered == b'\1' * (width * height)


def verify(task, cols, rows, ev, corpus):
    width, height = (cols - 1) * 8, (rows - 1) * 16
    t = Terminal(cols, rows)
    protocol = task.removeprefix('picture_frame_')
    if protocol == 'kitty':
        raw = b''.join(bytes.fromhex(v) for v in ev['setup'])
        payload = bytearray()
        for m in re.finditer(rb'\x1b_G([^;]*);(.*?)\x1b\\', raw, re.S):
            keys = dict(p.split(b'=', 1) for p in m[1].split(b','))
            if b's' in keys: assert int(keys[b's']) == width and int(keys[b'v']) == height and keys.get(b'f', b'32') == b'32'
            payload.extend(base64.b64decode(m[2], validate=True))
        assert payload == bytes((255, 0, 0, 255)) * (width * height)
        t.images[7] = 'validated RGBA fixture'
    png = (corpus / 'picture.png').read_bytes()
    red_png(png, width, height)
    for frame, hexed in enumerate(ev['wire']):
        wire = bytes.fromhex(hexed)
        col = frame % 2
        if protocol in ('sixel', 'iterm'):
            pattern = rb'\x1bP(.*?)\x1b\\' if protocol == 'sixel' else rb'\x1b\]1337;File=(.*?)\x1b\\'
            matches = list(re.finditer(pattern, wire, re.S))
            assert len(matches) == 1
            m = matches[0]
            t.feed(wire[:m.start()])
            assert (t.x, t.y) == (col, 0)
            if protocol == 'sixel': red_sixel(m[1], width, height)
            else:
                raw_keys, payload = m[1].split(b':', 1)
                keys = dict(p.split(b'=', 1) for p in raw_keys.split(b';'))
                assert int(keys[b'width']) == cols - 1 and int(keys[b'height']) == rows - 1
                assert keys[b'doNotMoveCursor'] == b'1' and keys[b'inline'] == b'1'
                assert base64.b64decode(payload, validate=True) == png
            t.feed(wire[m.end():])
        else:
            t.feed(wire)
            if protocol == 'kitty': assert t.placements[(7, 1)] == (col, 0, cols - 1, rows - 1)
            else:
                for y in range(rows):
                    for x in range(cols):
                        cell = t.grid[y * cols + x]
                        lit = y < rows - 1 and col <= x < col + cols - 1
                        assert (cell[0] != ' ') == lit
                        if lit: assert cell[1] == (255, 0, 0)
    return {'frames': len(ev['wire']), 'rgba_width': width, 'rgba_height': height,
            'status': 'passed: common opaque-red image and moving cell rectangle'}
