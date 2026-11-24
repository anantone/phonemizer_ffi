#!/usr/bin/env ruby
# frozen_string_literal: true

require "ffi"
require_relative "phonemizer_ffi/version"

# Drop-in replacement for the espeak-ng CLI wrapper (the `phonemizer` gem),
# calling the espeak-ng C library directly via FFI — no process spawned per
# word.
#
#   apt install libespeak-ng-dev       # Debian/Ubuntu
#   brew install espeak-ng             # macOS (the lib is keg-only, see below)
#
# If the library lives outside the default search path (e.g. a keg-only
# Homebrew install), set PHONEMIZER_ESPEAK_LIB in the environment before
# loading this file:
#
#   ENV["PHONEMIZER_ESPEAK_LIB"] =
#     %x(brew --prefix espeak-ng).strip + "/lib/libespeak-ng.dylib"
#
# Backend contract (verified against libespeak-ng 1.1.51):
#   espeak_TextToPhonemes translates one *clause* per call — the text up to
#   a comma, semicolon, colon, period or similar terminator — while advancing
#   its text pointer, and returns NULL at end of input. Words within the same
#   clause influence each other (liaisons, pronounced final consonants).
#
#   IMPORTANT difference from the CLI binary: the function offers NO isolation
#   between concatenated chunks — newlines are just spaces and adjacent chunks
#   merge. Grouping several words into one buffer would therefore silently
#   corrupt the results; each piece gets its own call. It is still an
#   in-process function call, far cheaper than the CLI's fork+exec per word.
#
#   --ipa corresponds to bit 1 of phonememode (0x02); --sep to bits 8-23. The
#   phonemize pipeline always asks espeak for the \x01 sentinel byte as the
#   inter-phone separator, so any user phone_sep (multi-character, spaces,
#   "-") can be substituted on the output without collision risk; espeak_raw,
#   on the other hand, passes single-byte separators through as-is, like --sep.
module Phonemizer
  module_function

  DEFAULT_LANGUAGE = "en-us"

  # Kept for API compatibility with the CLI wrapper. In-process calls are
  # cheap and libespeak-ng is not thread-safe: there is nothing to pool.
  DEFAULT_WORKERS = 1

  # espeak emits parenthesized language tags on language switches, e.g.
  # (en) / (fr) / (pt-br); the pattern covers any tag espeak may emit.
  LANG_SWITCH = /\((?:[a-z]{2,3}(?:-[a-z0-9]+)*)\)/

  # Characters espeak would try to pronounce; we split them out instead.
  # Apostrophes are EXCLUDED on purpose: they must stay inside the word they
  # elide (aujourd'hui, l'instar). Cutting them would transcribe the two
  # halves separately and lose the liaison consonants (oʒuʁdɥi -> oʒuʁ + yi).
  PUNCT = /([[:punct:]&&[^'’‘]]+)/

  # Cache shared by the module functions. A constant (not an @ivar) so the
  # methods behave the same whether called as Phonemizer.phonemize(...) or
  # after `include Phonemizer` — module_function copies don't carry the
  # module's instance-variable context.
  CACHE = {}

  # ---------------------------------------------------------------- FFI

  module LibEspeak
    extend FFI::Library

    ffi_lib [ENV["PHONEMIZER_ESPEAK_LIB"], "libespeak-ng.so.1",
             "libespeak-ng.so", "libespeak-ng.dylib"].compact

    AUDIO_OUTPUT_SYNCHRONOUS = 2       # no audio output, no async queue
    CHARS_UTF8               = 1       # espeakCHARS_UTF8
    INITIALIZE_DONT_EXIT     = 0x8000  # return an error value instead of exit()
    PHONEME_IPA              = 0x02    # bit 1 of phonememode: IPA output

    EE_OK             = 0
    EE_INTERNAL_ERROR = -1

    # Sentinel inter-phone separator requested from espeak (encoded in bits
    # 8-23 of phonememode). \x01 never appears in IPA output, so substituting
    # it afterwards with the user's phone_sep cannot collide, whatever the
    # phone_sep is (multi-character, spaces, even "-").
    SEP_CHAR = "\x01"

    attach_function :espeak_Initialize, %i[int int pointer int], :int
    attach_function :espeak_SetVoiceByName, [:string], :int
    attach_function :espeak_SetVoiceByProperties, [:pointer], :int
    attach_function :espeak_TextToPhonemes, %i[pointer int int], :string

    # espeak_VOICE — only the fields we fill in; the rest stay zero.
    # NOTE: FFI forbids ASSIGNING :string struct fields inline (they are
    # read-only shortcuts for char*). char* members are therefore declared
    # :pointer and fed a NUL-terminated string held in a MemoryPointer (see
    # with_voice).
    class Voice < FFI::Struct
      layout :name, :pointer, :languages, :pointer, :identifier, :pointer,
             :gender, :uint8, :age, :uint8, :variant, :uint8, :xx1, :uint8,
             :score, :int, :spare, :pointer
    end

    # phonememode: always IPA; sentinel separator only in sep mode. Used by
    # the phonemize pipeline (stitch substitutes the sentinel afterwards).
    module_function

    # espeak-ng phoneme output mode flags: always IPA; in separator mode the
    # sentinel character is OR-ed into bits 8+ (the phonemize pipeline
    # substitutes the user's separator for the sentinel afterwards).
    # @param phone_sep [String] user phoneme separator ("" for none)
    # @return [Integer] espeak-ng phonememode flags
    def phonememode(phone_sep)
      mode = PHONEME_IPA
      mode |= (SEP_CHAR.ord << 8) unless phone_sep.empty?
      mode
    end

    # espeak_Initialize must run once before anything else. Idempotent.
    # AUDIO_OUTPUT_SYNCHRONOUS: no audio device is touched; DONT_EXIT turns a
    # missing espeak-ng-data into a return error instead of a brutal exit().
    def init!
      return true if @initialized
      rate = espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, nil,
                               INITIALIZE_DONT_EXIT)
      if rate == EE_INTERNAL_ERROR
        raise "espeak_Initialize failed: is espeak-ng-data installed?"
      end
      @initialized = true
    end
  end

  # ---------------------------------------------------------------- public API

  # Input: a String (one utterance) or an Array of words.
  # Returns a String (or an Array of Strings, matching the input shape).
  #
  # Options:
  #   language:        espeak voice, default "en-us"
  #   phone_sep:       inserted between phones, default "" (mɑ̃ʒe)
  #   word_sep:        joins multi-word utterances,  default " "
  #   strip_stress:    remove ˈ ˌ from the output,   default true
  #   language_switch: :remove (default) or :keep
  #   workers:         accepted, ignored (kept for API compatibility; the
  #                    library is called in-process and is not thread-safe)
  def phonemize(words, language: DEFAULT_LANGUAGE, phone_sep: "",
                word_sep: " ", strip_stress: true, language_switch: :remove,
                workers: nil)
    if words.is_a?(Array)
      phonemize_batch(words, language:, phone_sep:, word_sep:,
                      strip_stress:, language_switch:)
    else
      phonemize_batch([words], language:, phone_sep:, word_sep:,
                      strip_stress:, language_switch:).first
    end
  end

  # Clears the process-wide word -> phonemization cache. Useful between
  # unrelated batches (to free memory) or after an espeak-ng upgrade.
  def clear_cache
    CACHE.clear
  end

  # CLI-wrapper compatibility: raw transcription of one utterance. Returns
  # the raw IPA (stress marks, liaison hyphens and language tags intact).
  #
  # Mirrors espeak_raw of the phonemizer gem, where --sep=<char> makes espeak
  # itself separate the phones with the user's character (word boundaries come
  # out as double spaces in sep mode). Single-byte separators are passed
  # through as-is via bits 8-23 of phonememode — the same setting the CLI's
  # --sep uses — verified to produce byte-identical output for sep=" ".
  # Multi-byte separators are inexpressible at the espeak level (the field is
  # one byte; --sep has the same limit), so they fall back to the sentinel and
  # are then substituted; the raw output then differs from the CLI only in
  # word boundaries being spaced once.
  #
  # The CLI's trailing newline (espeak prints a whole line) is not reproduced;
  # all consumers of this value, in both implementations, strip surrounding
  # whitespace before use.
  def espeak_raw(text, language, phone_sep: nil)
    with_voice(language) do
      text = text.to_s
      sep  = phone_sep.to_s

      out =
        if sep.empty?
          transcribe_piece(text, LibEspeak::PHONEME_IPA)
        elsif sep.bytesize == 1
          # CLI parity: pass the separator byte through in bits 8-23 of
          # phonememode, exactly what --sep=<char> does at the espeak level.
          mode = LibEspeak::PHONEME_IPA | (sep.getbyte(0) << 8)
          transcribe_piece(text, mode)
        else
          # Multi-byte separator: impossible at the espeak level.
          # Transcribe with the sentinel, then substitute the user's
          # separator.
          out = transcribe_piece(text, LibEspeak.phonememode(sep))
          out.gsub(LibEspeak::SEP_CHAR, sep)
        end

      warn "WARNING: espeak-ng returned no output for: #{text[0, 40].inspect}" \
        if out.strip.empty? && !text.strip.empty?

      out
    end
  end

  # ---------------------------------------------------------------- pipeline

  # Phonemizes a whole batch of words in-process (no fork+exec per word) —
  # the FFI backend's fast path for large lexicons. Same contract as the
  # phonemizer gem's Phonemizer.phonemize_batch: drop-in replacement.
  #
  # @param words [Array<String>] the words (or short utterances) to phonemize
  # @param language [String] espeak-ng voice, e.g. "fr" (default "en-us")
  # @param phone_sep [String] inserted between phonemes, default ""
  # @param word_sep [String] joins multiword utterances, default " "
  # @param strip_stress [Boolean] remove espeak-ng stress marks (ˈ ˌ)
  # @param language_switch [Symbol] :remove (default) or :keep language tags
  # @return [Array<String>] one phonemization per input word, in order
  def phonemize_batch(words, language:, phone_sep:, word_sep:,
                     strip_stress:, language_switch:)
    # Guard for nil: only copy when some element isn't already a String
    words = words.map(&:to_s) unless words.all? { |w| w.is_a?(String) }

    # Cache: word forms repeat constantly across a lexicon. Options are fixed
    # for the whole call, so the key is a pure function of the word — memoize
    # it to build each key array only once per unique word.
    key_of = Hash.new do |h, w|
      h[w] = [w, language, phone_sep, word_sep, strip_stress, language_switch]
    end
    todo = words.uniq.reject { |w| CACHE.key?(key_of[w]) }

    unless todo.empty?
      with_voice(language) do
        # Punctuation: split utterances on punctuation, transcribe only the
        # clean chunks, then splice the punctuation back by position
        chunks = todo.map { |w| split_punctuation(w) }

        mode = LibEspeak.phonememode(phone_sep)
        clean_words = chunks.flatten.reject { |p| PUNCT.match?(p) }.uniq
        ipa_map = clean_words.each_with_object({}) do |piece, map|
          map[piece] = transcribe_piece(piece, mode)
        end

        todo.each_with_index do |w, i|
          CACHE[key_of[w]] = stitch(chunks[i], ipa_map,
                                     phone_sep:, word_sep:, strip_stress:,
                                     language_switch:)
        end
      end
    end

    words.map { |w| CACHE[key_of[w]] }
  end

  # utterance -> [punct, word, punct, word, ...]
  def split_punctuation(word)
    word.split(PUNCT).reject(&:empty?)
  end

  # Reassemble one utterance: punctuation back in place, separators applied.
  # ipa_map maps each chunk piece to its raw IPA transcription (looked up by
  # content).
  def stitch(parts, ipa_map, phone_sep:, word_sep:, strip_stress:,
             language_switch:)
    parts.map do |part|
      next part if PUNCT.match?(part)               # punctuation: verbatim
      t = ipa_map[part] || ""
      t = t.gsub(LANG_SWITCH, "") if language_switch == :remove
      # Always strip stress marks; strip the liaison hyphen only in
      # contiguous mode, where espeak emits it (e.g. "les amis" -> "le-z
      # ami"). In sep mode we transcribed with the sentinel, so a "-" in the
      # user's phone_sep must survive.
      if strip_stress
        t = t.delete("ˈˌ")
        t = t.delete("-") if phone_sep.empty?
      end
      if phone_sep.empty?
        # contiguous phones: a plain space is a word boundary
        t = t.gsub(" ", word_sep)
      else
        # Sep mode: the \x01 sentinel separates phones, a plain space marks a
        # word boundary. Substituted in a single pass, so phone_sep and
        # word_sep may contain ANY characters — including spaces — without
        # collision.
        t = t.gsub(/[\x01 ]/) do |ch|
          ch == LibEspeak::SEP_CHAR ? phone_sep : word_sep
        end
      end
      t
    end.join
  end

  # ---------------------------------------------------------------- internals

  # Voice selection in libespeak-ng is global state; set it before
  # transcribing. Initialization guaranteed: every entry point goes through
  # here.
  #
  # Mirrors the espeak-ng CLI: SetVoiceByName recognizes installed voices and
  # variants; pure language codes it doesn't know ("fr-fr" on a system that
  # only installs "fr") fall back to SetVoiceByProperties, which matches on
  # the language (plus dialect) only.
  #
  # The languages field must be a NUL-terminated char*: Ruby's :string
  # coercion only applies to function ARGUMENTS, not to struct fields, and
  # :string struct fields are read-only in FFI — hence the explicit
  # MemoryPointer here. `lang` is kept alive on the local stack for the whole
  # call, which satisfies the struct's lifetime requirement.
  def with_voice(language)
    LibEspeak.init!
    rc = LibEspeak.espeak_SetVoiceByName(language)
    if rc != LibEspeak::EE_OK
      lang = FFI::MemoryPointer.from_string(language) # NUL-terminated
      spec = LibEspeak::Voice.new
      spec[:languages] = lang
      rc = LibEspeak.espeak_SetVoiceByProperties(spec)
    end
    unless rc == LibEspeak::EE_OK
      raise "espeak-ng: cannot select voice #{language.inspect}"
    end

    yield
  end

  # Transcribes one piece with the given phonememode. A piece normally holds a
  # single clause (punctuation was split out upstream), but we keep draining
  # clauses as a precaution: a stray terminator would otherwise be silently
  # dropped, and joining the fragments keeps the result sane.
  #
  # Clause fragments are joined with a plain space, like the CLI's one-line
  # IPA output ("words separated by spaces on one line, in input order" — the
  # C API just delivers one clause at a time).
  def transcribe_piece(piece, mode)
    buf = FFI::MemoryPointer.from_string(piece)
    tp  = FFI::MemoryPointer.new(:pointer)
    tp.write_pointer(buf)

    clauses = []
    while (clause = LibEspeak.espeak_TextToPhonemes(
             tp, LibEspeak::CHARS_UTF8, mode
           ))
      clauses << clause
      break if tp.read_pointer.null?
    end
    # FFI returns ASCII-8BIT strings; the IPA payload is UTF-8.
    clauses.join(" ").strip.force_encoding(Encoding::UTF_8)
  end

  # ---------------------------------------------------------------- CLI

  # Command-line entry point, mirroring the phonemize bin of the phonemizer
  # gem so this single file serves as both library and command
  # (bin/phonemize_ffi is a thin wrapper around this method). Differences from
  # the gem's bin/phonemize, all imposed by the backend:
  #   * no --workers/-j flag (single-threaded FFI backend)
  #   * stdin mode added: the CLI has no batch interface on stdin, and the
  #     library has no worker pool, so lines from stdin are the natural
  #     high-throughput path for this backend.
  def main(argv = ARGV)
    require "optparse"

    options = {
      language: Phonemizer::DEFAULT_LANGUAGE,
      phone_sep: "",
      word_sep: " ",
      strip_stress: true,
      language_switch: :remove
    }

    parser = OptionParser.new do |o|
      o.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options] [text | file]"
      o.on("-l", "--language LANG",
           "espeak voice (default: #{Phonemizer::DEFAULT_LANGUAGE})") { |v| options[:language] = v }
      o.on("-p", "--phone-sep SEP",
           "separator between phones (default: none)") { |v| options[:phone_sep] = v }
      o.on("-w", "--word-sep SEP",
           "separator between words in one utterance (default: space)") { |v| options[:word_sep] = v }
      o.on("-s", "--[no-]strip-stress",
           "strip stress marks and liaison hyphens (default: yes)") { |v| options[:strip_stress] = v }
      o.on("-k", "--keep-language-switch",
           "keep inline (en)/(fr) language tags (default: remove)") { options[:language_switch] = :keep }
      o.on("-h", "--help", "show this help") do
        puts o
        exit
      end
    end
    parser.parse!(argv)

    # Batch stdin mode: one line = one utterance, transcribed in a single batch.
    if argv.empty? && !$stdin.tty?
      lines = $stdin.read.lines.map(&:strip).reject(&:empty?)
      exit if lines.empty?
      Phonemizer.phonemize(lines, **options).each { |line| puts line }
    else
      text = argv.join(" ")
      if File.file?(text)
        lines = File.readlines(text, chomp: true).reject(&:empty?)
        Phonemizer.phonemize(lines, **options).each { |line| puts line }
      else
        puts Phonemizer.phonemize(text, **options)
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Executable mode: only runs when this file is invoked directly
# (ruby lib/phonemizer_ffi.rb ... or via a link/execbit), so requiring it from
# elsewhere stays side-effect free.
Phonemizer.main(ARGV) if $PROGRAM_NAME == __FILE__
