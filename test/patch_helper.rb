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
    # MRI parses heredocs a bit differently
    # Most probably that's a bug in the Parser
    %Q{p <<~E\n\tx\n    y\nE},
    %Q{p <<~E\n\tx\n        y\nE},
    %Q{p <<~E\n    \tx\n        y\nE},
    %Q{p <<~E\n        \tx\n\ty\nE},
    %Q{p <<~E\n    x\n  \\  y\nE},
    %Q{p <<~E\n    x\n  \\\ty\nE},

    # Ripper doesn't distinguish string and symbol arrays
    %q{%i[foo bar]},
    %q{%I[foo #{bar}]},
    %q{%I[foo#{bar}]},

    # Ripper cuts unary +
    %q{+2.0 ** 10},

    # Ripper does not emit shadow args in arrow lambda
    %q{->(a; foo, bar) { }},

    # Ripper doesn't handle local assigns
    # produced by matching regexs
    %q{/(?<match>bar)/ =~ 'bar'; match},
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
    source_buffer.instance_eval { @source = "nil;" + locals_code + @source }
    ast = super
    if ast
      children = ast.children[locals.count + 1..-1]
      case children.length
      when 0
        nil
      when 1
        children[0]
      else
        @builder.send(:n, :begin, children, nil)
      end
    else
      nil
    end
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

  def with_unwrapped_begin
    if type == :begin && children.length == 1
      children[0]
    else
      self
    end
  end

  def ==(other)
    return false if other.nil?

    a = self
    b = other

    a = a.with_joined_children(:str) if a.is_a?(AST::Node) && a.type == :dstr
    a = a.with_joined_children(:xstr) if a.is_a?(AST::Node) && a.type == :xstr
    a = a.with_unwrapped_begin if a.is_a?(AST::Node) && a.type == :begin

    b = b.with_joined_children(:str) if b.is_a?(AST::Node) && b.type == :dstr
    b = b.with_joined_children(:xstr) if b.is_a?(AST::Node) && b.type == :xstr
    b = b.with_unwrapped_begin if b.is_a?(AST::Node) && b.type == :begin

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
