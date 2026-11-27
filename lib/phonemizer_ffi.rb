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
# calls into it, and every access to the transcription cache, are
# serialized through a process-wide mutex. It is safe to call Phonemizer
# from multiple threads, but transcriptions will be serialized.
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
#   (multi-character, spaces, "-") can be substituted on the output in a
#   single pass without collision risk; espeak_raw, on the other hand,
#   passes single-byte separators through as-is, like --sep.
#
#   Known parity gap with the phonemizer gem in sep mode: around a liaison
#   hyphen, the CLI's --sep output can space a word boundary twice where
#   this backend spaces it once. Contiguous mode (phone_sep: "") is
#   byte-identical.
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

  # Transcription cache keyed on [piece, language, phonememode] -> raw IPA.
  # This is the expensive part (the FFI call). Post-processing (stress
  # stripping, separator substitution, language-switch removal) is cheap
  # string work and is NOT cached — so the hit rate is maximized across
  # calls that differ only in formatting options (any non-empty phone_sep
  # shares the same raw entries, since espeak always gets the sentinel).
  #
  # Bounded: it never holds more than MAX_CACHE_SIZE entries. When a batch
  # would overflow it, it is wiped wholesale first. Results are always
  # returned from a batch-local map, never re-read from the cache, so an
  # eviction can never blank out a batch's output.
  #
  # Only ever accessed with ESPEAK_LOCK held.
  IPA_CACHE = {} # rubocop:disable Style/MutableConstant
  MAX_CACHE_SIZE = 50_000

  # Safety cap for the clause-draining loop. A healthy call returns 1-2
  # clauses; anything above this indicates a bug in the C library or input.
  MAX_CLAUSES = 1000

  # Serializes every call into libespeak-ng (global voice state, init) and
  # every read or write of IPA_CACHE.
  ESPEAK_LOCK = Mutex.new

  LANGUAGE_SWITCH_MODES = %i[remove keep].freeze

  # ---------------------------------------------------------------- FFI

  # Bindings for libespeak-ng (espeak_Initialize, espeak_TextToPhonemes, …).
  module LibEspeak
    extend FFI::Library

    LIBRARY_CANDIDATES = [
      ENV.fetch('PHONEMIZER_ESPEAK_LIB', nil),
      'libespeak-ng.so.1', 'libespeak-ng.so',
      'libespeak-ng.1.dylib', 'libespeak-ng.dylib',
      # Homebrew (keg-only or linked), Apple Silicon then Intel prefixes
      '/opt/homebrew/opt/espeak-ng/lib/libespeak-ng.dylib',
      '/opt/homebrew/lib/libespeak-ng.dylib',
      '/usr/local/opt/espeak-ng/lib/libespeak-ng.dylib',
      '/usr/local/lib/libespeak-ng.dylib'
    ].compact.freeze

    begin
      ffi_lib LIBRARY_CANDIDATES
    rescue LoadError => e
      raise LoadError,
            "phonemizer_ffi: could not load libespeak-ng (#{e.message}). " \
            'Install it (apt install libespeak-ng-dev / brew install espeak-ng) ' \
            'or set PHONEMIZER_ESPEAK_LIB to the full path of the shared library.'
    end

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
  #
  # Raises ArgumentError for an unknown language_switch, Phonemizer::Error
  # when espeak-ng fails (e.g. unknown voice).
  def phonemize(words, language: DEFAULT_LANGUAGE, phone_sep: '',
                word_sep: ' ', strip_stress: true, language_switch: :remove,
                workers: nil) # rubocop:disable Lint/UnusedMethodArgument
    validate_language_switch!(language_switch)
    phone_sep = phone_sep.to_s
    word_sep = word_sep.to_s

    if words.is_a?(Array)
      phonemize_batch(words, language:, phone_sep:, word_sep:,
                             strip_stress:, language_switch:)
    else
      phonemize_batch([words], language:, phone_sep:, word_sep:,
                               strip_stress:, language_switch:).first
    end
  end

  # Clears the process-wide transcription cache. Returns nil.
  def clear_cache
    ESPEAK_LOCK.synchronize { IPA_CACHE.clear }
    nil
  end

  # CLI-wrapper compatibility: raw transcription of one utterance. Returns
  # the raw IPA (stress marks, liaison hyphens and language tags intact).
  # Deliberately bypasses IPA_CACHE: raw output is for diagnostics, and
  # caching it would double the memory footprint for rarely-repeated calls.
  def espeak_raw(text, language, phone_sep: nil)
    sep = phone_sep.to_s

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

  # Phonemizes a whole batch: split punctuation out of every unique word,
  # transcribe every unique clean piece once (cache-backed), then stitch
  # each word back together from a batch-local piece -> IPA map.
  def phonemize_batch(words, language:, phone_sep:, word_sep:,
                      strip_stress:, language_switch:)
    words = words.map(&:to_s)
    chunks_by_word = words.uniq.to_h { |w| [w, split_punctuation(w)] }
    pieces = chunks_by_word.values.flatten.uniq.grep_v(PUNCT)
    ipa_map = transcribe_pieces(pieces, language, LibEspeak.phonememode(phone_sep))

    words.map do |w|
      stitch(chunks_by_word[w], ipa_map, phone_sep:, word_sep:,
                                         strip_stress:, language_switch:)
    end
  end

  # ---------------------------------------------------------------- internals

  # pieces -> { piece => raw IPA }. Cache hits are served from IPA_CACHE,
  # misses go through a single voice selection and one FFI call each. The
  # returned map is batch-local, so evicting the shared cache cannot lose
  # anything this batch needs.
  def transcribe_pieces(pieces, language, mode)
    ESPEAK_LOCK.synchronize do
      ipa_map = {}
      pending = []
      pieces.each do |piece|
        key = [piece, language, mode]
        IPA_CACHE.key?(key) ? ipa_map[piece] = IPA_CACHE[key] : pending << piece
      end

      unless pending.empty?
        select_voice(language)
        IPA_CACHE.clear if IPA_CACHE.size + pending.size > MAX_CACHE_SIZE
        pending.each do |piece|
          ipa = transcribe_piece(piece, mode)
          ipa_map[piece] = ipa
          IPA_CACHE[[piece, language, mode]] = ipa if IPA_CACHE.size < MAX_CACHE_SIZE
        end
      end

      ipa_map
    end
  end

  # utterance -> [word, punct, word, punct, ...]
  def split_punctuation(word)
    word.split(PUNCT).reject(&:empty?)
  end

  # Reassemble one utterance from its pre-split chunks, using ipa_map
  # (piece -> raw IPA) for the non-punctuation chunks.
  def stitch(parts, ipa_map, phone_sep:, word_sep:, strip_stress:,
             language_switch:)
    parts.map do |part|
      next part if PUNCT.match?(part)

      raw = ipa_map.fetch(part) { raise Error, "internal: no transcription for #{part.inspect}" }
      post_process(raw, phone_sep:, word_sep:, strip_stress:, language_switch:)
    end.join
  end

  # Applies all formatting transformations to a raw IPA string.
  def post_process(ipa, phone_sep:, word_sep:, strip_stress:, language_switch:)
    ipa = ipa.gsub(LANG_SWITCH, '') if language_switch == :remove

    if strip_stress
      ipa = ipa.delete('ˈˌ')
      # Liaison hyphens only appear in contiguous mode (no phone_sep).
      # In sep mode the user's phone_sep might legitimately be "-",
      # so we must not delete hyphens there.
      ipa = ipa.delete('-') if phone_sep.empty?
    end

    substitute_separators(ipa, phone_sep:, word_sep:)
  end

  # Replaces the sentinel (\x01) and word-boundary spaces with user separators.
  # Single-pass gsub so phone_sep and word_sep can contain any characters
  # (including spaces or the other separator) without collision.
  def substitute_separators(ipa, phone_sep:, word_sep:)
    if phone_sep.empty?
      # Contiguous mode: a plain space is a word boundary
      ipa.gsub(' ', word_sep)
    else
      # Sep mode: \x01 = phone boundary, space = word boundary
      ipa.gsub(/[\x01 ]/) do |ch|
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
  # Must be called with ESPEAK_LOCK held: espeak keeps the selected voice in
  # global state, so two threads picking different voices would corrupt
  # each other's output.
  def select_voice(language)
    language = language.to_s
    LibEspeak.init!
    rc = LibEspeak.espeak_SetVoiceByName(language)
    if rc != LibEspeak::EE_OK
      lang = FFI::MemoryPointer.from_string(language)
      spec = LibEspeak::Voice.new
      spec[:languages] = lang
      rc = LibEspeak.espeak_SetVoiceByProperties(spec)
    end
    raise Error, "espeak-ng: cannot select voice #{language.inspect}" unless rc == LibEspeak::EE_OK
  end

  # Takes ESPEAK_LOCK, selects the voice, and yields.
  def with_voice(language)
    ESPEAK_LOCK.synchronize do
      select_voice(language)
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

  def validate_language_switch!(language_switch)
    return if LANGUAGE_SWITCH_MODES.include?(language_switch)

    raise ArgumentError,
          "language_switch must be :remove or :keep, got #{language_switch.inspect}"
  end

  # ---------------------------------------------------------------- CLI

  # Command-line entry point used by the phonemize_ffi executable.
  # Input, in order of precedence: --file PATH; a single argument naming an
  # existing regular file; text arguments (joined as one utterance); stdin
  # (one utterance per line) when it is not a TTY. Errors are reported on
  # stderr with exit status 1, without a backtrace.
  def main(argv = ARGV)
    options = {
      language: DEFAULT_LANGUAGE,
      phone_sep: '',
      word_sep: ' ',
      strip_stress: true,
      language_switch: :remove
    }
    file = nil
    parser = cli_parser(options) { |path| file = path }
    parser.parse!(argv)

    if file
      cli_batch(File.read(file, encoding: Encoding::UTF_8), options)
    elsif argv.empty? && !$stdin.tty?
      cli_batch($stdin.read, options)
    elsif argv.empty?
      warn parser
      exit 1
    elsif argv.size == 1 && File.file?(argv[0])
      cli_batch(File.read(argv[0], encoding: Encoding::UTF_8), options)
    else
      puts phonemize(argv.join(' '), **options)
    end
  rescue OptionParser::ParseError, Error, SystemCallError => e
    warn "#{File.basename($PROGRAM_NAME)}: #{e.message}"
    exit 1
  end

  # Phonemizes text line by line (blank lines skipped, lines stripped).
  def cli_batch(text, options)
    lines = text.lines.map(&:strip).reject(&:empty?)
    phonemize(lines, **options).each { |line| puts line } unless lines.empty?
  end

  def cli_parser(options, &on_file)
    require 'optparse'

    OptionParser.new do |o|
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
      o.on('-f', '--file PATH', 'phonemize PATH line by line', &on_file)
      o.on('-v', '--version', 'show version') do
        puts VERSION
        exit
      end
      o.on('-h', '--help', 'show this help') do
        puts o
        exit
      end
    end
  end

  # Internals: callable from inside the module, not part of the public API.
  private_class_method :phonemize_batch, :transcribe_pieces, :split_punctuation,
                       :stitch, :post_process, :substitute_separators,
                       :select_voice, :with_voice, :transcribe_piece,
                       :validate_language_switch!, :cli_batch, :cli_parser
end

# Executable mode guard: only runs when this file is invoked directly.
Phonemizer.main(ARGV) if $PROGRAM_NAME == __FILE__
