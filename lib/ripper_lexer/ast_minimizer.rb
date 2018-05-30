module RipperLexer
  class AstMinimizer < Parser::AST::Processor
    def _join_str_nodes(nodes)
      nodes.map { |node| node.children[0] }.join
    end

    def on_dstr(node)
      node = super
      children = node.children

      if children.empty? || children.all?(&:nil?)
        process node.updated(:str, [''])
      elsif children.all? { |c| c.is_a?(AST::Node) && c.type == :str }
        process node.updated(:str, [_join_str_nodes(children)])
      else
        node
      end
    end

    def on_str(node)
      node
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
        content = _join_str_nodes(children)
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
      unless node.respond_to?(:to_ast)
        p node
        raise 'Not an AST node'
      end
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
end
