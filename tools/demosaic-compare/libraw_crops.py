# Decodes the crops in crops.json with LibRaw (via rawpy) for the demosaic study.
# Usage: python3 libraw_crops.py <dir with <sample>.RAF files> <out dir>
# rawpy's demosaic names map onto X-Trans like this (LibRaw dcraw_process.cpp):
#   LINEAR -> lin_interpolate, PPG (user_qual 2) -> Markesteijn 1-pass, AHD (3) -> Markesteijn 3-pass.
import json, os, sys, time
import numpy as np, rawpy

raws, out = sys.argv[1], sys.argv[2]
cfg = json.load(open(os.path.join(os.path.dirname(__file__), 'crops.json')))
S = cfg['size']
os.makedirs(out, exist_ok=True)
for s in cfg['samples']:
    for alg in ['LINEAR', 'PPG', 'AHD']:
        r = rawpy.imread(os.path.join(raws, s['name'] + '.RAF'))
        t = time.time()
        im = r.postprocess(demosaic_algorithm=getattr(rawpy.DemosaicAlgorithm, alg), use_camera_wb=True,
                           no_auto_bright=True, output_bps=16, gamma=(1, 1), output_color=rawpy.ColorSpace.sRGB)
        print(s['name'], alg, f'{time.time() - t:.2f}s')
        H, W = im.shape[:2]
        for c in s['crops']:
            x0 = max(0, min(W - S, int(W * c['x']) - S // 2)); y0 = max(0, min(H - S, int(H * c['y']) - S // 2))
            np.save(os.path.join(out, f"{s['name']}-{c['id']}-{alg}.npy"), im[y0:y0 + S, x0:x0 + S])
