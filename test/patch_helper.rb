require 'parser/ruby25'
require 'ripper_lexer'
require 'parse_helper'

module ParseHelper
  ALL_VERSIONS.clear
  ALL_VERSIONS << '2.5'

  def parse_source_map_descriptions(*)
    # We don't care about source maps
  end

  def assert_parses(ast, code, source_maps='', versions=ALL_VERSIONS)
    with_versions(versions) do |version, parser|
      try_parsing(ast, code, parser, source_maps, version)
    end
  end
end

module Parser
  dedenter = Lexer::Dedenter

  remove_const(:Lexer)
  Lexer = RipperLexer
  Lexer::Dedenter = dedenter

  remove_const(:Ruby25)
  Ruby25 = Ruby251WithRipperLexer
end

module ParserExt
  def parse(source_buffer)
    locals = @static_env.instance_eval { @variables.to_a }
    locals_code = locals.map { |l| "#{l} = nil; " }.join
    source_buffer.instance_eval { @source = locals_code + @source }
    super.children[locals.count]
  end
end

Parser::Ruby25.prepend(ParserExt)
