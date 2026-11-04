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


def normalize(data):
    if not data or len(data) > MAX_BYTES:
        raise ValueError('image_limit')
    # Restrict plugin selection before parsing an untrusted header, rather than
    # only rejecting unsupported formats after their parser has already run.
    with Image.open(io.BytesIO(data), formats=('JPEG', 'PNG', 'WEBP')) as source:
        if source.format not in ('JPEG', 'PNG', 'WEBP') or getattr(source, 'n_frames', 1) != 1:
            raise ValueError('unsupported_image')
        if max(source.size) > 12000 or source.width * source.height > Image.MAX_IMAGE_PIXELS:
            raise ValueError('image_limit')
        source.verify()
    with Image.open(io.BytesIO(data), formats=('JPEG', 'PNG', 'WEBP')) as source:
        source.load()  # A header or MIME match is never enough.
        oriented = ImageOps.exif_transpose(source).convert('RGBA')
        # Fresh canvas drops EXIF, GPS, comments, ICC and all source metadata.
        pixels = Image.new('RGB', oriented.size, 'white')
        pixels.paste(oriented, mask=oriented.getchannel('A'))
        pixels.thumbnail((4096, 4096), Image.Resampling.LANCZOS)
        result = {}
        for variant, size in [('original', 4096), ('thumbnail', 320)]:
            output = pixels.copy()
            output.thumbnail((size, size), Image.Resampling.LANCZOS)
            stream = io.BytesIO()
            output.save(stream, 'JPEG', quality=85)
            result[variant] = {'data': base64.b64encode(stream.getvalue()).decode('ascii'),
                               'width': output.width, 'height': output.height}
        return result


if __name__ == '__main__':
    try:
        print(json.dumps(normalize(sys.stdin.buffer.read(MAX_BYTES + 1))))
    except Exception:
        # Never echo parser exceptions containing private metadata or file paths.
        sys.stderr.write('image_rejected\n')
        sys.exit(1)
