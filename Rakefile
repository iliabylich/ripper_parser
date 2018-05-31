require "bundler/gem_tasks"
require 'rake/testtask'

Rake::TestTask.new do |t|
  t.ruby_opts  = ["-rpatch_helper", "-rminitest/excludes"]
  t.libs       = %w(lib/ test/ vendor/parser/test/ vendor/parser/lib/)
  t.test_files = %w(vendor/parser/test/test_parser.rb)
  t.warning    = false
end

namespace :ruby_parser do
  desc "'rake generate' in the Ruby Parser"
  task :generate do
    # sh 'cd vendor/parser && rake generate'
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

module Helper
  module_function

  def parse_with_ripper_parser(source)
    require 'ripper_lexer'
    parser = Parser::Ruby251WithRipperLexer.new
    buffer = Parser::Source::Buffer.new('(eval)')
    buffer.source = source
    parser.parse(buffer)
  end

  def parse_with_parser(source)
    require 'parser/ruby25'
    parser = Parser::Ruby25.new
    buffer = Parser::Source::Buffer.new('(eval)')
    buffer.source = source
    parser.parse(buffer)
  end

  def parse_with_ripper(source)
    require 'ripper'
    Ripper::SexpBuilderPP.new(source).parse
  end

  def parse_with_c_lexer(source)
    require 'c_lexer'
    parser = Parser::Ruby25WithCLexer.new
    buffer = Parser::Source::Buffer.new('(eval)')
    buffer.source = source
    parser.parse(buffer)
  end

  def each_opal_file
    opal_dir = File.expand_path('../../opal', __FILE__)
    parser_dir = File.expand_path('../vendor/parser', __FILE__)

    opal_core = Dir[opal_dir + "/opal/**/*.rb"]
    opal_stdlib = Dir[opal_dir + "/stdlib/**/*.rb"]
    parser_files = Dir[parser_dir + "/lib/**/*.rb"]

    [*opal_core, *opal_stdlib, *parser_files].each do |f|
      yield File.read(f)
    end
  end
end

task :trace do
  require 'stackprof'
  source = File.read('test.rb')

  GC.disable
  StackProf.run(mode: :cpu, out: 'trace.dump') do
    Helper.parse_with_ripper_parser(source)
  end
  sh 'stackprof trace.dump'
end

task :compare do
  source = File.read('test.rb')

  ripper_result = Helper.parse_with_ripper_parser(source)
  parser_result = Helper.parse_with_parser(source)

  puts 'Ripper:'
  pp ripper_result

  puts 'Parser:'
  p parser_result

  puts 'Same:'
  p ripper_result == parser_result
end

task :bm do
  require 'benchmark/ips'
  GC.disable
  source = File.read('test.rb')

  puts "BM: opal core + opal stdlib + whitequark/parser"

  Benchmark.ips do |x|
    x.config(time: 5, warmup: 2)

    x.report('Ruby parser') do
      Helper.each_opal_file { |source| Helper.parse_with_parser(source) }
    end

    x.report('Ripper-based parser') do
      Helper.each_opal_file { |source| Helper.parse_with_ripper_parser(source) }
    end

    x.report('Ripper') do
      Helper.each_opal_file { |source| Helper.parse_with_ripper(source) }
    end

    x.report('Ruby parser + CLexer') do
      Helper.each_opal_file { |source| Helper.parse_with_c_lexer(source) }
    end

    x.compare!
  end
end
