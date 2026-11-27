# Aligns Apple and LibRaw crops, matches colour, applies one tone curve and writes <dir>/page/img/*.png.
# clean() is the false-colour cleanup the HDR pipeline should port to Swift.
# Usage: python3 compare.py <dir>, where <dir>/libraw holds libraw_crops.py output and <dir>/apple the CI artifact.
import sys, json, numpy as np, cv2, os
S = sys.argv[1]
cfg = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'crops.json')))
OUT = 512
os.makedirs(f'{S}/page/img', exist_ok=True)

def lum(a): return a[..., 0] * .2126 + a[..., 1] * .7152 + a[..., 2] * .0722

def srgb(x):
    x = np.clip(x, 0, 1)
    return np.where(x <= .0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - .055)

def shift_of(moving, ref):
    """(dx, dy) such that moving[y+dy, x+dx] ~ ref[y, x]."""
    h = min(moving.shape[0], ref.shape[0]); w = min(moving.shape[1], ref.shape[1])
    moving, ref = moving[:h, :w], ref[:h, :w]
    a = np.log1p(lum(ref) * 50).astype(np.float32); b = np.log1p(lum(moving) * 50).astype(np.float32)
    win = cv2.createHanningWindow(a.shape[::-1], cv2.CV_32F)
    (dx, dy), resp = cv2.phaseCorrelate(a, b, win)
    return round(dx), round(dy), resp

def read_apple(path):
    im = cv2.imread(path, cv2.IMREAD_UNCHANGED)[..., [2, 1, 0]]
    return im.astype(np.float64) / (65535 if im.dtype == np.uint16 else 255)

def clean(rgb):
    # False-colour suppression: median-filter colour ratios in log space, keep luminance.
    y = np.maximum(lum(rgb), 1e-5)[..., None]
    ratio = np.log(np.maximum(rgb, 1e-5) / y).astype(np.float32)
    for _ in range(2):
        ratio = cv2.medianBlur(ratio, 5)
    out = np.exp(ratio) * y
    return out * (y / np.maximum(lum(out), 1e-5)[..., None])

manifest = []
for s in cfg['samples']:
    for c in s['crops']:
        key = f"{s['name']}-{c['id']}"
        lib = {a: np.load(f'{S}/libraw/{key}-{a}.npy').astype(np.float64) / 65535 for a in ['LINEAR', 'PPG', 'AHD']}
        neutral = read_apple(f'{S}/apple/{key}-neutral.png')
        default = read_apple(f'{S}/apple/{key}-default.png')
        ref = lib['AHD']
        dx, dy, resp = shift_of(neutral[:ref.shape[0], :ref.shape[1]], ref)
        dx2, dy2, resp2 = shift_of(np.power(default[:ref.shape[0], :ref.shape[1]], 2.2), ref)
        # Common window in LibRaw coordinates where both Apple crops have pixels.
        m = 8
        x0 = max(m, -dx, -dx2) ; y0 = max(m, -dy, -dy2)
        x0 = min(x0, ref.shape[1] - OUT, neutral.shape[1] - OUT - dx, default.shape[1] - OUT - dx2)
        y0 = min(y0, ref.shape[0] - OUT, neutral.shape[0] - OUT - dy, default.shape[0] - OUT - dy2)
        win = lambda a, ox=0, oy=0: a[y0 + oy:y0 + oy + OUT, x0 + ox:x0 + ox + OUT]
        views = {k: win(v) for k, v in lib.items()}
        views['APPLE'] = win(neutral, dx, dy)
        # Per-channel gain so Apple's linear output matches LibRaw's colour balance, then one
        # exposure for all so the crop's median sits at mid-grey-ish.
        g = np.median(views['AHD'].reshape(-1, 3), 0) / np.maximum(np.median(views['APPLE'].reshape(-1, 3), 0), 1e-6)
        views['APPLE'] = views['APPLE'] * g
        views['CLEAN'] = clean(views['PPG'])
        ex = 0.22 / max(np.percentile(lum(views['AHD']), 50), 1e-4)
        ex = min(ex, 0.92 / max(np.percentile(lum(views['AHD']), 99.5), 1e-4)) if np.percentile(lum(views['AHD']), 99.5) * ex > 1.3 else ex
        files = {}
        for k, v in views.items():
            img = (srgb(v * ex) * 255 + .5).astype(np.uint8)
            files[k] = f'img/{key}-{k.lower()}.png'
            cv2.imwrite(f'{S}/page/{files[k]}', img[..., [2, 1, 0]], [cv2.IMWRITE_PNG_COMPRESSION, 9])
        d = win(default, dx2, dy2)
        files['DEFAULT'] = f'img/{key}-default.png'
        cv2.imwrite(f'{S}/page/{files["DEFAULT"]}', (d * 255 + .5).astype(np.uint8)[..., [2, 1, 0]], [cv2.IMWRITE_PNG_COMPRESSION, 9])
        print(key, 'shift', (dx, dy, round(resp, 2)), (dx2, dy2, round(resp2, 2)), 'gain', np.round(g, 2))
        manifest.append({'sample': s['name'], 'crop': c['id'], 'files': files, 'align': [round(resp, 2), round(resp2, 2)]})
json.dump(manifest, open(f'{S}/page/manifest.json', 'w'), indent=1)
