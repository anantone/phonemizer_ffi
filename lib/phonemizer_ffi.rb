#!/usr/bin/env ruby
# frozen_string_literal: true

require 'ffi'
require_relative 'phonemizer_ffi/version'

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
# Requires Ruby >= 3.1 (shorthand hash syntax in method calls).
#
# Thread safety: libespeak-ng keeps global state (selected voice), so all
# calls into it are serialized through a process-wide mutex. It is safe to
# call Phonemizer from multiple threads, but transcriptions will be
# serialized.
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
#   phonemize pipeline asks espeak for the \x01 sentinel byte as inter-phone
#   separator whenever a phone_sep is requested, so any user phone_sep
#   (multi-character, spaces, "-") can be substituted on the output without
#   collision risk; espeak_raw, on the other hand, passes single-byte
#   separators through as-is, like --sep.
module Phonemizer
  module_function

  class Error < StandardError; end

  DEFAULT_LANGUAGE = 'en-us'

  # Kept for API compatibility with the CLI wrapper. In-process calls are
  # cheap and libespeak-ng is not thread-safe: there is nothing to pool.
  # All espeak calls are serialized through ESPEAK_LOCK instead.
  DEFAULT_WORKERS = 1

  # espeak emits parenthesized language tags on language switches, e.g.
  # (en) / (fr) / (pt-br); the pattern covers any tag espeak may emit.
  LANG_SWITCH = /\((?:[a-z]{2,3}(?:-[a-z0-9]+)*)\)/

  # Characters espeak would try to pronounce; we split them out instead.
  # Apostrophes are EXCLUDED on purpose: they must stay inside the word they
  # elide (aujourd'hui, l'instar). Cutting them would transcribe the two
  # halves separately and lose the liaison consonants (oʒuʁdɥi -> oʒuʁ + yi).
  PUNCT = /([[:punct:]&&[^'’‘]]+)/

  # Transcription cache keyed on [piece, language, phone_sep] -> raw IPA.
  # This is the expensive part (the FFI call). Post-processing (stress
  # stripping, separator substitution, language-switch removal) is cheap
  # string work and is NOT cached — so the hit rate is maximized across
  # calls that differ only in formatting options.
  #
  # In a long-running process user-generated words would grow it without
  # bound; it is wiped wholesale once it reaches MAX_CACHE_SIZE entries.
  IPA_CACHE = {} # rubocop:disable Style/MutableConstant
  MAX_CACHE_SIZE = 50_000

  # Safety cap for the clause-draining loop. A healthy call returns 1-2
  # clauses; anything above this indicates a bug in the C library or input.
  MAX_CLAUSES = 1000

  # Serializes every call into libespeak-ng (global voice state, init) and
  # guards concurrent writes to IPA_CACHE.
  ESPEAK_LOCK = Mutex.new

  # ---------------------------------------------------------------- FFI

  # Bindings for libespeak-ng (espeak_Initialize, espeak_TextToPhonemes, …).
  module LibEspeak
    extend FFI::Library

    ffi_lib [ENV['PHONEMIZER_ESPEAK_LIB'], 'libespeak-ng.so.1',
             'libespeak-ng.so', 'libespeak-ng.dylib'].compact

    AUDIO_OUTPUT_SYNCHRONOUS = 2       # no audio output, no async queue
    CHARS_UTF8               = 1       # espeakCHARS_UTF8
    INITIALIZE_DONT_EXIT     = 0x8000  # return an error value instead of exit()
    PHONEME_IPA              = 0x02    # bit 1 of phonememode: IPA output

    EE_OK             = 0
    EE_INTERNAL_ERROR = -1

    # Sentinel inter-phone separator requested from espeak (encoded in bits
    # 8-23 of phonememode). \x01 never appears in IPA output, so substituting
    # it afterwards with the user's phone_sep cannot collide.
    SEP_CHAR = "\x01"

    attach_function :espeak_Initialize, %i[int int pointer int], :int
    attach_function :espeak_SetVoiceByName, [:string], :int
    attach_function :espeak_SetVoiceByProperties, [:pointer], :int
    # C signature (speak_lib.h, espeak-ng 1.51+):
    #   const char *espeak_TextToPhonemes(const void **textptr, int textmode, int phonememode);
    attach_function :espeak_TextToPhonemes, %i[pointer int int], :string

    # espeak_VOICE — only the fields we fill in; the rest stay zero.
    # NOTE: FFI forbids assigning :string struct fields inline (read-only
    # shortcuts for char*). char* members are declared :pointer and fed a
    # NUL-terminated string held in a MemoryPointer.
    class Voice < FFI::Struct
      layout :name, :pointer, :languages, :pointer, :identifier, :pointer,
             :gender, :uint8, :age, :uint8, :variant, :uint8, :xx1, :uint8,
             :score, :int, :spare, :pointer
    end

    module_function

    # espeak-ng phonememode flags: always IPA; in separator mode the
    # sentinel character is OR-ed into bits 8+.
    def phonememode(phone_sep)
      mode = PHONEME_IPA
      mode |= (SEP_CHAR.ord << 8) unless phone_sep.empty?
      mode
    end

    # espeak_Initialize must run once before anything else. Idempotent.
    # Called with ESPEAK_LOCK held.
    def init!
      return true if @initialized

      rate = espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, nil,
                               INITIALIZE_DONT_EXIT)
      raise Error, 'espeak_Initialize failed: is espeak-ng-data installed?' if rate == EE_INTERNAL_ERROR

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
  #   workers:         accepted, ignored (API compatibility)
  def phonemize(words, language: DEFAULT_LANGUAGE, phone_sep: '',
                word_sep: ' ', strip_stress: true, language_switch: :remove,
                workers: nil) # rubocop:disable Lint/UnusedMethodArgument
    validate_phone_sep!(phone_sep)

    if words.is_a?(Array)
      phonemize_batch(words, language:, phone_sep:, word_sep:,
                             strip_stress:, language_switch:)
    else
      phonemize_batch([words], language:, phone_sep:, word_sep:,
                               strip_stress:, language_switch:).first
    end
  end

  # Clears the process-wide transcription cache.
  def clear_cache
    IPA_CACHE.clear
  end

  # CLI-wrapper compatibility: raw transcription of one utterance. Returns
  # the raw IPA (stress marks, liaison hyphens and language tags intact).
  # Deliberately bypasses IPA_CACHE: raw output is for diagnostics, and
  # caching it would double the memory footprint for rarely-repeated calls.
  def espeak_raw(text, language, phone_sep: nil)
    sep = phone_sep.to_s
    validate_phone_sep!(sep)

    with_voice(language) do
      text = text.to_s

      if sep.empty?
        transcribe_piece(text, LibEspeak::PHONEME_IPA)
      elsif sep.bytesize == 1
        mode = LibEspeak::PHONEME_IPA | (sep.getbyte(0) << 8)
        transcribe_piece(text, mode)
      else
        out = transcribe_piece(text, LibEspeak.phonememode(sep))
        out.gsub(LibEspeak::SEP_CHAR, sep)
      end
    end
  end

  # ---------------------------------------------------------------- pipeline

  # Phonemizes a whole batch. The expensive FFI transcription is cached by
  # [piece, language, phone_sep]; post-processing is recomputed each call
  # (it's just string ops, nanoseconds vs. microseconds for the FFI call).
  def phonemize_batch(words, language:, phone_sep:, word_sep:,
                      strip_stress:, language_switch:)
    words = words.map(&:to_s)

    # Phase 1: collect all unique clean pieces that need transcription
    mode = LibEspeak.phonememode(phone_sep)
    chunks_by_word = {}
    pending = {} # Hash used as an ordered set of unique pieces to transcribe

    words.uniq.each do |w|
      chunks = split_punctuation(w)
      chunks_by_word[w] = chunks
      chunks.each do |piece|
        next if PUNCT.match?(piece)
        next if IPA_CACHE.key?([piece, language, phone_sep])

        pending[piece] = true
      end
    end

    # Phase 2: single voice-switch, batch-transcribe all uncached pieces
    unless pending.empty?
      with_voice(language) do
        pending.each_key do |piece|
          IPA_CACHE[[piece, language, phone_sep]] = transcribe_piece(piece, mode)
        end
        evict_cache_if_full
      end
    end

    # Phase 3: stitch (cheap string ops, not cached)
    words.map do |w|
      stitch(chunks_by_word[w], language:, phone_sep:, word_sep:,
                                strip_stress:, language_switch:)
    end
  end

  # ---------------------------------------------------------------- internals

  # Keeps the cache bounded: past MAX_CACHE_SIZE entries, drop everything.
  # Rebuilding the entries is cheap relative to the memory an unbounded
  # cache costs in a long-running process.
  def evict_cache_if_full
    IPA_CACHE.clear if IPA_CACHE.size >= MAX_CACHE_SIZE
  end

  # utterance -> [word, punct, word, punct, ...]
  def split_punctuation(word)
    word.split(PUNCT).reject(&:empty?)
  end

  # Reassemble one utterance from its pre-split chunks.
  def stitch(parts, language:, phone_sep:, word_sep:, strip_stress:,
             language_switch:)
    parts.filter_map do |part|
      next part if PUNCT.match?(part)

      raw = IPA_CACHE[[part, language, phone_sep]] || ''
      post_process(raw, phone_sep:, word_sep:, strip_stress:, language_switch:)
    end.join
  end

  # Applies all formatting transformations to a raw IPA string.
  def post_process(t, phone_sep:, word_sep:, strip_stress:, language_switch:)
    t = t.gsub(LANG_SWITCH, '') if language_switch == :remove

    if strip_stress
      t = t.delete('ˈˌ')
      # Liaison hyphens only appear in contiguous mode (no phone_sep).
      # In sep mode the user's phone_sep might legitimately be "-",
      # so we must not delete hyphens there.
      t = t.delete('-') if phone_sep.empty?
    end

    substitute_separators(t, phone_sep:, word_sep:)
  end

  # Replaces the sentinel (\x01) and word-boundary spaces with user separators.
  # Single-pass gsub so phone_sep and word_sep can contain any characters
  # (including spaces or the other separator) without collision.
  def substitute_separators(t, phone_sep:, word_sep:)
    if phone_sep.empty?
      # Contiguous mode: a plain space is a word boundary
      t.gsub(' ', word_sep)
    else
      # Sep mode: \x01 = phone boundary, space = word boundary
      t.gsub(/[\x01 ]/) do |ch|
        ch == LibEspeak::SEP_CHAR ? phone_sep : word_sep
      end
    end
  end

  # Voice selection: mirrors the espeak-ng CLI. SetVoiceByName first,
  # fallback to SetVoiceByProperties for pure language codes.
  #
  # The languages field must be a NUL-terminated char*: Ruby's :string
  # coercion only applies to function arguments, not struct fields.
  #
  # Serialized: espeak keeps the selected voice in global state, so two
  # threads picking different voices would corrupt each other's output.
  def with_voice(language)
    ESPEAK_LOCK.synchronize do
      LibEspeak.init!
      rc = LibEspeak.espeak_SetVoiceByName(language)
      if rc != LibEspeak::EE_OK
        lang = FFI::MemoryPointer.from_string(language)
        spec = LibEspeak::Voice.new
        spec[:languages] = lang
        rc = LibEspeak.espeak_SetVoiceByProperties(spec)
      end
      raise Error, "espeak-ng: cannot select voice #{language.inspect}" unless rc == LibEspeak::EE_OK

      yield
    end
  end

  # Transcribes one piece, draining all clauses. Defensive: a stray
  # terminator inside a piece would otherwise silently truncate output.
  # MAX_CLAUSES guards against an infinite loop from a buggy C library.
  def transcribe_piece(piece, mode)
    buf = FFI::MemoryPointer.from_string(piece)
    tp  = FFI::MemoryPointer.new(:pointer)
    tp.write_pointer(buf)

    clauses = []
    loop do
      clause = LibEspeak.espeak_TextToPhonemes(tp, LibEspeak::CHARS_UTF8, mode)
      break unless clause

      clauses << clause
      break if tp.read_pointer.null?

      raise Error, "espeak_TextToPhonemes: exceeded #{MAX_CLAUSES} clauses for #{piece.inspect}" \
        if clauses.size >= MAX_CLAUSES
    end

    clauses.join(' ').strip.force_encoding(Encoding::UTF_8)
  end

  # ---------------------------------------------------------------- validation

  # The sentinel \x01 is used internally to mark phone boundaries before
  # substitution. If the user passes it as phone_sep, substitution would be
  # ambiguous.
  def validate_phone_sep!(phone_sep)
    return unless phone_sep == LibEspeak::SEP_CHAR

    raise ArgumentError,
          'phone_sep cannot be the sentinel character (\\x01); ' \
          'choose a different separator'
  end

  # ---------------------------------------------------------------- CLI

  def main(argv = ARGV)
    require 'optparse'

    options = {
      language: DEFAULT_LANGUAGE,
      phone_sep: '',
      word_sep: ' ',
      strip_stress: true,
      language_switch: :remove
    }

    parser = OptionParser.new do |o|
      o.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options] [text | file]"
      o.on('-l', '--language LANG',
           "espeak voice (default: #{DEFAULT_LANGUAGE})") { |v| options[:language] = v }
      o.on('-p', '--phone-sep SEP',
           'separator between phones (default: none)') { |v| options[:phone_sep] = v }
      o.on('-w', '--word-sep SEP',
           'separator between words in one utterance (default: space)') { |v| options[:word_sep] = v }
      o.on('-s', '--[no-]strip-stress',
           'strip stress marks and liaison hyphens (default: yes)') { |v| options[:strip_stress] = v }
      o.on('-k', '--keep-language-switch',
           'keep inline (en)/(fr) language tags (default: remove)') { options[:language_switch] = :keep }
      o.on('-h', '--help', 'show this help') do
        puts o
        exit
      end
    end
    parser.parse!(argv)

    if argv.empty? && !$stdin.tty?
      lines = $stdin.read.lines.map(&:strip).reject(&:empty?)
      exit if lines.empty?
      phonemize(lines, **options).each { |line| puts line }
    elsif argv.empty?
      warn parser
      exit 1
    elsif argv.size == 1 && File.exist?(argv[0])
      lines = File.readlines(argv[0], chomp: true).reject(&:empty?)
      phonemize(lines, **options).each { |line| puts line }
    else
      puts phonemize(argv.join(' '), **options)
    end
  end
end

# Executable mode guard: only runs when this file is invoked directly.
Phonemizer.main(ARGV) if $PROGRAM_NAME == __FILE__
