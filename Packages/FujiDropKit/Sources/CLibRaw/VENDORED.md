# Vendored LibRaw

- Version: 0.22.2
- Source: https://www.libraw.org/data/LibRaw-0.22.2.tar.gz
- SHA-256 of the tarball: `de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa`
- License: used under CDDL 1.0 (`LICENSE.CDDL`); see `COPYRIGHT`. LibRaw's source is
  available at https://www.libraw.org and https://github.com/LibRaw/LibRaw.

No LibRaw source file is modified. Kept from the tarball: `libraw/`, `internal/`, `src/`,
`LICENSE.CDDL`, `COPYRIGHT`. Removed: everything else (RawSpeed, GoPro, samples, bin, doc,
build files), `src/Makefile`, and the three placeholder stubs `postprocessing_ph.cpp`,
`preprocessing_ph.cpp` and `write_ph.cpp`, which would duplicate symbols. That leaves the 79
files of `LIB_OBJECTS` in LibRaw's `Makefile.dist`.

Added (ours, not LibRaw's): `libraw/module.modulemap` (exposes the C API to Swift) and this file.
