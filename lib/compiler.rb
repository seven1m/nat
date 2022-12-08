require 'bundler/setup'
require 'natalie_parser'
require_relative './compiler/instruction'
require_relative './compiler/dependency'
require_relative './compiler/call_arg_dependency'
require_relative './compiler/variable_dependency'

class Compiler
  def initialize(code)
    @code = code
    @ast = NatalieParser.parse(code)
  end

  def compile
    @scope_stack = [{ vars: {} }]
    @methods = {}
    @calls = Hash.new { |h, k| h[k] = [] }
    @instructions = []
    transform(@ast)
    @instructions
  end

  private

  def transform(node)
    case node.sexp_type
    when :lit
      _, value = node
      instruction = Instruction.new(:push_int, arg: value, type: :int)
      @instructions << instruction
      instruction
    when :str
      _, value = node
      instruction = Instruction.new(:push_str, arg: value, type: :str)
      @instructions << instruction
      instruction
    when :block
      _, *nodes = node
      nodes.each { |n| transform(n) }
    when :lasgn
      _, name, value = node
      value_instruction = transform(value)
      instruction = Instruction.new(:set_var, arg: name)
      instruction.add_dependency(Dependency.new(instruction: value_instruction))
      set_var(name, instruction)
      @instructions << instruction
      instruction
    when :lvar
      _, name = node
      instruction = Instruction.new(:push_var, arg: name)
      instruction.add_dependency(VariableDependency.new(name: name, scope: scope))
      @instructions << instruction
      instruction
    when :defn
      @scope_stack << { vars: {} }
      _, name, (_, *args), *body = node
      instruction = Instruction.new(:def, arg: name)
      @instructions << instruction
      args.each_with_index do |arg, index|
        i1 = Instruction.new(:push_arg, arg: index)
        i1.add_dependency(
          CallArgDependency.new(
            method_name: name,
            calls: @calls[name],
            arg_index: index,
            arg_name: arg
          )
        )
        @instructions << i1
        i2 = Instruction.new(:set_var, arg: arg)
        i2.add_dependency(i1)
        @instructions << i2
        set_var(arg, i2)
      end
      body_instructions = body.map { |n| transform(n) }
      return_instruction = body_instructions.last
      instruction.add_dependency(return_instruction)
      set_method(name, instruction)
      @scope_stack.pop
      @instructions << Instruction.new(:end_def, arg: name)
      instruction
    when :call
      _, _receiver, name, *args = node
      arg_instructions = args.map do |arg|
        transform(arg)
      end
      @calls[name] << { args: arg_instructions }
      instruction = Instruction.new(:call, arg: name, extra_arg: args.size)
      instruction.add_dependency(@methods.fetch(name))
      @instructions << instruction
      instruction
    else
      raise "unknown node: #{node.inspect}"
    end
  end

  def scope
    @scope_stack.last
  end

  def vars
    scope.fetch(:vars)
  end

  def set_var(name, instruction)
    vars[name] ||= []
    vars[name] << instruction
    unique_types = vars[name].map do |dep|
      begin
        dep.type!
      rescue TypeError
        # If we don't yet know the type for this dependency,
        # that's fine, because we might know it later.
      end
    end.compact.uniq
    if unique_types.size > 1
      raise TypeError, "Variable a was set with more than one type: #{unique_types.inspect}"
    end
  end

  def set_method(name, instruction)
    if @methods[name]
      raise TypeError, 'TODO'
    end

    @methods[name] = instruction
  end
end
