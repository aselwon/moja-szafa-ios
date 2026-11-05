"""Bounded decoder process. Only pixel data crosses into new JPEG outputs."""
import io
import json
import sys
import warnings
import base64
from PIL import Image, ImageOps

MAX_BYTES = 12 * 1024 * 1024
Image.MAX_IMAGE_PIXELS = 24_000_000
warnings.simplefilter('error', Image.DecompressionBombWarning)


def normalize(data, cleaned=False):
    if not data or len(data) > MAX_BYTES:
        raise ValueError('image_limit')
    # Restrict plugin selection before parsing an untrusted header, rather than
    # only rejecting unsupported formats after their parser has already run.
    with Image.open(io.BytesIO(data), formats=('JPEG', 'PNG', 'WEBP')) as source:
        if (cleaned and source.format != 'PNG') or source.format not in ('JPEG', 'PNG', 'WEBP') or getattr(source, 'n_frames', 1) != 1:
            raise ValueError('unsupported_image')
        if max(source.size) > 12000 or source.width * source.height > Image.MAX_IMAGE_PIXELS:
            raise ValueError('image_limit')
        source.verify()
    with Image.open(io.BytesIO(data), formats=('JPEG', 'PNG', 'WEBP')) as source:
        source.load()  # A header or MIME match is never enough.
        oriented = ImageOps.exif_transpose(source).convert('RGBA')
        # Fresh canvas drops EXIF, GPS, comments, ICC and all source metadata.
        pixels = Image.new('RGBA' if cleaned else 'RGB', oriented.size, (0, 0, 0, 0) if cleaned else 'white')
        if cleaned:
            pixels.paste(oriented)
        else:
            pixels.paste(oriented, mask=oriented.getchannel('A'))
        pixels.thumbnail((4096, 4096), Image.Resampling.LANCZOS)
        result = {}
        for variant, size in ([('cleaned', 4096)] if cleaned else [('original', 4096), ('thumbnail', 320)]):
            output = pixels.copy()
            output.thumbnail((size, size), Image.Resampling.LANCZOS)
            stream = io.BytesIO()
            output.save(stream, 'PNG' if cleaned else 'JPEG', **({} if cleaned else {'quality': 85}))
            if len(stream.getvalue()) > MAX_BYTES:
                raise ValueError('image_limit')
            result[variant] = {'data': base64.b64encode(stream.getvalue()).decode('ascii'),
                               'width': output.width, 'height': output.height}
        return result


if __name__ == '__main__':
    try:
        print(json.dumps(normalize(sys.stdin.buffer.read(MAX_BYTES + 1), cleaned='--cleaned' in sys.argv)))
    except Exception:
        # Never echo parser exceptions containing private metadata or file paths.
        sys.stderr.write('image_rejected\n')
        sys.exit(1)
