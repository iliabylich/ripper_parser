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

    # Ripper is ... weird,
    # MRI cuts newlines, but ripper doesn't
    %Q{<<~E\n    1 \\\n    2\n    3\nE\n},
    %Q{<<-E\n    1 \\\n    2\n    3\nE\n},
    %Q{p <<~"E"\n  x\\n   y\nE},

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

    # flipsflops, who cares
    %q{if foo..bar; end},
    %q{!(foo..bar)},
    %q{if foo...bar; end},
    %q{!(foo...bar)},

    # match_current_line constructions, maybe can be fixed
    # without doing scary things on the AST level
    # But so far it's not worth it.
    # All such cases are getting parsed as simple regexps.
    %q{if /wat/; end},
    %q{!/wat/},
    %q{/\xa8/n =~ ""},

    # FIXME
    %q{break fun foo do end},
    %q{return fun foo do end},
    %q{next fun foo do end},

    # This syntax was accidentally backported to 2.5 parser.
    # MRI has it only in 2.6, so ideally it should be removed after
    # migrating to 2.6.stable:

    # Lambda do rescue end
    %q{-> do rescue; end},

    # Class definition in while cond
    %q{while class Foo; tap do end; end; break; end},
    %q{while class Foo a = tap do end; end; break; end},
    %q{while class << self; tap do end; end; break; end},
    %q{while class << self; a = tap do end; end; break; end},

    # Method definition in while cond
    %q{while def foo; tap do end; end; break; end},
    %q{while def self.foo; tap do end; end; break; end},
    %q{while def foo a = tap do end; end; break; end},
    %q{while def self.foo a = tap do end; end; break; end}
  ]


  def assert_parses(ast, code, source_maps='', versions=ALL_VERSIONS)
    return if EXCLUDES.include?(code)

    with_versions(versions) do |version, parser|
      try_parsing(ast, code, parser, source_maps, version)
    end
  end

  def assert_diagnoses(*)
    # we can't emit diagnostics
  end

  def assert_diagnoses_many(*)
    # we can't emit diagnostics
  end

  def assert_context(*)
    # there's no exposable context in the Ripper
  end

  def assert_equal(expected, actual, message = 'expected to be equal')
    if expected.is_a?(AST::Node)
      expected = AstMinimizer.instance.process(expected)
    end

    if expected.nil?
      # s(:begin) -> nil
      assert_nil actual, message
    else
      super(actual, expected, message)
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
    locals = @static_env.instance_eval { @variables.to_a }.map { |l| "#{l} = nil" }.join('; ')
    source_buffer.instance_eval { @source = "nil; begin; #{locals}; end; #{@source}" }
    ast = super
    ast = ast ? Parser::AST::Node.new(:begin, ast.children[2..-1]) : nil
    AstMinimizer.instance.process(ast)
  end
end

Parser::Ruby25.prepend(ParserExt)

class AstMinimizer < Parser::AST::Processor
  JOIN_STR_NODES = ->(nodes) { nodes.map { |node| node.children[0] }.join }

  def on_dstr(node)
    node = super
    children = node.children

    if children.empty? || children.all?(&:nil?)
      process node.updated(:str, [])
    elsif children.all? { |c| c.is_a?(AST::Node) && c.type == :str }
      process node.updated(:str, [JOIN_STR_NODES.call(children)])
    else
      node
    end
  end

  def on_str(node)
    if node.children == ['']
      node.updated(nil, [])
    else
      node
    end
  end

  def on_xstr(node)
    node = super
    children = node.children

    children = children.select do |child|
      if child.type == :str && child.children == []
        nil
      else
        child
      end
    end

    if children.all? { |c| c.is_a?(AST::Node) && c.type == :str }
      content = JOIN_STR_NODES.call(children)
      str = Parser::AST::Node.new(:str, [content])
      node.updated(nil, [str])
    else
      node.updated(nil, children)
    end
  end

  def on_begin(node)
    node = super

    case node.children.length
    when 0
      nil
    when 1
      process(node.children[0])
    else
      node
    end
  end

  def on_kwbegin(node)
    node = on_begin(node)
    node = node.updated(:begin) if node && node.type == :kwbegin
    node
  end

  # We need to have this handlers
  # to support custom 'process' method
  # that allows rewriting nodes to nil
  def on_float(node); node; end
  def on_self(node); node; end
  def on_complex(node); node; end
  def on_int(node); node; end
  def on_sym(node); node; end
  def on_rational(node); node; end
  def on_true(node); node; end
  def on_false(node); node; end
  def on___ENCODING__(node); node; end
  def on_zsuper(node); node; end
  def on_nil(node); node; end
  def on___FILE__(node); node; end
  def on___LINE__(node); node; end
  def on_cbase(node); node; end
  def on_regopt(node); node; end

  # Patched version that allows rewriting
  # nodes to nils.
  def process(node)
    return if node.nil?
    node = node.to_ast
    on_handler = :"on_#{node.type}"
    send on_handler, node
  end

  class << self
    def instance
      @instance ||= new
    end
  end
end
