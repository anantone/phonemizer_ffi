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

  spec.files         = Dir['lib/**/*.rb', 'README.md', 'LICENSE', 'CHANGELOG.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'ffi', '~> 1.15'

  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rspec', '~> 3.13'
end
