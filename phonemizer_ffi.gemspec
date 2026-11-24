# frozen_string_literal: true

require_relative 'lib/phonemizer_ffi/version'

Gem::Specification.new do |spec|
  spec.name          = 'phonemizer_ffi'
  spec.version       = Phonemizer::VERSION
  spec.executables   = ["phonemize_ffi"]
  spec.bindir        = 'bin'
  spec.authors       = 'anantone'
  spec.email         = 'self@anantone.me'

  spec.summary       = 'In-process espeak-ng phonemization via FFI (libespeak-ng)'
  spec.description   = 'A drop-in, API-compatible replacement for the phonemizer ' \
                       'gem: same Phonemizer.phonemize API and output, but calling ' \
                       'libespeak-ng directly in-process via FFI instead of ' \
                       'fork+exec-ing the espeak-ng CLI per word — an order of ' \
                       'magnitude faster on large batches, with caching.'
  spec.homepage      = 'https://github.com/anantone/phonemizer_ffi'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  # Metadata read notably by rubydoc.info (which builds the docs with YARD
  # from the source repo) and by rubygems.org.
  spec.metadata      = {
    'source_code_uri'   => 'https://github.com/anantone/phonemizer_ffi',
    'changelog_uri'     => 'https://github.com/anantone/phonemizer_ffi/blob/main/CHANGELOG.md',
    'bug_tracker_uri'   => 'https://github.com/anantone/phonemizer_ffi/issues',
    'documentation_uri' => 'https://rubydoc.info/gems/phonemizer_ffi'
  }

  spec.files         = Dir['lib/**/*.rb', 'README.md', 'LICENSE', 'CHANGELOG.md', '.yardopts']
  spec.require_paths = ['lib']

  spec.add_dependency 'ffi', '~> 1.15'

  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rspec', '~> 3.13'
  spec.add_development_dependency 'rdoc'
  spec.add_development_dependency 'yard'
  spec.add_development_dependency 'kramdown' # YARD markdown provider
end
