
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "ripper_lexer/version"

Gem::Specification.new do |spec|
  spec.name          = "ripper_lexer"
  spec.version       = RipperLexer::VERSION
  spec.authors       = ["Ilya Bylich"]
  spec.email         = ["ibylich@gmail.com"]

  spec.summary       = %q{Ripper-based lexer compatible with whitequark/parser}
  spec.description   = %q{Ripper-based lexer compatible with whitequark/parser}
  spec.homepage      = "https://github.com/iliabylich/ripper_lexer"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"
  else
    raise "RubyGems 2.0 or newer is required to protect against " \
      "public gem pushes."
  end

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency             'ast',           '~> 2.4.0'
  spec.add_dependency             'parser',        '= 2.5.1.0'

  spec.add_development_dependency 'bundler',       '~> 1.16'
  spec.add_development_dependency 'rake',          '~> 10.0'
  spec.add_development_dependency 'rake-compiler', '~> 0.9'

  # Parser dev dependencies
  spec.add_development_dependency 'minitest',      '~> 5.10'
  spec.add_development_dependency 'simplecov',     '~> 0.15.1'
  spec.add_development_dependency 'racc',          '= 1.4.14'
  spec.add_development_dependency 'cliver',        '~> 0.3.2'

end
