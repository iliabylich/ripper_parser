require 'ripper_lexer/version'
require 'ripper'
require 'ostruct'
require 'parser'
require 'yaml'

module Parser
  class Ruby251WithRipperLexer
    attr_reader :diagnostics, :static_env, :builder

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
      source = source_buffer.source
      ast = Ripper.sexp(source)
      tokens = Ripper.lex(source)
      rewriter = RipperLexer::Rewriter.new(
        builder: @builder,
        file: source_buffer.name,
        lines: source.lines,
        tokens: tokens
      )
      rewriter.process(ast)
    end
  end
end

module RipperLexer
  class Rewriter
    def initialize(builder:, file:, lines:, tokens:)
      @builder = builder
      @file = file
      @lines = lines
      @tokens = tokens

      filter_tokens
      build_tokens_map
    end

    def filter_tokens
      @tokens.select! do |loc, token_type, _token, _lex_state|
        token_type == :on_tstring_beg ||
          token_type == :on_heredoc_beg ||
          token_type == :on_tstring_content ||
          token_type == :on_qwords_beg ||
          token_type == :on_qsymbols_beg
      end
    end

    def build_tokens_map
      @tokens_map = @tokens.map.with_index do |(loc, _, _, _), idx|
        [loc, idx]
      end.to_h
    end

    def process(ast)
      return if ast.nil?
      node, *children = *ast
      send(:"process_#{node}", *children)
    end

    private

    def process_many(nodes)
      nodes.map { |node| process(node) }
    end

    def to_single_node(nodes)
      case nodes.length
      when 0
        nil
      when 1
        nodes[0]
      else
        s(:begin, *nodes)
      end
    end

    def process_args_sequence(nodes)
      processed = []

      while nodes && nodes.any? do
        node = nodes.shift
        case node
        when :args_add_star
          pre_splat = nodes.shift
          splat = nodes.shift
          processed += process_args_sequence(pre_splat) { |non_splat| process(non_splat) }
          processed << s(:splat, process(splat))
        else
          processed << yield(node)
        end
      end

      processed
    end

    def process_program(stmts, *rest)
      to_single_node(process_many(stmts))
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

    def process_top_const_ref(ref)
      _, const_name = *process(ref)
      s(:const, s(:cbase), const_name)
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
      when :@const
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

    def process_bodystmt(stmts, rescue_handlers, else_node, ensure_body)
      begin_body = to_single_node(process_many(stmts).compact)
      begin_body = s(:begin, begin_body) if begin_body && begin_body.type != :begin
      rescue_handlers = process(rescue_handlers)
      else_body = process(else_node)
      else_body = s(:begin, else_body) if else_body

      body = begin_body

      # Special case of
      # begin; 1; else; 2; end
      if ensure_body.nil? && rescue_handlers.nil?
        if body.nil? && else_body.nil?
          return nil
        else
          return s(:begin, *[*body, else_body].compact)
        end
      end

      if rescue_handlers.is_a?(Array)
        body = s(:rescue, body, *rescue_handlers, else_body)
      end

      if ensure_body
        ensure_body = process(ensure_body)
        ensure_stmts = []

        if body && body.type == :begin
          ensure_stmts += body.children
        else
          ensure_stmts << body
        end

        if ensure_body && ensure_body.type == :begin
          ensure_stmts += ensure_body.children
        else
          ensure_stmts << ensure_body
        end

        body = s(:ensure, *ensure_stmts)
      end

      body
    end

    def process_rescue(klasses, var, stmts, nested)
      if klasses && klasses[0].is_a?(Array)
        klasses = process_many(klasses)
      else
        klasses = process(klasses)
      end

      if klasses.is_a?(Array)
        klasses = s(:array, *klasses)
      end

      var = process(var)
      var = reader_to_writer(var) if var
      stmts = to_single_node(process_many(stmts))

      nested = process(nested)

      [s(:resbody, klasses, var, stmts), *nested]
    end

    def process_rescue_mod(bodystmt, rescue_handler)
      bodystmt = process(bodystmt)
      rescue_handler = process(rescue_handler)
      s(:rescue, bodystmt, s(:resbody, nil, nil, rescue_handler), nil)
    end

    def process_ensure(body)
      to_single_node(process_many(body).compact)
    end

    # ref = value
    def process_assign(ref, value)
      ref = process(ref)
      value = process(value)

      ref = reader_to_writer(ref)

      ref.updated(nil, [*ref, value])
    end

    def reader_to_writer(ref)
      case ref.type
      when :const
        ref.updated(:casgn)
      when :lvar
        ref.updated(:lvasgn)
      when :gvar
        ref.updated(:gvasgn)
      when :ivar
        ref.updated(:ivasgn)
      when :cvar
        ref.updated(:cvasgn)
      when :mlhs
        s(:mlhs, *ref.children.map { |child| reader_to_writer(child) })
      when :restarg
        child, _ = *ref
        if child
          s(:splat, reader_to_writer(child))
        else
          s(:splat)
        end
      when :send
        recv, mid, *args = *ref
        args ||= []
        s(:send, recv, :"#{mid}=", *args)
      when :csend
        recv, mid, *args = *ref
        args ||= []
        s(:csend, recv, :"#{mid}=", *args)
      when :index
        ref.updated(:indexasgn)
      else
        raise "Unsupport assign type #{ref.type}"
      end
    end

    def process_var_field(field)
      field = process(field)
      case field
      when Symbol
        s(:lvar, field)
      else
        field
      end
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

      case mid
      when Symbol
        # lowercased method name
      when AST::Node
        # Upcased method name
        _, mid = *mid
      end

      s(:def, mid, args, bodystmt)
    end

    def process_defs(definee, dot, mid, args, bodystmt)
      definee = process(definee)
      mid = process(mid)
      args = process(args)
      bodystmt = process(bodystmt)

      case mid
      when Symbol
        # lowercased method name
      when AST::Node
        # Upcased method name
        _, mid = *mid
      end

      s(:defs, definee, mid, args, bodystmt)
    end

    define_method('process_@ident') do |name, _location|
      name.to_sym
    end

    def process_params(req, opt, rest, post, kwargs, kwrest, block)
      args = []

      if req
        args += req.map { |arg| process_arg(arg) }
      end

      if opt
        args += opt.map { |arg| process_optarg(*arg) }
      end

      if !rest.nil? && rest != 0
        args << process(rest)
      end

      if post
        args += post.map { |arg| process_arg(arg) }
      end

      if kwargs
        args += kwargs.map { |arg| process_kwarg(arg) }
      end

      if kwrest
        args << process(kwrest)
      end

      if block
        args << process(block)
      end

      s(:args, *args)
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

    def process_paren(stmts)
      return s(:begin) unless stmts.is_a?(Array)

      if stmts[0].is_a?(Symbol)
        stmts = [process(stmts)]
      else
        stmts = process_many(stmts)
      end

      if stmts.length == 1
        stmts[0] || s(:begin)
      else
        s(:begin, *stmts.compact)
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
        if @builder.emit_file_line_as_literals
          line, _col = location
          s(:int, line)
        else
          s(:__LINE__)
        end
      when '__FILE__'
        if @builder.emit_file_line_as_literals
          s(:str, @file)
        else
          s(:__FILE__)
        end
      when 'self'
        s(:self)
      when '__ENCODING__'
        if @builder.class.emit_encoding
          s(:__ENCODING__)
        else
          s(:const, s(:const, nil, :Encoding), :UTF_8)
        end
      else
        keyword.to_sym # wtf
      end
    end

    def process_begin(bodystmt)
      bodystmt = process(bodystmt)
      if bodystmt.nil?
        s(:kwbegin)
      elsif bodystmt.type == :begin
        bodystmt.updated(:kwbegin)
      elsif bodystmt.type == :kwbegin
        bodystmt
      else
        s(:kwbegin, bodystmt)
      end
    end

    def process_unary(sign, value)
      value = process(value)
      case sign
      when :'-@'
        if %i[int float].include?(value.type)
          value.updated(nil, [-value.children[0]])
        else
          s(:send, value, :'-@')
        end
      when :'+@'
        if %i[int float].include?(value.type)
          value.updated(nil, [+value.children[0]])
        else
          s(:send, value, :'+@')
        end
      when :'~'
        if %i[int float].include?(value.type)
          value.updated(nil, [~value.children[0]])
        else
          s(:send, value, :'~')
        end
      when :'!'
        s(:send, value, :'!')
      when :not
        s(:send, value || s(:begin), :'!')
      else
        raise "Unsupported unary sign #{sign}"
      end
    end

    def _string_content_idx(line, col)
      key = [line, col]
      @tokens_map[key]
    end

    def _str_begin(string_content_idx)
      @tokens[0...string_content_idx].reverse_each.detect do |_pos, token_type, token, _lex_state|
        case token_type
        when :on_tstring_beg
          break token
        when :on_heredoc_beg
          if token.end_with?("'")
            break "'"
          else
            break '"'
          end
        else
          nil
        end
      end
    end

    def _str_end(str_begin)
      if str_begin == '"' || str_begin == "'"
        str_begin
      elsif str_begin.end_with?('[')
        ']'
      elsif str_begin.end_with?(')')
        ')'
      elsif str_begin.end_with?('{')
        '}'
      else
        raise "Unsupported str_begin #{str_begin}"
      end
    end

    def process_string_literal(string_content)
      _, *parts = string_content


      parts = parts.map do |part|
        nested = process(part)
        if nested
          case nested.type
          when :str
            escaped = nested.children[0]
            next nested unless escaped.include?("\\")
            line = nested.loc.expression.line
            col  = nested.loc.expression.col
            string_content_idx = _string_content_idx(line, col)
            str_begin = _str_begin(string_content_idx)
            str_end = _str_end(str_begin)
            str_end = _str_end(str_begin)

            begin
              if str_begin == '"'
                unescaped = (str_begin + escaped + str_end).undump
              else
                unescaped = eval(str_begin + escaped + str_end)
              end
            rescue Exception
              require 'pry'; binding.pry
            end

            nested.updated(nil, [unescaped])
          else
            nested
          end
        end
      end
      parts = parts.compact
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
      parts = process_many(parts)

      parts = parts.flat_map do |part|
        if part.type == :str
          values = part.children[0].lines
          values.map.with_index do |value, idx|
            range = DummyRange.new(value, part.loc.expression.line + idx)
            map = Parser::Source::Map::Collection.new(nil, nil, range)
            s(:str, value, map: map)
          end
        else
          part
        end
      end

      interpolated = parts.any? { |part| part.type != :str }

      if interpolated
        s(:xstr, *parts)
      else
        s(:xstr, *parts)
      end
    end

    def process_regexp_literal(parts, modifiers)
      parts = process_many(parts)
      modifiers = process(modifiers)
      s(:regexp, *parts, modifiers)
    end

    define_method('process_@regexp_end') do |value, _location|
      modifiers = value.chars[1..-1].map(&:to_sym).sort
      s(:regopt, *modifiers)
    end

    DummyRange = Struct.new(:source, :line, :col)

    define_method('process_@tstring_content') do |value, (line, col)|
      range = DummyRange.new(value, line, col)
      map = Parser::Source::Map::Collection.new(nil, nil, range)
      s(:str, value, map: map)
    end

    def process_string_embexpr((expr))
      expr = process(expr)
      if expr && expr.type != :begin
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
      strings = process_many(strings)
      s(:dstr, *strings)
    end

    define_method('process_@CHAR') do |value, _location|
      s(:str, value[1])
    end

    def process_method_add_arg(call, args)
      send = process(call)
      args = args.empty? ? s(:args) : process(args)
      send.updated(nil, [*send, *args])
    end

    def process_call(recv, dot, mid)
      recv = process(recv)
      mid = mid.is_a?(Symbol) ? mid : process(mid)
      case mid
      when Symbol
        # lowercased method name
      when ::AST::Node
        _, mid = *mid
      else
        raise "Unsupported mid #{mid}"
      end

      s(dot == :'&.' ? :csend : :send, recv, mid)
    end

    def process_arg_paren(inner)
      if inner.nil?
        nil
      elsif inner[0].is_a?(Array)
        process_many(inner)
      else
        process(inner)
      end
    end

    def process_args_add_block(parts, block)
      args = process_args_sequence(parts) { |non_splat| process(non_splat) }

      if block
        args << s(:block_pass, process(block))
      end

      args
    end

    def process_command(mid, args)
      mid = process(mid)

      case mid
      when Symbol
        # lowercased method name
      when ::AST::Node
        _, mid = *mid
      else
        raise "Unsupported mid #{mid}"
      end

      args = args[0].is_a?(Array) ? [process(args[0])] : process(args)
      s(:send, nil, mid, *args)
    end

    def process_command_call(recv, dot, mid, args)
      recv = process(recv)
      mid = process(mid)
      args = process(args)

      case mid
      when Symbol
        # lowercased method name
      when ::AST::Node
        _, mid = *mid
      else
        raise "Unsupported mid #{mid}"
      end

      s(dot == :'&.' ? :csend : :send, recv, mid, *args)
    end

    def process_vcall(mid = nil)
      return nil if mid.nil?
      s(:send, nil, process(mid))
    end

    def process_symbol_literal(inner)
      inner = process(inner)
      if inner.is_a?(AST::Node) && inner.type == :const
        _, inner = *inner
      end
      s(:sym, inner)
    end

    def process_symbol(symbol)
      process(symbol)
    end

    def process_dyna_symbol(parts)
      parts = process_many(parts).compact
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
      processed = process_args_sequence(parts) do |non_splat|
        if non_splat[0].is_a?(Symbol)
          process(non_splat)
        elsif non_splat.is_a?(Array)
          if non_splat.length == 1 && non_splat[0][0] == :@tstring_content
            process(non_splat[0])
          else
            s(:dstr, *process_many(non_splat))
          end
        end
      end

      s(:array, *processed)
    end

    def process_bare_assoc_hash(assocs)
      pairs = process_many(assocs)
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
      process_many(assocs)
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
      mid = process(ident)
      if mid.is_a?(AST::Node) && mid.type == :const
        _, mid = *mid
      end
      s(:send, nil, mid)
    end

    def process_ifop(cond, then_branch, else_branch)
      s(:if,
        process(cond),
        process(then_branch),
        process(else_branch))
    end

    def process_dot2(range_start, range_end)
      s(:irange, process(range_start), process(range_end))
    end

    def process_dot3(range_start, range_end)
      s(:erange, process(range_start), process(range_end))
    end

    define_method('process_@backref') do |value, _location|
      if match = value.match(/\$(\d+)/)
        s(:nth_ref, match[1].to_i)
      else
        s(:back_ref, value.to_sym)
      end
    end

    def process_defined(inner)
      s(:defined?, process(inner))
    end

    def process_const_path_field(scope, const)
      scope = process(scope)
      const = process(const)
      case const
      when Symbol
        # method
        s(:send, scope, const)
      when ::AST::Node
        _, const_name = *const
        s(:const, scope, const_name)
      else
        raise "Unsupported const path #{const}"
      end
    end

    def process_top_const_field(const)
      _, const_name = *process(const)
      s(:const, s(:cbase), const_name)
    end

    def process_massign(mlhs, mrhs)
      if mlhs[0] == :mlhs
        # a single top-level mlhs
        _, *mlhs = *mlhs
      end

      mlhs = s(:mlhs, *process_mlhs(*mlhs))
      mlhs = reader_to_writer(mlhs)

      mrhs = process(mrhs)

      s(:masgn, mlhs, mrhs)
    end

    def process_mlhs(*mlhs)
      mlhs = process_many(mlhs).compact
      mlhs.any? ? s(:mlhs, *mlhs) : nil
    end

    def process_mrhs_new_from_args(first, last = nil)
      process_array([*first, last])
    end

    def process_mrhs_add_star(before, rest)
      if before && !before.empty?
        before = process(before)
      else
        before = []
      end
      s(:array, *before, s(:splat, process(rest)))
    end

    def process_field(recv, dot, mid)
      recv = process(recv)
      mid = process(mid)
      case mid
      when Symbol
        # method
      when AST::Node
        _, mid = *mid
      else
        raise "Unsupported field #{mid}"
      end

      s(dot == :'&.' ? :csend : :send, recv, mid)
    end

    def process_aref(recv, args)
      recv = process(recv)
      if args.nil?
        args = []
      elsif args[0].is_a?(Array)
        args = process_many(args)
      else
        args = process(args)
      end

      if @builder.class.emit_index
        s(:index, recv, *args)
      else
        s(:send, recv, :[], *args)
      end
    end

    def process_aref_field(recv, args)
      recv = process(recv)
      args = process(args)
      if @builder.class.emit_index
        s(:index, recv, *args)
      else
        s(:send, recv, :[], *args)
      end
    end

    def process_opassign(recv, op, arg)
      recv = process(recv)
      if recv.type != :send && recv.type != :csend
        recv = reader_to_writer(recv)
      end
      op = process(op)
      arg = process(arg)
      case op
      when '||='
        s(:or_asgn, recv, arg)
      when '&&='
        s(:and_asgn, recv, arg)
      else
        s(:op_asgn, recv, op[0].to_sym, arg)
      end
    end

    define_method('process_@op') do |value, _location|
      value
    end

    def process_module(const_name, bodystmt)
      s(:module, process(const_name), process(bodystmt))
    end

    def process_sclass(sclass_of, bodystmt)
      s(:sclass, process(sclass_of), process(bodystmt))
    end

    def process_undef(mids)
      mids = process_many(mids)
      s(:undef, *mids)
    end

    def process_alias(old_id, new_id)
      s(:alias, process(old_id), process(new_id))
    end

    def process_var_alias(old_id, new_id)
      s(:alias, process(old_id), process(new_id))
    end

    def process_method_add_block(method_call, block)
      method_call = process(method_call)
      block = process(block)
      block.updated(nil, [method_call, *block])
    end

    def process_brace_block(args, stmts)
      invisible_rest = args && args[1] && args[1][3] && args[1][3] == 0
      args = process(args) || s(:args)

      if args.children.length == 1 && args.children[0].type == :arg && !invisible_rest && @builder.class.emit_procarg0
        args = s(:args, args.children[0].updated(:procarg0))
      end

      body = to_single_node(process_many(stmts))

      s(:block, args, body)
    end

    def process_do_block(args, stmt)
      invisible_rest = args && args[1] && args[1][3] && args[1][3] == 0
      args = process(args) || s(:args)

      if args.children.length == 1 && args.children[0].type == :arg && !invisible_rest && @builder.class.emit_procarg0
        args = s(:args, args.children[0].updated(:procarg0))
      end

      stmt = process(stmt)
      s(:block, args, stmt)
    end

    def process_block_var(args, shadow_args)
      args = process(args)
      shadow_args = shadow_args ? shadow_args.map { |arg| s(:shadowarg, process(arg)) } : []
      args.updated(nil, [*args, *shadow_args])
    end

    def process_binary(lhs, op, rhs)
      lhs = process(lhs)
      rhs = process(rhs)

      case op
      when :and, :'&&'
        s(:and, lhs, rhs)
      when :or, :'||'
        s(:or, lhs, rhs)
      else
        s(:send, lhs, op, rhs)
      end
    end

    def process_lambda(args, stmts)
      args = process(args) || s(:args)
      stmts = process_many(stmts)
      body = case stmts.length
      when 0
        nil
      when 1
        stmts[0]
      else
        s(:begin, *stmts.compact)
      end

      lambda_call = @builder.class.emit_lambda ? s(:lambda) : s(:send, nil, :lambda)

      s(:block, lambda_call, args, body)
    end

    def process_super(args)
      s(:super, *process(args))
    end

    def process_zsuper
      s(:zsuper)
    end

    def process_yield(args)
      s(:yield, *process(args))
    end

    def process_yield0
      s(:yield)
    end

    def process_if(cond, then_branch, else_branch)
      then_branch = s(:begin, *process_many(then_branch).compact)
      else_branch = process(else_branch) if else_branch
      s(:if, process(cond), then_branch, else_branch)
    end

    def process_if_mod(cond, then_branch)
      s(:if, process(cond), process(then_branch), nil)
    end

    def process_else(stmts)
      to_single_node(process_many(stmts).compact)
    end

    def process_elsif(cond, then_branch, else_branch)
      process_if(cond, then_branch, else_branch)
    end

    def process_unless(cond, then_branch, else_branch)
      then_branch = s(:begin, *process_many(then_branch))
      else_branch = process(else_branch) if else_branch
      s(:if, process(cond), else_branch, then_branch)
    end

    def process_unless_mod(cond, then_branch)
      s(:if, process(cond), nil, process(then_branch))
    end

    def process_case(cond, whens_tree)
      whens = []

      while whens_tree do
        whens << whens_tree.shift(3)
        whens_tree = whens_tree[0]
      end

      if whens.last[0] != :else
        whens << [:else, []]
      end

      s(:case, process(cond), *process_many(whens))
    end

    def process_when(conds, stmts)
      conds = process_args_sequence(conds) { |non_splat| process(non_splat) }
      stmt = to_single_node(process_many(stmts))
      s(:when, *conds, stmt)
    end

    def process_while(cond, stmts)
      s(:while, process(cond), to_single_node(process_many(stmts)))
    end

    def process_while_mod(cond, stmt)
      stmt = process(stmt)
      while_type = stmt.type == :kwbegin ? :while_post : :while
      s(while_type, process(cond), stmt)
    end

    def process_until(cond, stmts)
      s(:until, process(cond), to_single_node(process_many(stmts)))
    end

    def process_until_mod(cond, stmt)
      stmt = process(stmt)
      until_type = stmt.type == :kwbegin ? :until_post : :until
      s(until_type, process(cond), stmt)
    end

    def process_for(vars, in_var, stmts)
      if vars[0].is_a?(Array)
        vars = s(:mlhs, *process_many(vars))
      else
        vars = process(vars)
      end

      in_var = process(in_var)
      stmts = to_single_node(process_many(stmts).compact)

      s(:for, reader_to_writer(vars), in_var, stmts)
    end

    def process_break(args)
      if args.nil? || args.empty?
        args = []
      elsif args[0].is_a?(Array)
        args = process_many(args)
      else
        args = process(args)
      end
      s(:break, *args)
    end

    def process_return(value)
      if value[0].is_a?(Array)
        value = to_single_node(process_many(value))
      else
        value = s(:begin, *process(value))
      end

      s(:return, value)
    end

    def process_return0
      s(:return)
    end

    def process_next(value)
      if value.empty?
        s(:next)
      elsif value[0].is_a?(Array)
        s(:next, to_single_node(process_many(value)))
      else
        s(:next, s(:begin, *process(value)))
      end
    end

    def process_redo
      s(:redo)
    end

    def process_retry
      s(:retry)
    end

    def process_BEGIN(stmts)
      s(:preexe, *process_many(stmts))
    end

    def process_END(stmts)
      s(:postexe, *process_many(stmts))
    end

    def s(type, *children, map: nil)
      @builder.send(:n, type, children, map)
    end
  end
end
