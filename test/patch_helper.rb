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
      expected = DstrRewriter.new.process(expected)
    end

    super(actual, expected, message)
  end
end

module Parser
  remove_const(:Ruby25)
  Ruby25 = Ruby251WithRipperLexer
end

class DstrRewriter < Parser::AST::Processor
  # That's the only incostistence in the AST format
  # that most probably can't be easily fixed.
  #
  # The following heredoc:
  # <<-HERE
  # HERE
  #
  # gets parsed as
  # - s(:dstr) by the Parser
  # - s(:str, '') by the RipperParser
  def on_dstr(node)
    if node.children.length == 0
      node.updated(:str, [''])
    end
  end
end

module ParserExt
  def parse(source_buffer)
    locals = @static_env.instance_eval { @variables.to_a }.map { |l| "#{l} = nil" }.join('; ')
    source_buffer.instance_eval { @source = "nil; begin; #{locals}; end; #{@source}" }
    ast = super

    if ast
      nodes = ast.children[2..-1]
      case nodes.length
      when 0
        nil
      when 1
        nodes[0]
      else
        Parser::AST::Node.new(:begin, nodes)
      end
    else
      nil
    end
  end
end

Parser::Ruby25.prepend(ParserExt)
