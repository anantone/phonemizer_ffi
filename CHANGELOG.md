# Changelog

## 0.1.3 - 2026-11-25

- Internal refactor of the cache, no behavior change (output verified byte-identical to 0.1.2 across 9 option combinations x 7 texts): `CACHE` renamed to `IPA_CACHE` and now stores only raw per-piece IPA keyed by `[piece, language, phone_sep]`; the expensive post-processing (separator substitution, stress stripping, language-switch marking) is applied once per batch instead of being cached
- `validate_phone_sep!` rejects `phone_sep` values containing the `\x01` sentinel used internally for clause splitting
- `MAX_CLAUSES = 1000` cap on the number of clauses per text to bound the FFI call fan-out
- `stitch` signature change: `stitch(parts, ipa_map, phone_sep:, ...)` → `stitch(parts, language:, phone_sep:, ...)`, reading from `IPA_CACHE`; unit specs updated accordingly (helper that seeds `IPA_CACHE` with a test language)
- Thread safety: new `ESPEAK_LOCK` mutex serializes every call into libespeak-ng (global voice state) via `with_voice`, making `Phonemizer` safe to call from multiple threads (transcriptions are serialized); verified: 4 threads x 4 languages produce results identical to single-threaded
- Bounded cache: `MAX_CACHE_SIZE = 50_000`; once reached, `IPA_CACHE` is wiped wholesale (`evict_cache_if_full`) so long-running processes don't grow memory without bound
- New `Phonemizer::Error < StandardError` raised instead of bare `RuntimeError` on espeak failures (init failure, voice not found, clause cap exceeded) — note: `rescue RuntimeError` no longer catches these, bare `rescue` still does
- CLI: running with no arguments on a TTY now prints the usage to stderr and exits 1 (previously it phonemized the empty string); stdin-pipe and file modes unchanged
- No behavior change in transcription output: verified byte-identical to the previous version across 9 option combinations x 9 texts

## 0.1.2 - 2026-11-24

- rubocop : `.rubocop.yml` ajouté (TargetRubyVersion 3.1, NewCops désactivés, quotes simples, plafonds Metrics relevés à l'état actuel, BlockLength hors spec/) ; autocorrections appliquées ; 0 offense, specs inchangés

## 0.1.1 - 2026-11-24

- RDoc: document the remaining public methods (`phonememode`, `clear_cache`, `phonemize_batch` with `@param`/`@return`); add an `rdoc` task to the Rakefile (`rake rdoc` generates the HTML docs, README as home page) and `rdoc` as a development dependency
- YARD support for rubydoc.info: `.yardopts` file (markdown markup, README as front page), `rake yard` task in the Rakefile (aliased as `rake doc`, generates `doc/`); `yard` and `kramdown` added as development dependencies; gemspec metadata (`source_code_uri`, `changelog_uri`, `bug_tracker_uri`, `documentation_uri`) pointing at the GitHub repo and `https://rubydoc.info/gems/phonemizer_ffi`; documentation link added to the README. Documentation-only change

## 0.1.0 - 2026-11-22

- Initial release. `lib/phonemizer_ffi.rb` (extracted from the `scansion` gem) packaged as a standalone gem: a drop-in, API-compatible replacement for the `phonemizer` gem that calls libespeak-ng in-process via FFI instead of fork+exec-ing the espeak-ng CLI per word (~40x faster on a 500-word batch, byte-identical output in default mode)
- `phonemize_ffi` executable (`bin/phonemize_ffi`), registered via `spec.executables` and routed through the new `Phonemizer.main(argv)` entry point; adds a stdin batch mode (one utterance per line) since the FFI backend has no worker pool; the lib file also still runs standalone (`ruby lib/phonemizer_ffi.rb ...`)
- Runtime dependency on the `ffi` gem; requires the espeak-ng shared library and data (`apt install libespeak-ng-dev`, or `PHONEMIZER_ESPEAK_LIB` for non-standard lib paths such as keg-only Homebrew installs)
- RSpec suite under `spec/`: deterministic unit specs (no espeak needed) + integration specs skipped when libespeak-ng is unavailable
- Documentation and comments in English
