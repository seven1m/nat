require 'minitest/autorun'
require 'minitest/focus'

require_relative '../lib/compiler'
require_relative '../spec/support/expectations'

describe Compiler do
  def compile(code)
    Compiler.new(code).compile.map(&:to_h)
  end

  it 'compiles integers' do
    expect(compile('1')).must_equal [
      { type: :int, instruction: [:push_int, 1] }
    ]
  end

  it 'compiles strings' do
    expect(compile('"foo"')).must_equal [
      { type: :str, instruction: [:push_str, 'foo'] }
    ]
  end

  it 'compiles variables set and get' do
    expect(compile('a = 1; a')).must_equal [
      { type: :int, instruction: [:push_int, 1] },
      { type: :int, instruction: [:set_var, :a] },
      { type: :int, instruction: [:push_var, :a] }
    ]
  end

  it 'can set a variable more than once' do
    expect(compile('a = 1; a = 2')).must_equal [
      { type: :int, instruction: [:push_int, 1] },
      { type: :int, instruction: [:set_var, :a] },
      { type: :int, instruction: [:push_int, 2] },
      { type: :int, instruction: [:set_var, :a] }
    ]
  end

  it 'raises an error if the variable type changes' do
    e = expect do
      compile('a = 1; a = "foo"')
    end.must_raise TypeError
    expect(e.message).must_equal 'Variable a was set with more than one type: [:int, :str]'
  end

  it 'compiles method definitions' do
    code = <<~CODE
      def foo
        'foo'
      end
      def bar
        1
      end
      foo
      bar
    CODE
    expect(compile(code)).must_equal [
      { type: :str, instruction: [:def, :foo] },
      { type: :str, instruction: [:push_str, 'foo'] },
      { type: nil, instruction: [:end_def, :foo] },
      { type: :int, instruction: [:def, :bar] },
      { type: :int, instruction: [:push_int, 1] },
      { type: nil, instruction: [:end_def, :bar] },
      { type: :str, instruction: [:call, :foo, 0] },
      { type: :int, instruction: [:call, :bar, 0] }
    ]
  end

  it 'compiles method definitions with arguments' do
    code = <<~CODE
      def foo(a, b)
        a
      end

      def bar(a)
        a
      end

      foo('foo', 1)

      bar(2)
    CODE
    expect(compile(code)).must_equal_with_diff [
      { type: :str, instruction: [:def, :foo] },
      { type: :str, instruction: [:push_arg, 0] },
      { type: :str, instruction: [:set_var, :a] },
      { type: :int, instruction: [:push_arg, 1] },
      { type: :int, instruction: [:set_var, :b] },
      { type: :str, instruction: [:push_var, :a] },
      { type: nil, instruction: [:end_def, :foo] },

      { type: :int, instruction: [:def, :bar] },
      { type: :int, instruction: [:push_arg, 0] },
      { type: :int, instruction: [:set_var, :a] },
      { type: :int, instruction: [:push_var, :a] },
      { type: nil, instruction: [:end_def, :bar] },

      { type: :str, instruction: [:push_str, 'foo'] },
      { type: :int, instruction: [:push_int, 1] },
      { type: :str, instruction: [:call, :foo, 2] },

      { type: :int, instruction: [:push_int, 2] },
      { type: :int, instruction: [:call, :bar, 1] }
    ]
  end

  it 'raises an error if the method arg type is unknown' do
    code = <<~CODE
      def foo(a)
        a
      end
    CODE
    e = expect { compile(code) }.must_raise TypeError
    expect(e.message).must_equal "Not enough information to infer type of argument 'a' in method 'foo'"
  end

  # NOTE: we don't support monomorphization (yet!)
  it 'raises an error if the method arg can have more than one type' do
    code = <<~CODE
      def foo(a)
        a
      end

      foo(1)

      foo('bar')
    CODE
    e = expect { compile(code) }.must_raise TypeError
    expect(e.message).must_equal "Argument 'a' in method 'foo' was called with more than one type: [:int, :str]"
  end
end
