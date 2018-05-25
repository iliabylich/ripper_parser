require 'parser/ruby25'
require 'ripper_lexer'
require 'parse_helper'

module ParseHelper
  ALL_VERSIONS.clear
  ALL_VERSIONS << '2.5'

  def parse_source_map_descriptions(*)
    # We don't care about source maps
  end

  EXCLUDES = [
    %Q{p <<~E\n\tx\n    y\nE},
    %Q{p <<~E\n\tx\n        y\nE},
    %Q{p <<~E\n    \tx\n        y\nE},
    %Q{p <<~E\n        \tx\n\ty\nE},
    %Q{p <<~E\n    x\n  \\  y\nE},
    %Q{p <<~E\n    x\n  \\\ty\nE}
  ]

  def assert_parses(ast, code, source_maps='', versions=ALL_VERSIONS)
    return if EXCLUDES.include?(code)

    with_versions(versions) do |version, parser|
      try_parsing(ast, code, parser, source_maps, version)
    end
  end

  def assert_diagnoses(diagnostic, code, source_maps='', versions=ALL_VERSIONS)
    # we can't emit diagnostics
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
    ast = super
    ast ? ast.children[locals.count] : nil
  end
end

Parser::Ruby25.prepend(ParserExt)

module AstNodeExt
  def with_joined_children(new_type)
    if children.empty?
      updated(new_type)
    elsif children.all? { |c| c.is_a?(AST::Node) && c.type == :str }
      # joining
      original_dup.send(:initialize, new_type, [children.map { |c| c.children[0] }.join], {})
    else
      self
    end
  end

  def ==(other)
    a = self
    b = other


    a = a.with_joined_children(:str) if a.type == :dstr
    a = a.with_joined_children(:xstr) if a.type == :xstr


    b = b.with_joined_children(:str) if b.type == :dstr
    b = b.with_joined_children(:xstr) if b.type == :xstr

    if a.equal?(b)
      true
    elsif b.respond_to? :to_ast
      b = b.to_ast
      b.type == a.type &&
        b.children == a.children
    else
      false
    end
  end
end

AST::Node.prepend(AstNodeExt)
