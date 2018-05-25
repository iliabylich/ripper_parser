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
      rewriter = RipperLexer::Rewriter.new(
        builder: @builder,
        file: source_buffer.name
      )
      rewriter.process(ripper_ast)
    end
  end
end

module RipperLexer
  class Rewriter
    def initialize(builder:, file:)
      @builder = builder
      @file = file
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
      case ref[0]
      when :@ident
        s(:lvar, process(ref))
      when :@kw
        process(ref)
      when :@ivar
        process(ref)
      when :@cvar
        process(ref)
      when :@gvar
        process(ref)
      else
        raise "Unsupported var_ref #{ref[0]}"
      end
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
      when :lvar
        ref.updated(:lvasgn, [*ref, value])
      else
        raise "Unsupport assign type #{ref.type}"
      end
    end

    def process_var_field(field)
      s(:lvar, process(field))
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
      when '__FILE__'
        s(:str, @file)
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

    def process_string_literal(string_content)
      _, *parts = string_content
      parts = parts.map { |part| process(part) }
      interpolated = parts.any? { |part| part.type != :str }

      if interpolated
        s(:dstr, *parts)
      elsif parts.length == 1
        parts.first
      else
        s(:dstr, *parts)
      end
    end

    def process_xstring_literal(parts)
      parts = parts.map { |part| process(part) }
      interpolated = parts.any? { |part| part.type != :str }

      if interpolated
        s(:xstr, *parts)
      elsif parts.length == 1
        parts.first.updated(:xstr)
      else
        s(:xstr, *parts)
      end
    end

    def process_regexp_literal(parts, modifiers)
      parts = parts.map { |part| process(part) }
      modifiers = process(modifiers)
      s(:regexp, *parts, modifiers)
    end

    define_method('process_@regexp_end') do |value, _location|
      modifiers = value.chars[1..-1].map(&:to_sym).sort
      s(:regopt, *modifiers)
    end

    define_method('process_@tstring_content') do |value, _location|
      s(:str, value)
    end

    def process_string_embexpr((expr))
      expr = process(expr)
      if expr.type != :begin
        expr = s(:begin, expr)
      end
      expr
    end

    def process_string_dvar(value)
      process(value)
    end

    define_method('process_@ivar') do |value, _location|
      s(:ivar, value.to_sym)
    end

    define_method('process_@cvar') do |value, _location|
      s(:cvar, value.to_sym)
    end

    define_method('process_@gvar') do |value, _location|
      s(:gvar, value.to_sym)
    end

    def process_string_concat(*strings)
      strings = strings.map { |s| process(s) }
      s(:dstr, *strings)
    end

    define_method('process_@CHAR') do |value, _location|
      s(:str, value[1])
    end

    def process_method_add_arg(call, args)
      send = process(call)
      args = process(args)
      send.updated(nil, [*send, *args])
    end

    def process_call(recv, op, mid)
      s(:send, process(recv), process(mid))
    end

    def process_arg_paren(inner)
      process(inner)
    end

    def process_args_add_block(args, _)
      args.map { |a| process(a) }
    end

    def process_command(mid, args)
      mid = process(mid)
      args = process(args)
      s(:send, nil, mid, *args)
    end

    def process_command_call(recv, op, mid, args)
      recv = process(recv)
      mid = process(mid)
      args = process(args)

      s(:send, recv, mid, *args)
    end

    def process_vcall(mid)
      s(:send, nil, process(mid))
    end

    def process_symbol_literal(inner)
      s(:sym, process(inner))
    end

    def process_symbol(symbol)
      process(symbol)
    end

    def process_dyna_symbol(parts)
      parts = parts.map { |part| process(part) }.compact
      interpolated = parts.any? { |part| part.type != :str }

      if interpolated
        s(:dsym, *parts)
      elsif parts.length == 1
        part = parts.first
        part.updated(:sym, [part.children[0].to_sym])
      else
        s(:dsym, *parts)
      end
    end

    def process_array(parts)
      processed = []

      while parts.any? do
        part = parts.shift
        case part
        when :args_add_star
          pre_splat = parts.shift
          splat = parts.shift
          processed += pre_splat.map { |p| process(p) }
          processed << s(:splat, process(splat))
        else
          if part[0].is_a?(Symbol)
            processed << process(part)
          elsif part.is_a?(Array)
            if part.length == 1 && part[0][0] == :@tstring_content
              processed << process(part[0])
            else
              processed << s(:dstr, *part.map { |p| process(p) })
            end
          end
        end
      end

      s(:array, *processed)
    end

    def process_bare_assoc_hash(assocs)
      pairs = assocs.map { |assoc| process(assoc) }
      s(:hash, *pairs)
    end

    def process_hash(assoclist)
      if assoclist.nil?
        s(:hash)
      else
        s(:hash, *process(assoclist))
      end
    end

    def process_assoclist_from_args(assocs)
      assocs.map { |assoc| process(assoc) }
    end

    def process_assoc_new(key, value)
      key = process(key)
      key = s(:sym, key) if key.is_a?(Symbol) # label
      s(:pair, key, process(value))
    end

    def process_assoc_splat(value)
      s(:kwsplat, process(value))
    end

    def process_string_content
      # no-op
    end

    def process_fcall(ident)
      s(:send, nil, process(ident))
    end

    def process_ifop(cond, if_branch, else_branch)
      s(:if,
        process(cond),
        process(if_branch),
        process(else_branch))
    end

    def process_dot2(range_start, range_end)
      s(:irange, process(range_start), process(range_end))
    end

    def process_dot3(range_start, range_end)
      s(:erange, process(range_start), process(range_end))
    end

    def s(type, *children)
      @builder.send(:n, type, children, nil)
    end
  end
end
