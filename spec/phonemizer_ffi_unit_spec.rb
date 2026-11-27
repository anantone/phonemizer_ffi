# frozen_string_literal: true

RSpec.describe Phonemizer do
  describe 'LANG_SWITCH' do
    it 'matches simple language tags' do
      expect('(fr)').to match(Phonemizer::LANG_SWITCH)
      expect('(en)').to match(Phonemizer::LANG_SWITCH)
    end

    it 'matches regional tags' do
      expect('(pt-br)').to match(Phonemizer::LANG_SWITCH)
      expect('(en-us)').to match(Phonemizer::LANG_SWITCH)
    end

    it 'does not match non-tag parentheses' do
      expect('(1)').not_to match(Phonemizer::LANG_SWITCH)
      expect('(toolongtag)').not_to match(Phonemizer::LANG_SWITCH)
    end
  end

  describe 'PUNCT' do
    it 'matches ordinary punctuation' do
      expect(',').to match(Phonemizer::PUNCT)
      expect('...').to match(Phonemizer::PUNCT)
      expect('?!').to match(Phonemizer::PUNCT)
    end

    it 'does NOT match apostrophes (they stay inside elided words)' do
      expect("'").not_to match(Phonemizer::PUNCT)
      expect('’').not_to match(Phonemizer::PUNCT)
      expect('‘').not_to match(Phonemizer::PUNCT)
    end
  end

  describe 'LibEspeak' do
    it 'uses the \x01 sentinel as inter-phone separator' do
      expect(Phonemizer::LibEspeak::SEP_CHAR).to eq("\x01")
    end

    it 'always sets the IPA bit of phonememode' do
      expect(Phonemizer::LibEspeak.phonememode('') & 0x02).to eq(0x02)
      expect(Phonemizer::LibEspeak.phonememode(' ') & 0x02).to eq(0x02)
    end

    it 'encodes the sentinel in bits 8-23 when a phone_sep is requested' do
      mode = Phonemizer::LibEspeak.phonememode(' ')
      expect((mode >> 8) & 0xFF).to eq(0x01)
    end

    it 'sets no separator bits for an empty phone_sep' do
      expect(Phonemizer::LibEspeak.phonememode('')).to eq(0x02)
    end
  end

  describe '.split_punctuation' do
    it 'splits a word with no punctuation into a single chunk' do
      expect(described_class.send(:split_punctuation, 'tableau')).to eq(['tableau'])
    end

    it 'keeps punctuation as its own chunks' do
      expect(described_class.send(:split_punctuation, 'bonjour,'))
        .to eq(['bonjour', ','])
    end

    it 'handles leading and trailing punctuation' do
      expect(described_class.send(:split_punctuation, '(go)'))
        .to eq(['(', 'go', ')'])
    end

    it 'never yields empty chunks' do
      expect(described_class.send(:split_punctuation, '...')).to eq(['...'])
    end

    it 'keeps a multi-word chunk whole so cross-word liaison can happen' do
      # A space is not punctuation: "les amis" stays one chunk, so espeak-ng
      # sees both words together and emits the liaison ("le-z amˈi").
      expect(described_class.send(:split_punctuation, 'les amis')).to eq(['les amis'])
    end
  end

  describe '.stitch' do
    # stitch takes a batch-local piece -> raw IPA map — no espeak involved.
    let(:map) { { 'bonjour' => 'bɔ̃ʒuʁ', 'comment' => 'kɔmɑ̃' } }

    def stitch_map(ipa_map, parts, **opts)
      described_class.send(:stitch, parts, ipa_map, **opts)
    end

    it 'reassembles words and punctuation in order' do
      parts = ['bonjour', ',', 'comment']
      expect(stitch_map(map, parts, phone_sep: '', word_sep: ' ',
                                    strip_stress: true, language_switch: :remove))
        .to eq('bɔ̃ʒuʁ,kɔmɑ̃')
    end

    it 'passes punctuation through verbatim' do
      parts = ['bonjour', '...']
      result = stitch_map(map, parts, phone_sep: '', word_sep: ' ',
                                      strip_stress: true, language_switch: :remove)
      expect(result).to end_with('...')
    end

    it 'strips language-switch tags when :remove' do
      parts = ['wifi']
      m = { 'wifi' => 'vi (fr) fi' }
      result = stitch_map(m, parts, phone_sep: '', word_sep: ' ',
                                    strip_stress: true, language_switch: :remove)
      expect(result).to eq('vi  fi')
    end

    it 'keeps language-switch tags when :keep' do
      parts = ['wifi']
      m = { 'wifi' => 'vi (fr) fi' }
      result = stitch_map(m, parts, phone_sep: '', word_sep: ' ',
                                    strip_stress: true, language_switch: :keep)
      expect(result).to eq('vi (fr) fi')
    end

    it 'keeps the liaison consonant and strips the liaison hyphen when strip_stress' do
      # espeak-ng emits "le-z amˈi" for "les amis": the - marks the liaison
      # (final s of "les" pronounced [z] before the vowel of "amis").
      parts = ['les amis']
      m = { 'les amis' => 'le-z amˈi' }
      result = stitch_map(m, parts, phone_sep: '', word_sep: ' ',
                                    strip_stress: true, language_switch: :remove)
      expect(result).to eq('lez ami')
    end

    it 'leaves stress marks and the liaison hyphen in place when not stripping' do
      parts = ['les amis']
      m = { 'les amis' => 'le-z amˈi' }
      result = stitch_map(m, parts, phone_sep: '', word_sep: ' ',
                                    strip_stress: false, language_switch: :remove)
      expect(result).to eq('le-z amˈi')
    end

    it 'treats a plain space as a word boundary when phone_sep is empty' do
      parts = ['les amis']
      m = { 'les amis' => 'le ami' }
      result = stitch_map(m, parts, phone_sep: '', word_sep: ' _ ',
                                    strip_stress: true, language_switch: :remove)
      expect(result).to eq('le _ ami')
    end

    it 'maps the \x01 sentinel to phone_sep and a plain space to word_sep in sep mode' do
      parts = ['les amis']
      m = { 'les amis' => "l\x01e a\x01m\x01i" }
      result = stitch_map(m, parts, phone_sep: '-', word_sep: ' ',
                                    strip_stress: true, language_switch: :remove)
      expect(result).to eq('l-e a-m-i')
    end

    it 'supports multi-character separators containing spaces without collision' do
      parts = ['les amis']
      m = { 'les amis' => "l\x01e a\x01m\x01i" }
      result = stitch_map(m, parts, phone_sep: ' | ', word_sep: ' _ ',
                                    strip_stress: true, language_switch: :remove)
      expect(result).to eq('l | e _ a | m | i')
    end

    it "keeps a '-' phone_sep in sep mode even with strip_stress" do
      # In sep mode a "-" is a user-chosen phone separator, never a liaison
      # marker, so it must survive stress stripping.
      parts = ['les amis']
      m = { 'les amis' => "le\x01z a\x01m\x01i" }
      result = stitch_map(m, parts, phone_sep: '-', word_sep: ' ',
                                    strip_stress: true, language_switch: :remove)
      expect(result).to eq('le-z a-m-i')
    end

    it 'raises instead of silently emitting an empty string for a missing mapping' do
      expect do
        stitch_map({}, ['unknown'], phone_sep: '', word_sep: ' ',
                                    strip_stress: true, language_switch: :remove)
      end.to raise_error(Phonemizer::Error, /no transcription/)
    end
  end

  describe 'input shape' do
    # Stub the batch path so we assert shape handling without espeak.
    before do
      allow(described_class).to receive(:phonemize_batch)
        .and_return(['IPA'])
    end

    it 'returns a String for String input' do
      result = described_class.phonemize('manger')
      expect(result).to be_a(String)
    end

    it 'returns an Array for Array input' do
      result = described_class.phonemize(['manger'])
      expect(result).to be_an(Array)
    end

    it 'accepts and ignores the workers option (drop-in compatibility)' do
      expect { described_class.phonemize('manger', workers: 8) }
        .not_to raise_error
    end

    it 'rejects an unknown language_switch' do
      expect { described_class.phonemize('manger', language_switch: :bogus) }
        .to raise_error(ArgumentError, /language_switch/)
    end
  end

  describe 'public API surface' do
    it 'exposes only the documented entry points' do
      %i[phonemize espeak_raw clear_cache main].each do |m|
        expect(described_class).to respond_to(m)
      end
      %i[phonemize_batch stitch transcribe_piece transcribe_pieces with_voice select_voice].each do |m|
        expect(described_class).not_to respond_to(m)
      end
    end
  end

  describe 'cache' do
    # Fake the FFI layer so the cache logic is exercised without espeak.
    let(:calls) { [] }

    before do
      allow(described_class).to receive(:select_voice)
      allow(described_class).to receive(:transcribe_piece) do |piece, _mode|
        calls << piece
        "ipa_#{piece}"
      end
    end

    it 'serves repeated pieces from the cache' do
      described_class.phonemize(%w[a b], language: 'xx')
      described_class.phonemize(%w[b a], language: 'xx')
      expect(calls).to eq(%w[a b])
    end

    it 'shares raw entries across different non-empty phone_sep values' do
      described_class.phonemize('a', language: 'xx', phone_sep: ' ')
      described_class.phonemize('a', language: 'xx', phone_sep: '|')
      expect(calls).to eq(%w[a])
    end

    it 'never blanks a batch when the cache is evicted mid-run' do
      stub_const('Phonemizer::MAX_CACHE_SIZE', 3)
      expect(described_class.phonemize(%w[a b], language: 'xx')).to eq(%w[ipa_a ipa_b])
      expect(described_class.phonemize(%w[c d], language: 'xx')).to eq(%w[ipa_c ipa_d])
    end

    it 'returns every word of a batch larger than the cache itself' do
      stub_const('Phonemizer::MAX_CACHE_SIZE', 3)
      words = %w[a b c d e f]
      expect(described_class.phonemize(words, language: 'xx')).to eq(words.map { |w| "ipa_#{w}" })
    end

    it 'never grows beyond MAX_CACHE_SIZE' do
      stub_const('Phonemizer::MAX_CACHE_SIZE', 3)
      described_class.phonemize(%w[a b], language: 'xx')
      described_class.phonemize(%w[c d e f g], language: 'xx')
      expect(Phonemizer::IPA_CACHE.size).to be <= 3
    end
  end

  describe '.clear_cache' do
    it 'is callable and empties the cache' do
      expect { described_class.clear_cache }.not_to raise_error
      expect(Phonemizer::IPA_CACHE).to be_empty
    end
  end
end
