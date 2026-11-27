# Changelog

## 0.1.4 - 2026-11-26

### Breaking changes

`Phonemizer.phonemize` called with the documented options is unaffected (output byte-identical, see below; verified against the `scansion` gem's suite). Code that relied on internals or undocumented behavior may break:

- Internal helpers (`phonemize_batch`, `stitch`, `transcribe_piece`, `with_voice`, …) are now private; the public API is `phonemize`, `espeak_raw`, `clear_cache` and `main`. `phonemize_batch` was documented as public in 0.1.1; call `phonemize` with an Array instead. `stitch` also changed signature: it now takes a batch-local `piece -> IPA` map instead of reading the cache
- Cache key is now `[piece, language, phonememode]` instead of `[piece, language, phone_sep]`: raw IPA only depends on whether a separator is requested, so all non-empty `phone_sep` values share entries. Code reading `IPA_CACHE` directly will no longer find `[piece, language, phone_sep]` keys
- `phonemize` raises `ArgumentError` for a `language_switch` other than `:remove` / `:keep` (it was silently treated as `:keep`)
- `clear_cache` now returns `nil` (it returned the internal cache Hash)
- CLI file mode now strips leading and trailing whitespace from each line (as stdin mode already did)

### Fixes and improvements

- **Fix: batches could come back as empty strings.** When a batch pushed the cache past `MAX_CACHE_SIZE`, the cache was cleared *after* the new transcriptions were written and *before* they were read back, so every word of that batch came back as `""` (any single call with more than 50,000 unique pieces, or whichever call crossed the cap in a long-running process). Under concurrency, another thread's eviction could blank a batch the same way. Batches are now assembled from a batch-local `piece -> IPA` map; the cache is cleared *before* inserting, never exceeds `MAX_CACHE_SIZE`, and a missing transcription raises `Phonemizer::Error` instead of silently yielding `""`
- Thread safety: every `IPA_CACHE` read and write now happens with `ESPEAK_LOCK` held (previously reads were outside the lock), so the guarantee no longer depends on MRI's GVL
- Removed the `phone_sep == "\x01"` check: substitution is single-pass, so even the sentinel itself is a valid separator
- Library loading: Homebrew locations (`/opt/homebrew`, `/usr/local`, linked or keg-only) are searched automatically, and a failure raises a `LoadError` with install instructions and a pointer to `PHONEMIZER_ESPEAK_LIB`
- CLI: new `-f/--file PATH` and `-v/--version`; unknown voices, missing files and invalid options print a one-line message on stderr and exit 1 instead of a backtrace; a single argument is read as a file only if it is a regular file (a directory name is now phonemized as text instead of crashing with `EISDIR`)
- Tooling: rubocop added to the bundle with a `rake rubocop` task, `rake` now runs specs + rubocop; `.rubocop.yml` cleaned of settings inherited from the `scansion` gem and Metrics caps lowered; development dependencies moved from the gemspec to the Gemfile; `rubygems_mfa_required` metadata
- No change in transcription output: verified byte-identical to 0.1.3 across 9 option combinations x 9 texts x 2 languages

## 0.1.3 - 2026-11-25

- Internal refactor of the cache: `CACHE` renamed to `IPA_CACHE` and now stores only raw per-piece IPA keyed by `[piece, language, phone_sep]`; the cheap post-processing (separator substitution, stress stripping, language-switch removal) is no longer cached and is recomputed on every call
- `validate_phone_sep!` rejects a `phone_sep` equal to the `\x01` sentinel used internally as phone separator
- `MAX_CLAUSES = 1000` cap on the number of clauses per text to bound the FFI call fan-out
- `stitch` signature change: `stitch(parts, ipa_map, phone_sep:, ...)` → `stitch(parts, language:, phone_sep:, ...)`, reading from `IPA_CACHE`; unit specs updated accordingly (helper that seeds `IPA_CACHE` with a test language)
- Thread safety: new `ESPEAK_LOCK` mutex serializes every call into libespeak-ng (global voice state) via `with_voice`, making `Phonemizer` safe to call from multiple threads (transcriptions are serialized); verified: 4 threads x 4 languages produce results identical to single-threaded
- Bounded cache: `MAX_CACHE_SIZE = 50_000`; once reached, `IPA_CACHE` is wiped wholesale (`evict_cache_if_full`) so long-running processes don't grow memory without bound
- New `Phonemizer::Error < StandardError` raised instead of bare `RuntimeError` on espeak failures (init failure, voice not found, clause cap exceeded) — note: `rescue RuntimeError` no longer catches these, bare `rescue` still does
- CLI: running with no arguments on a TTY now prints the usage to stderr and exits 1 (previously it phonemized the empty string); stdin-pipe and file modes unchanged
- No behavior change in transcription output: verified byte-identical to 0.1.2 across 9 option combinations x 9 texts

## 0.1.2 - 2026-11-24

- rubocop: added `.rubocop.yml` (TargetRubyVersion 3.1, NewCops disabled, single quotes, Metrics caps raised to the current state, BlockLength excluded for spec/); autocorrections applied; 0 offenses, specs unchanged

## 0.1.1 - 2026-11-24

- RDoc: document the remaining public methods (`phonememode`, `clear_cache`, `phonemize_batch` with `@param`/`@return`); add an `rdoc` task to the Rakefile (`rake rdoc` generates the HTML docs, README as home page) and `rdoc` as a development dependency
- YARD support for rubydoc.info: `.yardopts` file (markdown markup, README as front page), `rake yard` task in the Rakefile (aliased as `rake doc`, generates `doc/`); `yard` and `kramdown` added as development dependencies; gemspec metadata (`source_code_uri`, `changelog_uri`, `bug_tracker_uri`, `documentation_uri`) pointing at the GitHub repo and `https://rubydoc.info/gems/phonemizer_ffi`; documentation link added to the README. Documentation-only change

## 0.1.0 - 2026-11-22

- Initial release. `lib/phonemizer_ffi.rb` (extracted from the `scansion` gem) packaged as a standalone gem: a drop-in, API-compatible replacement for the `phonemizer` gem that calls libespeak-ng in-process via FFI instead of fork+exec-ing the espeak-ng CLI per word (~40x faster on a 500-word batch, byte-identical output in default mode)
- `phonemize_ffi` executable (`bin/phonemize_ffi`), registered via `spec.executables` and routed through the new `Phonemizer.main(argv)` entry point; adds a stdin batch mode (one utterance per line) since the FFI backend has no worker pool; the lib file also still runs standalone (`ruby lib/phonemizer_ffi.rb ...`)
- Runtime dependency on the `ffi` gem; requires the espeak-ng shared library and data (`apt install libespeak-ng-dev`, or `PHONEMIZER_ESPEAK_LIB` for non-standard lib paths such as keg-only Homebrew installs)
- RSpec suite under `spec/`: deterministic unit specs (no espeak needed) + integration specs skipped when libespeak-ng is unavailable
- Documentation and comments in English
