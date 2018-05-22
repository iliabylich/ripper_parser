require "ripper_lexer/version"
require 'ripper'
require 'ast/node'
require 'pry'
require 'ostruct'

module Parser
  class Ruby251WithRipperLexer
    attr_reader :diagnostics, :static_env

    Lexer = OpenStruct.new(cmdarg: [])

    EXPECTED_RUBY_VERSION = '2.5.1'.freeze

    def initialize(builder = Parser::Builders::Default.new)
      @diagnostics = Diagnostic::Engine.new
      @builder     = builder
      @static_env  = StaticEnvironment.new
      @lexer       = Lexer

      @builder.parser = self

      if RUBY_VERSION != EXPECTED_RUBY_VERSION
        raise "Unsupported Ruby Version (Supported is #{EXPECTED_RUBY_VERSION})"
      end
    end

    def parse(source_buffer)
      ripper_ast = Ripper.sexp(source_buffer.source)
      rewriter = RipperLexer::Rewriter.new(@builder)
      rewriter.process(ripper_ast)
    end
  end
end

module RipperLexer
  class Rewriter
    def initialize(builder)
      @builder = builder
    end

    def process(ast)
      return if ast.nil?
      node, *children = *ast
      send(:"process_#{node}", *children)
    end

    private

    def process_program(stmts, *rest)
      stmts = stmts.map { |stmt| process(stmt)  }
      if stmts.length == 1
        stmts[0]
      else
        s(:begin, *stmts)
      end
    end

    def process_void_stmt
    end

    def process_class(name, superclass, bodystmt)
      s(:class, process(name), process(superclass), process(bodystmt))
    end

    def process_const_path_ref(scope, const)
      s(:const, process(scope), process_const_name(const))
    end

    def process_const_ref(ref)
      process(ref)
    end

    def process_var_ref(ref)
      process(ref)
    end

    define_method('process_@const') do |const_name, _location|
      s(:const, nil, const_name.to_sym)
    end

    def process_const_name((_, const_name, _location))
      const_name.to_sym
    end

    def process_bodystmt(stmts, _, _, _)
      stmts = stmts.map { |stmt| process(stmt) }.compact
      if stmts.length == 1
        stmts[0]
      else
        s(:begin, *stmts)
      end
    end

    # ref = value
    def process_assign(ref, value)
      ref = process(ref)
      value = process(value)

      case ref.type
      when :const
        ref.updated(:casgn, [*ref, value])
      else
        raise "Unsupport assign type #{ref.type}"
      end
    end

    def process_var_field(field)
      process(field)
    end

    define_method('process_@int') do |value, _location|
      s(:int, value.to_i)
    end

    define_method('process_@float') do |value, _location|
      s(:float, value.to_f)
    end

    define_method('process_@rational') do |value, _location|
      s(:rational, value.to_r)
    end

    define_method('process_@imaginary') do |value, _location|
      if value.end_with?('ri')
        s(:complex, eval(value)) # TODO: rare case, but probably deserves some optimization
      else
        s(:complex, value.to_c)
      end
    end

    def process_def(mid, args, bodystmt)
      mid = process(mid)
      args = process(args)
      bodystmt = process(bodystmt)

      s(:def, mid, args, bodystmt)
    end

    define_method('process_@ident') do |name, _location|
      name.to_sym
    end

    def process_params(req, opt, rest, post, kwargs, kwrest, block)
      req = req.map { |arg| process_arg(arg) }
      opt = opt.map { |arg| process_optarg(*arg) }
      rest = process(rest)
      post = post.map { |arg| process_arg(arg) }
      kwargs = kwargs.map { |arg| process_kwarg(arg) }
      kwrest = process(kwrest)
      block = process(block)

      s(:args, *req, *opt, rest, *post, *kwargs, kwrest, block)
    end

    def process_arg(arg)
      type, *rest = *arg
      case type
      when :@ident
        s(:arg, process(arg))
      when :mlhs
        rest = rest.map { |a| process_arg(a) }
        s(:mlhs, *rest)
      when :rest_param
        process(arg)
      else
        raise "Unknown arg type #{type}"
      end
    end

    def process_optarg(name, value)
      s(:optarg, process(name), process(value))
    end

    def process_rest_param(name)
      if name
        s(:restarg, process(name))
      else
        s(:restarg)
      end
    end

    def process_kwarg(kwarg)
      name, default_value = kwarg
      name = process(name)
      if default_value == false
        s(:kwarg, name)
      else
        s(:kwoptarg, name, process(default_value))
      end
    end

    define_method('process_@label') do |value, location|
      value[0..-2].to_sym
    end

    def process_kwrest_param(name)
      if name
        s(:kwrestarg, process(name))
      else
        s(:kwrestarg)
      end
    end

    def process_blockarg(name)
      s(:blockarg, process(name))
    end

    def process_paren(inner)
      type, *children = *inner
      case type
      when :params
        process(inner)
      when [:void_stmt]
        s(:begin)
      else
        raise "Unsupported paren child #{type}"
      end
    end

    define_method('process_@kw') do |keyword, location|
      case keyword
      when 'nil'
        s(:nil)
      when 'true'
        s(:true)
      when 'false'
        s(:false)
      when '__LINE__'
        line, col = location
        s(:int, line)
      else
        raise "Unsupport keyword #{keyword}"
      end
    end

    def process_begin(bodystmt)
      bodystmt = process(bodystmt)
      if bodystmt.nil?
        s(:kwbegin)
      else
        bodystmt.updated(:kwbegin)
      end
    end

    def process_unary(sign, value)
      value = process(value)
      case sign
      when :-@
        value.updated(nil, [-value.children[0]])
      else
        raise "Unsupported unary sign #{sign}"
      end
    end

    def s(type, *children)
      @builder.send(:n, type, children, nil)
    end
  end
end
