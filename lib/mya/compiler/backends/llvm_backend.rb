require 'llvm/core'
require 'llvm/execution_engine'

class Compiler
  module Backends
    class LLVMBackend
      def initialize(instructions, io: $stdout, dump: false)
        @instructions = instructions
        @stack = []
        @scope_stack = [{ vars: {} }]
        @call_stack = []
        @if_depth = 0
        @methods = {}
        @io = io
        @dump = dump
        @module = LLVM::Module.new('llvm')
      end

      attr_reader :instructions

      def run
        return_type = @instructions.last.type!

        @index = 0
        main = build_function('main', [], llvm_type(return_type))
        raise 'Bad code generated' unless main.valid?

        @module.dump if @dump

        LLVM.init_jit

        engine = LLVM::JITCompiler.new(@module)
        value = engine.run_function(main)
        return_value = case return_type
                      when :bool
                        value.to_i == -1
                      when :int
                        value.to_i
                      when :str
                        value.to_ptr.read_pointer.read_string
                        #value.to_ptr.read_string
                      end
        engine.dispose

        return_value
      end

      private

      BUILT_IN_METHODS = {
        '+': ->(builder, lhs, rhs) { builder.add(lhs, rhs) },
        '-': ->(builder, lhs, rhs) { builder.sub(lhs, rhs) },
        '*': ->(builder, lhs, rhs) { builder.mul(lhs, rhs) },
        '/': ->(builder, lhs, rhs) { builder.sdiv(lhs, rhs) },
        '==': ->(builder, lhs, rhs) { builder.icmp(:eq, lhs, rhs) },
        'p': ->(arg, io:) { io.puts(arg.inspect) }
      }.freeze

      def build_function(name, arg_types, return_type)
        @module.functions.add(name, arg_types, return_type) do |function|
          @scope_stack << { function:, vars: {} }
          function.basic_blocks.append.build do |builder|
            build_instructions(function, builder, stop_at: [:end_def]) do |return_value|
              case function.return_type
              when :str
                zero = LLVM.Int(0)
                builder.ret builder.gep(return_value, zero)
              else
                builder.ret return_value
              end
            end
          end
          @scope_stack.pop
        end
      end

      def build_instructions(function, builder, stop_at: [])
        while @index < @instructions.size
          instruction = @instructions[@index]
          build(instruction, function, builder)
          @index += 1
          break if stop_at.include?(@instructions[@index]&.name)
        end
        return_value = @stack.pop
        yield return_value
      end

      def build(instruction, function, builder)
        case instruction.name
        when :push_int
          @stack << LLVM::Int(instruction.arg)
        when :push_str
          # FIXME: don't always want a global string here probably
          str = @module.globals.add(LLVM::ConstantArray.string(instruction.arg), 'str') do |var|
            var.initializer = LLVM::ConstantArray.string(instruction.arg)
          end
          @stack << str
        when :push_true
          @stack << LLVM::TRUE
        when :push_false
          @stack << LLVM::FALSE
        when :set_var
          value = @stack.pop
          variable = builder.alloca(value.type)
          builder.store(value, variable)
          vars[instruction.arg] = variable
        when :push_var
          variable = vars.fetch(instruction.arg)
          @stack << builder.load(variable)
        when :def
          @index += 1
          name = instruction.arg
          arg_types = (0...instruction.extra_arg).map do |i|
            llvm_type(@instructions.fetch(@index + (i * 2)).type!)
          end
          @methods[name] = build_function(name, arg_types, llvm_type(instruction.type!))
        when :end_def, :end_if, :else
          raise 'should not reach here'
        when :call
          args = @stack.pop(instruction.extra_arg)
          if (built_in_method = BUILT_IN_METHODS[instruction.arg])
            @stack << built_in_method.call(builder, *args)
          else
            name = instruction.arg
            function = @methods[name] or raise(NoMethodError, "Method '#{name}' not found")
            @stack << builder.call(function, *args)
          end
        when :push_arg
          function = @scope_stack.last.fetch(:function)
          @stack << function.params[instruction.arg]
        when :if
          result = builder.alloca(llvm_type(instruction.type!))
          then_block = function.basic_blocks.append
          else_block = function.basic_blocks.append
          result_block = function.basic_blocks.append
          condition = @stack.pop
          builder.cond(condition, then_block, else_block)
          raise 'bad if' if @index >= @instructions.size || @instructions[@index].name != :if
          @index += 1
          then_block.build do |then_builder|
            build_instructions(function, then_builder, stop_at: [:else]) do |value|
              then_builder.store(value, result)
              then_builder.br(result_block)
            end
          end
          raise 'bad else' if @index >= @instructions.size || @instructions[@index].name != :else
          @index += 1
          else_block.build do |else_builder|
            build_instructions(function, else_builder, stop_at: [:end_if]) do |value|
              else_builder.store(value, result)
              else_builder.br(result_block)
            end
          end
          builder.position_at_end(result_block)
          @stack << builder.load(result)
        else
          raise "Unknown instruction: #{instruction.inspect}"
        end
      end

      def skip_to_next_instruction_by_name(name)
        start_if_depth = @if_depth
        until @instructions[@index].name == name && @if_depth == start_if_depth
          case @instructions[@index].name
          when :if
            @if_depth += 1
          when :end_if
            @if_depth -= 1
          end
          @index += 1
        end
      end

      def scope
        @scope_stack.last
      end

      def vars
        scope.fetch(:vars)
      end

      def llvm_type(type)
        case type
        when :bool
          LLVM::Int1
        when :int
          LLVM::Int32
        when :str
          LLVM::Type.pointer(LLVM::UInt8)
        else
          raise "Unknown type: #{type.inspect}"
        end
      end
    end
  end
end
