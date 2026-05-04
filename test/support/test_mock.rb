# Minimal Mock object used by tests. Minitest 6 dropped Minitest::Mock; this
# preserves the small subset of the Mock API our tests depend on.

class MockExpectationError < StandardError; end

module Minitest
  class Mock
    def initialize
      @expectations = Hash.new { |h, k| h[k] = [] }
      @actual_calls = Hash.new(0)
    end

    # expect(name, retval)                - no args expected
    # expect(name, retval, [arg1, arg2])  - positional args
    # expect(name, retval, kw: val)       - keyword args
    def expect(name, retval, args = [], **kwargs)
      @expectations[name] << { args: args, kwargs: kwargs, retval: retval }
      self
    end

    def verify
      @expectations.each do |name, expects|
        actual = @actual_calls[name]
        if actual < expects.length
          raise MockExpectationError, "expected #{name} to be called #{expects.length} times, got #{actual}"
        end
      end
      true
    end

    def respond_to_missing?(_name, _include_private = false) = true

    def method_missing(name, *args, **kwargs, &_block)
      expects = @expectations[name]
      idx = @actual_calls[name]
      raise MockExpectationError, "unexpected call to #{name}" if expects.empty? || idx >= expects.length

      expectation = expects[idx]
      expected_args = expectation[:args]
      expected_kwargs = expectation[:kwargs]

      if expected_args != args
        raise MockExpectationError, "#{name} expected args #{expected_args.inspect}, got #{args.inspect}"
      end
      if expected_kwargs != kwargs
        raise MockExpectationError, "#{name} expected kwargs #{expected_kwargs.inspect}, got #{kwargs.inspect}"
      end

      @actual_calls[name] = idx + 1
      expectation[:retval]
    end
  end
end

class Object
  # Temporarily replace method +name+ with one that returns
  # +val_or_callable+ for the duration of +block+. Mirrors the
  # Minitest 5 +Object#stub+ extension we lost when upgrading to
  # Minitest 6 (which dropped Mock and stubbing entirely).
  def stub(name, val_or_callable, &block)
    new_name = "__test_stub__#{name}"
    metaclass = class << self; self; end

    if respond_to?(name) && !methods.map(&:to_s).include?(name.to_s)
      metaclass.send :define_method, name do |*args, **kwargs|
        super(*args, **kwargs)
      end
    end

    metaclass.send :alias_method, new_name, name
    metaclass.send :define_method, name do |*args, **kwargs, &blk|
      if val_or_callable.is_a?(Proc) || val_or_callable.is_a?(Method)
        val_or_callable.call(*args, **kwargs, &blk)
      else
        val_or_callable
      end
    end

    block.call(self)
  ensure
    metaclass.send :undef_method, name
    metaclass.send :alias_method, name, new_name
    metaclass.send :undef_method, new_name
  end
end
