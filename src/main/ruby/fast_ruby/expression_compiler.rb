require 'fast_ruby/jdt_utils'

module FastRuby
  class ExpressionCompiler
    include JDTUtils

    include org.jruby.ast.visitor.NodeVisitor

    def initialize(ast, body_compiler, node)
      @ast, @body_compiler, @node = ast, body_compiler, node
    end

    attr_accessor :ast, :body_compiler, :node

    def start
      expression = node.accept(self)

      expression
    end

    def method_compiler
      body_compiler.method_compiler
    end

    def class_compiler
      method_compiler.class_compiler
    end

    def nil_expression(*args)
      ast.new_name('RNil')
    end
    alias method_missing nil_expression

    def empty_expression
      nil
    end
    
    def visitClassNode(node)
      source = new_source
      class_compiler.compiler.sources << source

      new_ast = source.ast

      new_class_compiler = ClassCompiler.new(class_compiler.compiler, new_ast, source, node.cpath.name, node)
      new_class_compiler.start

      empty_expression
    end

    def visitCallNode(node)
      class_compiler.compiler.methods[safe_name(node.name)] = node.args_node ? node.args_node.child_nodes.size : 0

      method_invocation = case node.name
      when "new"
        ast.new_class_instance_creation.tap do |construct|
          construct.type = ast.new_simple_type(ast.new_simple_name(node.receiver_node.name))
        end
      else
        ast.new_method_invocation.tap do |method_invocation|
          method_invocation.name = ast.new_simple_name(safe_name(node.name))
          method_invocation.expression = ExpressionCompiler.new(ast, body_compiler, node.receiver_node).start
        end
      end
        
      node.args_node && node.args_node.child_nodes.each do |arg|
        arg_expression = ExpressionCompiler.new(ast, body_compiler, arg).start
        method_invocation.arguments << arg_expression
      end

      method_invocation
    end

    def visitFCallNode(node)
      class_compiler.compiler.methods[safe_name(node.name)] = node.args_node ? node.args_node.child_nodes.size : 0

      ast.new_method_invocation.tap do |method_invocation|
        method_invocation.name = ast.new_simple_name(node.name)
        method_invocation.expression = ast.new_this_expression
        
        node.args_node && node.args_node.child_nodes.each do |arg|
          arg_expression = ExpressionCompiler.new(ast, body_compiler, arg).start
          method_invocation.arguments << arg_expression
        end
      end
    end

    def visitVCallNode(node)
      class_compiler.compiler.methods[safe_name(node.name)] = 0

      ast.new_method_invocation.tap do |method_invocation|
        method_invocation.name = ast.new_simple_name(node.name)
        method_invocation.expression = ast.new_this_expression
      end
    end

    def visitDefnNode(node)
      method_compiler = MethodCompiler.new(ast, class_compiler, node)
      method_compiler.start

      empty_expression
    end

    def visitStrNode(node)
      ast.new_class_instance_creation.tap do |construct|
        construct.type = ast.new_simple_type(ast.new_simple_name("RString"))
        construct.arguments << ast.new_string_literal.tap do |string_literal|
          string_literal.literal_value = node.value.to_s
        end
      end
    end

    def visitFixnumNode(node)
      ast.new_class_instance_creation.tap do |construct|
        construct.type = ast.new_simple_type(ast.new_simple_name("RFixnum"))
        construct.arguments << ast.new_number_literal(node.value.to_s + "L")
      end
    end

    def visitFloatNode(node)
      ast.new_class_instance_creation.tap do |construct|
        construct.type = ast.new_simple_type(ast.new_simple_name("RFloat"))
        construct.arguments << ast.new_number_literal(node.value.to_s)
      end
    end

    def visitNewlineNode(node)
      node.next_node.accept(self)
    end

    def visitNilNode(node)
      nil_expression
    end

    def visitLocalVarNode(node)
      ast.new_name(node.name)
    end

    def visitLocalAsgnNode(node)
      unless body_compiler.declared_vars.include? node.name
        body_compiler.declared_vars << node.name
        var = ast.new_variable_declaration_fragment
        var.name = ast.new_simple_name(node.name)
      
        var.initializer = ast.new_name("RNil")
        var_assign = ast.new_variable_declaration_statement(var)
        var_assign.type = ast.new_simple_type(ast.new_simple_name("RObject"))

        body_compiler.body.statements << var_assign
      end

      var_assign = ast.new_assignment
      var_assign.left_hand_side = ast.new_name(node.name)
      var_assign.right_hand_side = ExpressionCompiler.new(ast, body_compiler, node.value_node).start

      var_assign
    end

    def visitIfNode(node)
      conditional = ast.new_if_statement
      
      condition_expr = ExpressionCompiler.new(ast, body_compiler, node.condition).start
      java_boolean = ast.new_method_invocation
      java_boolean.expression = condition_expr
      java_boolean.name = ast.new_simple_name("toBoolean")

      conditional.expression = java_boolean

      if node.then_body
        then_stmt = StatementCompiler.new(ast, body_compiler, node.then_body).start
        conditional.then_statement = then_stmt
      end

      if node.else_body
        else_stmt = StatementCompiler.new(ast, body_compiler, node.else_body).start
        conditional.else_statement = else_stmt
      end

      body_compiler.body.statements << conditional

      nil
    end

    def visitZArrayNode(node)
      ast.new_class_instance_creation.tap do |ary|
        ary.type = ast.new_simple_type(ast.new_simple_name('RArray'))
      end
    end

    def visitArrayNode(node)
      visitZArrayNode(node).tap do |ary|
        node.child_nodes.each do |element|
          ary.arguments << ExpressionCompiler.new(ast, body_compiler, element).start
        end
      end
    end

    def visitConstDeclNode(node)
      const_assign = ast.new_variable_declaration_fragment
      const_assign.name = ast.new_simple_name(node.name)
      const_assign.initializer = ExpressionCompiler.new(ast, body_compiler, node.value_node).start

      declaration = ast.new_field_declaration(const_assign).tap do |decl|
        decl.modifiers << ast.new_modifier(ModifierKeyword::PUBLIC_KEYWORD)
        decl.modifiers << ast.new_modifier(ModifierKeyword::STATIC_KEYWORD)
        decl.type = ast.new_simple_type(ast.new_simple_name('RObject'))
      end

      class_compiler.class_decl.body_declarations << declaration

      ast.new_name(node.name)
    end

    def visitConstNode(node)
      ast.new_qualified_name(ast.new_simple_name(class_compiler.class_name), ast.new_simple_name(node.name))
    end

    def safe_name(name)
      new_name = ''

      name.chars.each do |ch|
        new_name << case ch
          when '+'; '$plus'
          when '-'; '$minus'
          when '*'; '$times'
          when '/'; '$div'
          when '<'; '$less'
          when '>'; '$greater'
          when '='; '$equal'
          when '&'; '$tilde'
          when '!'; '$bang'
          when '%'; '$percent'
          when '^'; '$up'
          when '?'; '$qmark'
          when '|'; '$bar'
          when '['; '$lbrack'
          when ']'; '$rbrack'
          else; ch;
        end
      end

      new_name
    end
  end
end