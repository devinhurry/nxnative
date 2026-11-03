"""Category icons preserve their mask opacity; the frontend owns user opacity."""
from pathlib import Path
import struct
import sys
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import botw_touch_assets


class TouchIconOpacity(unittest.TestCase):
    def test_png_preserves_full_and_partial_mask_opacity(self):
        data = botw_touch_assets.png(3, 1, [0, 128, 255])
        offset, compressed = 8, bytearray()
        while offset < len(data):
            size, = struct.unpack_from('>I', data, offset)
            if data[offset + 4:offset + 8] == b'IDAT':
                compressed.extend(data[offset + 8:offset + 8 + size])
            offset += size + 12
        rgba = zlib.decompress(compressed)
        self.assertEqual(rgba[0], 0)
        self.assertEqual(list(rgba[4::4]), [0, 128, 255])


if __name__ == '__main__':
    unittest.main()
