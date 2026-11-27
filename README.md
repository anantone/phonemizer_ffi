phonemizer_ffi
==============

[![Gem Version](https://img.shields.io/gem/v/phonemizer_ffi.svg)](https://rubygems.org/gems/phonemizer_ffi)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-rubydoc.info-blue.svg)](https://rubydoc.info/gems/phonemizer_ffi)

An in-process [espeak-ng](https://github.com/espeak-ng/espeak-ng) phonemizer for Ruby: a **drop-in replacement for the [`phonemizer`](https://rubygems.org/gems/phonemizer) gem** that calls the `libespeak-ng` C library directly via [FFI](https://rubygems.org/gems/ffi) instead of spawning the `espeak-ng` CLI process once per word. Same API, same output — typically **one to two orders of magnitude faster** on large batches. Supports [these languages](https://github.com/espeak-ng/espeak-ng/blob/master/docs/languages.md).


Why phonemizer_ffi instead of phonemizer?
----------------------------------------------------------------

| | `phonemizer` | `phonemizer_ffi` |
|---|---|---|
| Backend | `espeak-ng` CLI, one fork+exec per word | `libespeak-ng` via FFI, plain in-process function call |
| Process spawns | one per word | none |
| Parallelism | worker pool (`workers:`, default CPUs − 1) | none needed — calls are that cheap; `workers:` is accepted but ignored |
| Extra install | `espeak-ng` binary only | `ffi` gem + `libespeak-ng` shared library and data (`libespeak-ng-dev`) |
| API | `Phonemizer.phonemize(...)` | **identical** (drop-in: swap the `require`) |

Measured on this machine (Ruby 4.0, espeak-ng 1.52, 500 unique French words from Lexique):

```text
phonemizer     (CLI, fork+exec per word):  0.79 s
phonemizer_ffi (FFI, in-process):          0.02 s    # ~40x faster
```

The CLI wrapper pays a fork+exec+pipe round-trip per word (~1–2 ms each); the FFI backend pays a single in-process function call (microseconds). Process-spawn overhead — not phonemization itself — dominates the CLI gem's runtime, so on a 250k-word lexicon the difference is minutes vs. seconds.

**Output parity:** on the same 500-word sample, `phonemizer_ffi` produces byte-identical output to `phonemizer` in the default contiguous mode (`phone_sep: ""`). In sep mode the only possible difference is a word boundary being spaced once instead of twice around liaison hyphens — an inherent espeak-ng `--sep` limitation, documented in the comments of `lib/phonemizer_ffi.rb`.

Trade-offs:

- You need the espeak-ng **shared library and data**, not just the CLI binary (`apt install libespeak-ng-dev`, or `brew install espeak-ng` on macOS — see below).
- Unlike the CLI gem, this one **is thread-safe** (libespeak-ng keeps global voice state, so all calls into it are serialized through an internal process-wide mutex — see Thread Safety below); the price is that transcriptions never run in parallel. There is no worker pool to tune — one process is usually faster than the CLI's parallel spawns anyway.
- Do not load both gems in the same process: both define the `Phonemizer` module on purpose (drop-in replacement) and their constants would clash.


Requirements
----------------------------------------------------------------

- Ruby 3.1+
- The `ffi` gem (declared as a runtime dependency of this gem)
- The **espeak-ng shared library** and its data:
  ```bash
  apt install libespeak-ng-dev   # Debian/Ubuntu (lib + espeak-ng-data)
  brew install espeak-ng         # macOS
  ```
  The standard Homebrew locations (`/opt/homebrew` and `/usr/local`, linked or keg-only) are searched automatically. If the library lives anywhere else, point `PHONEMIZER_ESPEAK_LIB` at it before loading the gem:
  ```ruby
  ENV["PHONEMIZER_ESPEAK_LIB"] = %x(brew --prefix espeak-ng).strip + "/lib/libespeak-ng.dylib"
  ```


Installation
----------------------------------------------------------------

Add to your Gemfile:

```ruby
gem "phonemizer_ffi"
```

Or install directly:

```bash
gem install phonemizer_ffi
```


Usage
----------------------------------------------------------------

Same API as the `phonemizer` gem — swap `require "phonemizer"` for `require "phonemizer_ffi"`:

```ruby
require "phonemizer_ffi"

# Single word
Phonemizer.phonemize("manger", language: "fr-fr")
# => "mɑ̃ʒe"

# Batch - pass an Array, get an Array back (same order). This is where the
# speedup shows: one in-process pass, no process spawned per word.
Phonemizer.phonemize(["docteur", "tableau", "pastille"], language: "fr-fr")
# => ["dɔktœʁ", "tablo", "pastij"]

# A whole lexicon in one call (the internal cache dedupes repeated forms)
lines = File.readlines("lexique.txt", chomp: true).reject(&:empty?)
ipa = Phonemizer.phonemize(lines, language: "fr-fr") # Array of IPA strings, same order
```


Options
----------------------------------------------------------------

```ruby
Phonemizer.phonemize(
  "les amis",
  language:        "fr-fr",    # espeak voice (default "en-us")
  phone_sep:       "",         # separator between phones ("" = contiguous)
  word_sep:        " ",        # separator between words in one utterance
  strip_stress:    true,       # remove stress marks and liaison hyphens
  language_switch: :remove,    # :remove or :keep, for inline (fr)/(en) tags
  workers:         nil         # accepted for drop-in compatibility, IGNORED:
                               # espeak calls are serialized internally
                               # (see Thread Safety)
)
```

Separate each phone explicitly:

```ruby
Phonemizer.phonemize("tableau", language: "fr-fr", phone_sep: " ")
# => "t a b l o"
```

Keep the language-switch markers espeak emits mid-utterance:

```ruby
Phonemizer.phonemize("le célèbre Schwarzenegger", language: "fr-fr", language_switch: :keep)
# => "lə selɛbʁ (en)ʃwɔːzənɛɡə(fr)"
```


Command line
----------------------------------------------------------------

The `phonemize_ffi` executable exposes the same options as `phonemize`, minus `-j/--workers`, plus a **stdin batch mode** (one utterance per line — the natural high-throughput path for this backend, since there is no worker pool). Pass text as arguments, or a file to phonemize it line by line (lines are stripped, blank lines skipped):

```bash
phonemize_ffi "hello world"
phonemize_ffi -l fr-fr "les amis"
phonemize_ffi -l fr-fr -f words.txt > words.ipa      # explicit file
phonemize_ffi -l fr-fr words.txt > words.ipa         # a single argument naming a regular file
cat words.txt | phonemize_ffi -l fr-fr > words.ipa   # stdin batch mode
```

A single argument is read as a file only if it names an existing regular file; use `-f` to be explicit, or quote/combine words to force text. Errors (unknown voice, missing file, bad option) are printed on stderr with exit status 1.

```bash
phonemize_ffi --help
# Usage: phonemize_ffi [options] [text | file]
#     -l, --language LANG           espeak voice (default: en-us)
#     -p, --phone-sep SEP           separator between phones (default: none)
#     -w, --word-sep SEP            separator between words (default: space)
#     -s, --[no-]strip-stress       strip stress marks and liaison hyphens (default: yes)
#     -k, --keep-language-switch    keep inline (en)/(fr) language tags (default: remove)
#     -f, --file PATH               phonemize PATH line by line
#     -v, --version                 show version
#     -h, --help                    show this help
```

```bash
phonemize_ffi -l fr-fr -p " " tableau
# => t a b l o
```

The library file also runs standalone (`ruby lib/phonemizer_ffi.rb ...`), so it can be vendored as a single file.


Punctuation
----------------------------------------------------------------

Punctuation is preserved verbatim and never sent to espeak, so whole sentences pass through cleanly:

```ruby
Phonemizer.phonemize("Bonjour, comment ça va ?", language: "fr-fr")
# => "bɔ̃ʒuʁ,kɔmɑ̃ sa va?"
```

Apostrophes are kept inside the word on purpose, so elisions stay intact and liaison consonants aren't lost:

```ruby
Phonemizer.phonemize("aujourd'hui", language: "fr-fr")
# => "oʒuʁdyi"
```


Caching
----------------------------------------------------------------

Raw transcriptions are cached per piece, language and separator mode — a *piece* being each punctuation-free chunk of a word, and the mode being just "contiguous" vs. "separated", so every non-empty `phone_sep` shares the same entries. Post-processing (separator substitution, stress stripping, language-switch removal) is cheap string work and is recomputed on every call, not cached. Useful when the same forms recur across a large lexicon.

The cache is bounded: it never holds more than 50,000 entries (`MAX_CACHE_SIZE`). When a batch would overflow it, it is wiped wholesale first, so a long-running process doesn't grow memory without bound. Results are always assembled from a per-batch map, so batches of any size — including a whole lexicon larger than the cache — come back complete. Call `clear_cache` to free memory or start fresh:

```ruby
Phonemizer.clear_cache
```


How it works
----------------------------------------------------------------

- `espeak_TextToPhonemes` transcribes one *clause* per call (text up to a comma, semicolon, colon, period…), advancing its text pointer. The pipeline splits punctuation out first, so each clean piece is transcribed on its own — adjacent pieces are never merged into one buffer, because the C API gives no isolation between concatenated chunks (unlike the CLI's `--stdin`, newlines are just spaces there).
- The pipeline always asks espeak for the `\x01` sentinel byte as inter-phone separator (bits 8-23 of `phonememode`, the same field as `--sep`). `\x01` never occurs in IPA output, so any user `phone_sep` — multi-character, containing spaces, even `"-"` — is substituted afterwards in a single pass without collision risk. `espeak_raw` instead passes single-byte separators straight through, for byte-level parity with the CLI's `--sep`.
- Voice selection mirrors the CLI: `espeak_SetVoiceByName` for installed voices/variants, falling back to `espeak_SetVoiceByProperties` on the language code (e.g. `"fr-fr"` when only `"fr"` is installed).


Thread Safety
----------------------------------------------------------------

This gem **is thread-safe**: libespeak-ng keeps global voice state (the selected voice), so every call into the library — initialization, voice selection, transcription — and every cache access is serialized through a process-wide mutex (`ESPEAK_LOCK`). You can call `Phonemizer.phonemize` from multiple threads; the transcriptions are simply serialized, never run in parallel, and each thread's results are identical to a single-threaded call:

```ruby
words = File.readlines("lexique.txt", chomp: true)
threads = 4.times.map { Thread.new { Phonemizer.phonemize(words, language: "fr-fr") } }
threads.each(&:join) # no Mutex of your own needed
```


API Reference
----------------------------------------------------------------

### `Phonemizer.phonemize(words, **options)`

Phonemize text to IPA. Returns a String for String input, Array for Array input.

**Arguments:**
- `words` — String or Array of Strings
- `language` — espeak voice (default: `"en-us"`)
- `phone_sep` — separator between phones (default: `""`)
- `word_sep` — separator between words in multi-word input (default: `" "`)
- `strip_stress` — remove stress marks ˈ ˌ and liaison hyphens (default: `true`)
- `language_switch` — `:remove` or `:keep` for inline language tags (default: `:remove`)
- `workers` — accepted for drop-in compatibility with the `phonemizer` gem, **ignored** (in-process backend; espeak calls are serialized through an internal mutex — see Thread Safety)

Raises `ArgumentError` for an unknown `language_switch`, and `Phonemizer::Error` when espeak-ng fails (e.g. a voice that cannot be selected).

### `Phonemizer.espeak_raw(text, language, phone_sep: nil)`

Low-level: transcribe one utterance via libespeak-ng directly. Returns the raw IPA output string (stress marks, liaison hyphens and language tags intact).

**Arguments:**
- `text` — text to phonemize
- `language` — espeak voice
- `phone_sep` — optional separator (single-byte separators are passed to espeak as-is, like `--sep`; multi-byte ones fall back to the sentinel and are substituted)

### `Phonemizer.clear_cache`

Clear the internal phonemization cache. Returns `nil`.

### `Phonemizer.main(argv = ARGV)`

Command-line entry point used by the `phonemize_ffi` executable.


Development
----------------------------------------------------------------

```bash
bundle install
bundle exec rake      # specs + rubocop
bundle exec rspec     # specs only
bundle exec rake yard # docs into doc/
```

The integration specs are skipped automatically when libespeak-ng cannot be loaded in-process; the unit specs are deterministic and need no espeak at all.


Structure
----------------------------------------------------------------

```
├── bin/phonemize_ffi              executable (thin wrapper around Phonemizer.main)
├── lib/phonemizer_ffi.rb          library + CLI entry point Phonemizer.main
├── lib/phonemizer_ffi/version.rb  Phonemizer::VERSION
└── spec/                          RSpec suite (unit + integration)
```


Contributing
----------------------------------------------------------------

Bug reports and pull requests are welcome on [GitHub](https://github.com/anantone/phonemizer_ffi).


License
----------------------------------------------------------------

MIT
