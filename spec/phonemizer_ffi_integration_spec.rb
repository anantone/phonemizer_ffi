# frozen_string_literal: true

require 'open3'
require 'rbconfig'

RSpec.describe 'Phonemizer FFI integration', skip: !ffi_backend_available? &&
                                                   'libespeak-ng not loadable in-process' do
  describe '.espeak_raw' do
    it 'returns non-empty IPA for a known word' do
      out = Phonemizer.espeak_raw('manger', 'fr-fr')
      expect(out.strip).not_to be_empty
    end

    it 'raises when the voice cannot be selected' do
      expect do
        Phonemizer.espeak_raw('test', 'xx-xx')
      end.to raise_error(/cannot select voice/)
    end

    it 'matches the espeak-ng CLI output byte for byte (contiguous mode)', skip: !espeak_available? &&
                                                                                 'espeak-ng not installed on PATH' do
      cli, _err, _st = Open3.capture3('espeak-ng', '-q', '--ipa', '-v', 'fr-fr',
                                      '--stdin', stdin_data: "les amis\n")
      ffi = Phonemizer.espeak_raw('les amis', 'fr-fr')
      expect(ffi.strip).to eq(cli.strip)
    end

    it 'passes a single-byte phone_sep through like the CLI --sep', skip: !espeak_available? &&
                                                                         'espeak-ng not installed on PATH' do
      cli, _err, _st = Open3.capture3('espeak-ng', '-q', '--ipa', '-v', 'fr-fr',
                                      '--sep= ', '--stdin', stdin_data: "tableau\n")
      ffi = Phonemizer.espeak_raw('tableau', 'fr-fr', phone_sep: ' ')
      expect(ffi.strip).to eq(cli.strip)
    end
  end

  describe '.phonemize' do
    it 'phonemizes a single French word' do
      result = Phonemizer.phonemize('manger', language: 'fr-fr')
      expect(result).to be_a(String)
      expect(result).to eq('mɑ̃ʒe')
    end

    it 'preserves input order and length for a batch' do
      words = %w[docteur tableau pastille]
      batch = Phonemizer.phonemize(words, language: 'fr-fr')

      expect(batch).to be_an(Array)
      expect(batch.length).to eq(words.length)

      # Each batched element must match the standalone phonemization of the
      # word at the same index — this is what actually pins the order.
      batch.each_with_index do |ipa, i|
        expect(ipa).to eq(Phonemizer.phonemize(words[i], language: 'fr-fr'))
      end
    end

    it 'preserves punctuation verbatim' do
      result = Phonemizer.phonemize('bonjour, salut', language: 'fr-fr')
      expect(result).to include(',')
    end

    it 'keeps apostrophes inside the word (no split, liaison preserved)' do
      result = Phonemizer.phonemize("aujourd'hui", language: 'fr-fr')
      # one continuous phonemized token, no space where the apostrophe was
      expect(result).not_to include(' ')
    end

    it 'performs the liaison in a multi-word utterance (les amis)' do
      # espeak-ng emits "le-z amˈi": the final s of "les" is pronounced [z]
      # before the vowel of "amis". The liaison consonant must survive;
      # only the "-" marker (and stress) may be stripped.
      result = Phonemizer.phonemize('les amis', language: 'fr-fr')
      expect(result).to include('z')     # liaison consonant pronounced
      expect(result).not_to include('-') # liaison hyphen stripped (contiguous mode)
    end

    it 'does not liaison across separate batch elements (per-piece isolation)' do
      # Each array element is its own espeak call, so "les" alone has no
      # following vowel and its final s stays silent: no liaison by design.
      batch = Phonemizer.phonemize(%w[les amis], language: 'fr-fr')
      expect(batch.length).to eq(2)
      expect(batch.join).not_to include('z')
    end

    it 'inserts phone_sep between phones when requested' do
      result = Phonemizer.phonemize('tableau', language: 'fr-fr',
                                               phone_sep: '.')
      expect(result).to include('.')
      expect(result).not_to include(' ')
    end

    it "keeps a '-' separator when strip_stress is off" do
      result = Phonemizer.phonemize('tableau', language: 'fr-fr',
                                               phone_sep: '-',
                                               strip_stress: false)
      expect(result).to include('-')
    end

    it 'strips stress marks by default' do
      result = Phonemizer.phonemize('tableau', language: 'fr-fr')
      expect(result).not_to include('ˈ')
      expect(result).not_to include('ˌ')
    end
  end

  describe 'caching' do
    it 'returns identical output on repeated calls' do
      first  = Phonemizer.phonemize('manger', language: 'fr-fr')
      second = Phonemizer.phonemize('manger', language: 'fr-fr')
      expect(second).to eq(first)
    end

    it 'recomputes correctly after clear_cache' do
      before = Phonemizer.phonemize('manger', language: 'fr-fr')
      Phonemizer.clear_cache
      after = Phonemizer.phonemize('manger', language: 'fr-fr')
      expect(after).to eq(before)
    end
  end

  describe 'phonemize_ffi executable' do
    let(:bin) { File.expand_path('../bin/phonemize_ffi', __dir__) }

    it 'phonemizes a text argument' do
      out = `#{RbConfig.ruby} #{bin} -l fr-fr "les amis"`.strip
      expect(out).to include('z')
      expect(out).not_to include('-')
    end

    it 'phonemizes stdin line by line in batch mode' do
      out, _err, _st = Open3.capture3(RbConfig.ruby, bin, '-l', 'fr-fr',
                                      stdin_data: "manger\ntableau\n")
      expect(out.lines.map(&:strip)).to eq(%w[mɑ̃ʒe tablo])
    end

    it 'phonemizes a file line by line' do
      require 'tempfile'
      Tempfile.create(%w[words .txt]) do |f|
        f.write("manger\ntableau\n")
        f.flush
        out = `#{RbConfig.ruby} #{bin} -l fr-fr #{f.path}`.strip
        expect(out.lines.map(&:strip)).to eq(%w[mɑ̃ʒe tablo])
      end
    end
  end
end
