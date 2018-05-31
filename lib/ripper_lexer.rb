require 'ripper_lexer/version'
require 'ripper'
require 'ostruct'
require 'parser'
require 'yaml'
require 'pry'

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
      rewriter = RipperLexer::Rewriter.new(
        builder: @builder,
        file: source_buffer.name,
        source: source
      )
      rewriter.parse
    end
  end
end

module RipperLexer
  class Rewriter < ::Ripper::SexpBuilderPP
    def initialize(builder:, file:, source:)
      @builder = builder
      @file = file
      @escapes = []
      super(source)
    end

    scanner_methods = SCANNER_EVENTS.map{ |m| :"on_#{m}" }
    (instance_methods.grep(/\Aon_/) - scanner_methods).each do |method_name|
      define_method method_name do |*args|
        raise "Missing handler #{method_name} (#{args.length} args)"
      end
    end

    # === Scanner events ===

    def on_tstring_beg(term)
      interp = term == '"' || term.start_with?('%Q')
      @escapes.push(interp)
    end

    def on_tstring_end(term)
      @escapes.pop
    end

    def on_heredoc_beg(term)
      @escapes.push(!term.end_with?("'"))
    end

    def on_heredoc_end(term)
      @escapes.pop
    end

    def on_qsymbols_beg(term)
      @escapes.push(false)
    end

    def on_qsymbols_end(term)
      @escapes.pop
    end

    def on_words_beg(term)
      @escapes.push(true)
    end

    def on_symbols_beg(term)
      @escapes.push(true)
    end

    def on_symbols_end(term)
      @escapes.pop
    end

    def on_heredoc_dedent(val, width)
      val.map! do |e|
        dedent_string(e, width) if e.is_a?(String)
        e
      end
    end

    def on_backtick(term)
      @escapes.push(false)
    end

    # === Parser events ===

    def begin_node(stmts)
      if stmts.is_a?(AST::Node)
        stmts
      elsif stmts.is_a?(Array)
        stmts.compact!
        case stmts.length
        when 0
          return nil
        when 1
          stmts[0]
        else
          s(:begin, *stmts)
        end
      elsif stmts.nil?
        nil
      else
        binding.pry
      end
    end

    def on_int(v)
      s(:int, v.to_i)
    end

    def on_binary(lhs, op, rhs)
      case op
      when :and, :'&&'
        s(:and, lhs, rhs)
      when :or, :'||'
        s(:or, lhs, rhs)
      else
        s(:send, lhs, op, rhs)
      end
    end

    def on_stmts_new
      []
    end

    def on_stmts_add(list, stmt)
      list.push(stmt)
    end

    def on_program(stmts)
      begin_node(stmts)
    end

    def on_tstring_content(str)
      if @escapes.last
        if str.ascii_only?
          str = ('"' + str + '"').undump
        else
          str = str.gsub("\\t", "\t").gsub("\\n", "\n").gsub("\\r", "\r")
        end
      end

      str
    end

    def on_string_content
      []
    end

    def on_string_add(strings, str)
      strings.push(str || '')
    end

    def on_string_literal(parts)
      parts = [''] if parts == []

      if parts.length == 1 && parts[0].is_a?(String)
        return s(:str, parts[0])
      end

      parts.map! { |part| part.is_a?(AST::Node) ? part : s(:str, part) }
      s(:dstr, *parts)
    end

    def on_string_concat(*strs)
      s(:dstr, *strs)
    end

    def on_string_embexpr(exprs)
      s(:begin, *exprs.compact)
    end

    def on_string_dvar(dvar)
      dvar
    end

    def on_qwords_new
      []
    end

    def on_qwords_add(qwords, qword)
      qwords.push(s(:str, qword))
    end

    def on_words_add(list, words)
      dynamic = words.any? { |w| w.is_a?(AST::Node) }
      words.map! { |w| w.is_a?(AST::Node) ? w : s(:str, w) }
      word = dynamic ? s(:dstr, *words) : words[0]
      list.push(word)
    end

    def on_words_new
      []
    end

    def on_word_add(list, word)
      list.push(word)
    end

    def on_word_new
      []
    end

    def on_symbols_new
      []
    end

    def on_symbols_add(list, parts)
      parts.map! { |part| part.is_a?(AST::Node) ? part : s(:sym, part.to_sym) }
      list.concat(parts)
    end

    def on_qsymbols_new
      []
    end

    def on_qsymbols_add(list, qsymbol)
      list.push(s(:sym, qsymbol.to_sym))
    end

    def on_xstring_new
      []
    end

    def on_xstring_add(list, xstring)
      list.push(xstring)
    end

    DummyRange = Struct.new(:source, :line, :col)

    def on_xstring_literal(strs)
      strs.map! do |str|
        if str.is_a?(AST::Node)
          str
        else
          range = DummyRange.new(str, 0, 0)
          map = Parser::Source::Map::Collection.new(nil, nil, range)
          s(:str, str, map: map)
        end
      end

      s(:xstr, *strs)
    end

    def on_array(items)
      s(:array, *items)
    end

    def on_const(const_name)
      s(:const, nil, const_name.to_sym)
    end

    def on_const_ref(ref)
      ref
    end

    def on_void_stmt
    end

    def to_arg(arg)
      case arg
      when Array
        s(:mlhs, *arg.map { |a| to_arg(a) })
      when AST::Node
        arg
      else
        s(:arg, arg)
      end
    end

    def on_excessed_comma(args)
      args
    end

    def on_params(req, opt, rest, post, kwargs, kwrest, block)
      args = []

      if req
        req.each { |arg| args << to_arg(arg) }
      end

      if opt
        opt.each { |arg, default_value| args << s(:optarg, arg, default_value) }
      end

      if rest
        args << rest
      end

      if post
        post.each { |arg| args << to_arg(arg) }
      end

      if kwargs
        kwargs.each do |name, default_value|
          if default_value
            args << s(:kwoptarg, name, default_value)
          else
            args << s(:kwarg, name)
          end
        end
      end

      if kwrest
        args << kwrest
      end

      if block
        args << block
      end

      s(:args, *args)
    end

    def on_paren(stmts)
      if stmts.is_a?(Array)
        s(:begin, *stmts.compact)
      elsif !stmts
        s(:begin)
      else
        s(:begin, stmts)
      end
    end

    def on_bodystmt(stmts, resbodies, else_body, ensure_body)
      body = begin_node(stmts)

      if resbodies.nil? && else_body.nil? && ensure_body.nil?
        return body
      end

      else_body = nil if resbodies.is_a?(Array) && else_body == s(:begin, nil)
      else_body = s(:begin, else_body) if body && else_body

      if resbodies
        if else_body && else_body.type == :begin && else_body.children.length == 1
          else_body = else_body.children[0]
        end

        body = s(:rescue, body, *resbodies, else_body)
      elsif else_body
        stmts = []

        if body
          if body.type == :begin
            stmts += body.children
          else
            stmts << body
          end
        end

        if else_body
          stmts << else_body
        end

        stmts.compact!

        body = s(:begin, *stmts)
      end

      if ensure_body
        ensure_body = nil if ensure_body == s(:begin)
        body = s(:ensure, body, ensure_body)
      end

      body
    end

    def on_ident(ident)
      ident.to_sym
    end

    def on_def(mid, args, bodystmt)
      _, mid =  *mid if mid.is_a?(AST::Node)
      if args && args.type == :begin && args.children.length == 1
        args = args.children[0]
      end
      s(:def, mid, args, bodystmt)
    end

    def on_defs(definee, dot, mid, args, bodystmt)
      _, mid =  *mid if mid.is_a?(AST::Node)
      if definee.type == :begin && definee.children.length == 1
        definee = definee.children[0]
      end
      s(:defs, definee, mid, args, bodystmt)
    end

    def on_mlhs_new
      []
    end

    def on_mlhs_add(list, lhs)
      list.push(lhs)
    end

    def on_mlhs_add_star(list, splat)
      splat = splat ? s(:restarg, splat) : s(:restarg)
      list.push(splat)
    end

    def on_mlhs_paren(lhses)
      lhses
    end

    def on_rest_param(rest)
      if rest
        s(:restarg, rest)
      else
        s(:restarg)
      end
    end

    def on_kwrest_param(kwrest)
      if kwrest
        s(:kwrestarg, kwrest)
      else
        s(:kwrestarg)
      end
    end

    def on_blockarg(block)
      s(:blockarg, block)
    end

    def on_label(label)
      label[0..-2].to_sym
    end

    def on_var_ref(ref)
      if ref.is_a?(Symbol)
        s(:lvar, ref)
      else
        ref
      end
    end

    def on_var_field(field)
      case field
      when Symbol
        s(:lvar, field)
      else
        field
      end
    end

    def on_assign(var, value)
      value = s(:array, *value) if value.is_a?(Array)
      var = reader_to_writer(var)

      var.updated(nil, [*var, value])
    end

    def on_kw(keyword)
      case keyword
      when 'nil'
        s(:nil)
      when 'true'
        s(:true)
      when 'false'
        s(:false)
      when '__LINE__'
        if @builder.emit_file_line_as_literals
          s(:int, lineno)
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

    def on_begin(inner)
      return s(:kwbegin) if inner.nil?

      if inner.is_a?(AST::Node) && inner.type == :begin
        if inner.children.length > 1
          inner.updated(:kwbegin)
        else
          s(:kwbegin, inner)
        end
      else
        s(:kwbegin, inner)
      end
    end

    def on_float(value)
      s(:float, value.to_f)
    end

    def on_unary(sign, value)
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

    def on_rational(value)
      s(:rational, value.to_r)
    end

    def on_imaginary(value)
      if value.end_with?('ri')
        s(:complex, eval(value))
      else
        s(:complex, value.to_c)
      end
    end

    def on_ivar(value)
      s(:ivar, value.to_sym)
    end

    def on_cvar(value)
      s(:cvar, value.to_sym)
    end

    def on_gvar(value)
      s(:gvar, value.to_sym)
    end

    def on_CHAR(value)
      s(:str, value[1])
    end

    def on_args_new
      []
    end

    def on_args_add(list, arg)
      arg ? list.push(arg) : arg
    end

    def on_args_add_block(args, block)
      args.push(s(:block_pass, block)) if block
      args
    end

    def on_command(mid, args)
      s(:send, nil, mid, *args)
    end

    def on_command_call(recv, dot, mid, args)
      _, mid = *mid if mid.is_a?(AST::Node)
      s(dot == :'&.' ? :csend : :send, recv, mid, *args)
    end

    def on_hash(assoclist)
      if assoclist.nil?
        s(:hash)
      else
        s(:hash, *assoclist)
      end
    end

    def on_assoclist_from_args(assocs)
      assocs
    end

    def on_symbol(sym)
      sym
    end

    def on_symbol_literal(value)
      s(:sym, value)
    end

    def on_dyna_symbol(parts)
      interpolated = parts.any? { |part| part.is_a?(AST::Node) }
      parts.map! { |part| part.is_a?(AST::Node) ? part : s(:str, part) }

      if interpolated
        s(:dsym, *parts)
      elsif parts.length == 1
        part = parts.first
        part.updated(:sym, [part.children[0].to_sym])
      else
        s(:dsym, *parts)
      end
    end

    def on_regexp_literal(parts, modifiers)
      parts.map! { |part| part.is_a?(AST::Node) ? part : s(:str, part) }
      s(:regexp, *parts, modifiers)
    end

    def on_regexp_new
      []
    end

    def on_regexp_add(list, part)
      list.push(part)
    end

    def on_regexp_end(value)
      modifiers = value.chars[1..-1].map(&:to_sym).sort
      s(:regopt, *modifiers)
    end

    def on_args_add_star(before, splat_value)
      before.push(s(:splat, splat_value))
    end

    def on_assoc_new(key, value)
      key = s(:sym, key) if key.is_a?(Symbol)
      s(:pair, key, value)
    end

    def on_bare_assoc_hash(assocs)
      s(:hash, *assocs)
    end

    def on_vcall(mid)
      return nil if mid.nil?
      s(:send, nil, mid)
    end

    def on_ifop(cond, then_branch, else_branch)
      s(:if, cond, then_branch, else_branch)
    end

    def on_arg_paren(inner)
      inner
    end

    def on_fcall(ident)
      if ident.is_a?(AST::Node) && ident.type == :const
        _, ident = *ident
      end
      s(:send, nil, ident)
    end

    def on_method_add_arg(call, args)
      call.updated(nil, [*call, *args])
    end

    def on_assoc_splat(value)
      s(:kwsplat, value)
    end

    def on_dot2(range_start, range_end)
      s(:irange, range_start, range_end)
    end

    def on_dot3(range_start, range_end)
      s(:erange, range_start, range_end)
    end

    def on_backref(value)
      if match = value.match(/\$(\d+)/)
        s(:nth_ref, match[1].to_i)
      else
        s(:back_ref, value.to_sym)
      end
    end

    def on_top_const_ref(ref)
      _, const_name = *ref
      s(:const, s(:cbase), const_name)
    end

    def on_const_path_ref(scope, const)
      _, const_name = *const
      s(:const, scope, const_name)
    end

    def on_top_const_field(const)
      _, const_name = *const
      s(:const, s(:cbase), const_name)
    end

    def on_defined(inner)
      s(:defined?, inner)
    end

    def on_const_path_field(scope, const)
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

    def on_mrhs_new_from_args(rhses)
      rhses
    end

    def on_mrhs_add_star(rhses, splat)
      rhses.push(s(:splat, splat))
    end

    def _build_mlhs(lhses)
      lhses.map! do |lhs|
        if lhs.is_a?(Array)
          lhs = s(:mlhs, *_build_mlhs(lhs))
        else
          lhs = reader_to_writer(lhs)
        end
        lhs
      end
    end

    def on_massign(lhses, rhs)
      mlhs = _build_mlhs(lhses)
      rhs = s(:array, *rhs) if rhs.is_a?(Array)
      s(:masgn, s(:mlhs, *lhses), rhs)
    end

    def on_field(recv, dot, mid)
      _, mid = *mid if mid.is_a?(AST::Node)
      s(dot == :'&.' ? :csend : :send, recv, mid)
    end

    def on_aref(recv, args)
      if @builder.class.emit_index
        s(:index, recv, *args)
      else
        s(:send, recv, :[], *args)
      end
    end

    def on_aref_field(recv, args)
      if @builder.class.emit_index
        s(:index, recv, *args)
      else
        s(:send, recv, :[], *args)
      end
    end

    def on_opassign(recv, op, arg)
      if recv.type != :send && recv.type != :csend
        recv = reader_to_writer(recv)
      end
      case op
      when '||='
        s(:or_asgn, recv, arg)
      when '&&='
        s(:and_asgn, recv, arg)
      else
        s(:op_asgn, recv, op[0].to_sym, arg)
      end
    end

    def on_op(value)
      value
    end

    def on_module(const_name, bodystmt)
      s(:module, const_name, bodystmt)
    end

    def on_class(const_name, superclass, bodystmt)
      s(:class, const_name, superclass, bodystmt)
    end

    def on_sclass(sclass_of, bodystmt)
      s(:sclass, sclass_of, bodystmt)
    end

    def on_undef(mids)
      s(:undef, *mids)
    end

    def on_alias(old_id, new_id)
      s(:alias, old_id, new_id)
    end

    def on_var_alias(old_id, new_id)
      s(:alias, old_id, new_id)
    end

    def on_block_var(args, shadow_args)
      shadow_args = shadow_args ? shadow_args.map { |arg| s(:shadowarg, arg) } : []
      args.updated(nil, [*args, *shadow_args])
    end

    def _handle_procarg0(args)
      arglist = args.children

      if arglist.last == 0
        invisible_rest = true
        arglist = arglist[0..-2]
      else
        invisible_rest = false
      end

      if arglist.length == 1 && @builder.class.emit_procarg0 && !invisible_rest
        arg = arglist[0]
        if arg.type == :arg
          arglist = [arg.updated(:procarg0)]
        end
      end

      s(:args, *arglist)
    end

    def on_brace_block(args, stmts)
      body = begin_node(stmts)
      args ||= s(:args)

      args = _handle_procarg0(args)

      s(:block, args, body)
    end

    def on_method_add_block(method_call, block)
      block.updated(nil, [method_call, *block])
    end

    def on_do_block(args, body)
      body = s(:begin, *body.compact) if body.is_a?(Array)
      args ||= s(:args)

      args = _handle_procarg0(args)

      s(:block, args, body)
    end

    def on_call(recv, dot, mid)
      _, mid = *mid if mid.is_a?(AST::Node)
      s(dot == :'&.' ? :csend : :send, recv, mid)
    end

    def on_lambda(args, stmts)
      body = begin_node(stmts)
      if args.is_a?(AST::Node) && args.type == :begin && args.children.length == 1
        args = args.children[0]
      end
      lambda_call = @builder.class.emit_lambda ? s(:lambda) : s(:send, nil, :lambda)
      s(:block, lambda_call, args, body)
    end

    def on_super(args)
      s(:super, *args)
    end

    def on_zsuper
      s(:zsuper)
    end

    def on_yield(args)
      s(:yield, *args)
    end

    def on_yield0
      s(:yield)
    end

    def on_if(cond, then_smts, else_stmts)
      then_body = begin_node(then_smts)
      else_body = begin_node(else_stmts)
      s(:if, cond, then_body, else_body)
    end

    def on_if_mod(cond, then_branch)
      on_if(cond, then_branch, nil)
    end

    def on_else(stmts)
      begin_node(stmts) || s(:begin, nil)
    end

    def on_elsif(cond, then_branch, else_branch)
      on_if(cond, then_branch, else_branch)
    end

    def on_unless(cond, then_branch, else_branch)
      on_if(cond, else_branch, then_branch)
    end

    def on_unless_mod(cond, then_branch)
      on_if(cond, nil, then_branch)
    end

    def on_case(cond, whens)
      s(:case, cond, *whens)
    end

    def on_when(conds, stmts, next_whens)
      body = begin_node(stmts)
      next_whens = [next_whens] unless next_whens.is_a?(Array)
      [s(:when, *conds, body), *next_whens]
    end

    def on_while(cond, stmts)
      body = begin_node(stmts)
      s(:while, cond, body)
    end

    def on_while_mod(cond, stmt)
      while_type = stmt.type == :kwbegin ? :while_post : :while
      s(while_type, cond, stmt)
    end

    def on_until(cond, stmts)
      body = begin_node(stmts)
      s(:until, cond, body)
    end

    def on_until_mod(cond, stmt)
      until_type = stmt.type == :kwbegin ? :until_post : :until
      s(until_type, cond, stmt)
    end

    def on_for(vars, in_var, stmts)
      if vars.is_a?(Array)
        vars = s(:mlhs, *_build_mlhs(vars))
      else
        vars = reader_to_writer(vars)
      end

      body = begin_node(stmts)

      s(:for, vars, in_var, body)
    end

    def on_break(args)
      args ||= []
      s(:break, *args)
    end

    def on_return(args)
      arg = begin_node(args)
      s(:return, arg)
    end

    def on_return0
      s(:return)
    end

    def on_next(args)
      args = s(:begin, *args.compact) if args.is_a?(Array)
      s(:next, *args)
    end

    def on_redo
      s(:redo)
    end

    def on_retry
      s(:retry)
    end

    def on_BEGIN(stmts)
      s(:preexe, begin_node(stmts))
    end

    def on_END(stmts)
      s(:postexe, begin_node(stmts))
    end

    def on_rescue(klasses, var, stmts, nested)
      klasses = s(:array, *klasses) if klasses.is_a?(Array)
      var = reader_to_writer(var) if var
      stmts = begin_node(stmts)

      [s(:resbody, klasses, var, stmts), *nested]
    end

    def on_rescue_mod(bodystmt, rescue_handler)
      s(:rescue, bodystmt, s(:resbody, nil, nil, rescue_handler), nil)
    end

    def on_ensure(stmts)
      begin_node(stmts) || s(:begin)
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

    def on_magic_comment(_, _)
    end

    def s(type, *children, map: nil)
      @builder.send(:n, type, children, map)
    end
  end
end
