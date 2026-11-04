import base64
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
from PIL import Image

spec = importlib.util.spec_from_file_location('normalize', Path(__file__).parents[1] / 'images/normalize.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DecoderTests(unittest.TestCase):
    def test_unsupported_format_is_rejected_before_its_parser_runs(self):
        source = io.BytesIO()
        Image.new('RGB', (10, 10), 'red').save(source, 'BMP')
        Image.init()
        parser, accept = Image.OPEN['BMP']
        observed = Mock(wraps=parser)
        with patch.dict(Image.OPEN, {'BMP': (observed, accept)}):
            with self.assertRaises(Exception):
                module.normalize(source.getvalue())
        observed.assert_not_called()

    def test_metadata_orientation_and_thumbnail(self):
        image = Image.new('RGB', (640, 480), 'red')
        exif = Image.Exif()
        exif[274] = 6
        exif[270] = 'private fixture description'
        source = io.BytesIO()
        image.save(source, 'JPEG', exif=exif, icc_profile=b'private profile')
        results = module.normalize(source.getvalue())
        self.assertEqual((results['original']['width'], results['original']['height']), (480, 640))
        self.assertEqual((results['thumbnail']['width'], results['thumbnail']['height']), (240, 320))
        for result in results.values():
            data = base64.b64decode(result['data'])
            self.assertNotIn(b'private', data)
            with Image.open(io.BytesIO(data)) as decoded:
                decoded.load()
                self.assertFalse(decoded.getexif())
                self.assertNotIn('icc_profile', decoded.info)

    def test_reject_invalid_truncated_oversized_and_animated(self):
        image = Image.new('RGB', (50, 50))
        source = io.BytesIO()
        image.save(source, 'JPEG')
        for data in [b'', b'fake JPEG', source.getvalue()[:100], b'x' * (module.MAX_BYTES + 1)]:
            with self.assertRaises(Exception):
                module.normalize(data)
        animated = io.BytesIO()
        image.save(animated, 'PNG', save_all=True, append_images=[Image.new('RGB', (50, 50), 'red')])
        with self.assertRaises(ValueError):
            module.normalize(animated.getvalue())
        # Lower the threshold for the same real decompression-bomb code path.
        previous = Image.MAX_IMAGE_PIXELS
        try:
            Image.MAX_IMAGE_PIXELS = 100
            with self.assertRaises((Image.DecompressionBombError, Image.DecompressionBombWarning)):
                module.normalize(source.getvalue())
        finally:
            Image.MAX_IMAGE_PIXELS = previous


if __name__ == '__main__':
    unittest.main()
