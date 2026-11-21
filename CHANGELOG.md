# Changelog

## 0.1.0 - 2026-11-22

- Initial release. `lib/phonemizer_ffi.rb` (extracted from the `scansion` gem) packaged as a standalone gem: a drop-in, API-compatible replacement for the `phonemizer` gem that calls libespeak-ng in-process via FFI instead of fork+exec-ing the espeak-ng CLI per word (~40x faster on a 500-word batch, byte-identical output in default mode)
- `phonemize_ffi` executable (`bin/phonemize_ffi`), registered via `spec.executables` and routed through the new `Phonemizer.main(argv)` entry point; adds a stdin batch mode (one utterance per line) since the FFI backend has no worker pool; the lib file also still runs standalone (`ruby lib/phonemizer_ffi.rb ...`)
- Runtime dependency on the `ffi` gem; requires the espeak-ng shared library and data (`apt install libespeak-ng-dev`, or `PHONEMIZER_ESPEAK_LIB` for non-standard lib paths such as keg-only Homebrew installs)
- RSpec suite under `spec/`: deterministic unit specs (no espeak needed) + integration specs skipped when libespeak-ng is unavailable
- Documentation and comments in English
