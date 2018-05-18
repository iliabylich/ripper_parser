require "bundler/gem_tasks"
require 'rake/testtask'

Rake::TestTask.new do |t|
  t.ruby_opts  = ["-rpatch_helper"]
  t.libs       = %w(lib/ test/ vendor/parser/test/ vendor/parser/lib/)
  t.test_files = %w(vendor/parser/test/test_lexer.rb)# vendor/parser/test/test_parser.rb)
  t.warning    = false
end

namespace :ruby_parser do
  desc "'rake generate' in the Ruby Parser"
  task :generate do
    sh 'cd vendor/parser && rake generate'
  end

  desc "'rake clean' in the Ruby Parser"
  task :clean do
    sh 'cd vendor/parser && rake clean'
  end
end

task :clean do
  sh 'rm -rf tmp'
  sh 'cd vendor/parser && rake clean'
end

task generate: ['ruby_parser:generate']
task test: :generate
task build: :generate
task default: :test
