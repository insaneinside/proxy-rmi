module IINet
  module Util

    # TimeTable provides an easy way to time different parts of processes.
    class TimeTable
      # An individual action recorded by TimeTable.
      Action = Struct.new(:sym, :description, :time)
      Action.send(RUBY_VERSION >= '1.9.1' ? :define_singleton_method : :define_method,
                  *[:to_s, proc { '%s %.05fs' % [ (self.description||self.sym.to_s).downcase, self.time ] } ])
      Action.send(:public, :to_s)
      @actions = nil
      @verbose = nil

      # Fetch the actions recorded by this TimeTable object.
      # @!attribute [r] actions
      #   @return [Hash<Symbol, Action>]
      attr_reader :actions

      def initialize(verbose = false)
        @actions = Hash.new { |hsh, key| hsh[key] = Action.new(key, nil, nil) }
        @verbose = verbose
      end

      def clear()
        @actions.clear()
      end

      def total
        out = 0.0
        @actions.each_value { |v| out += v.time }
        out
      end

      def time(sym, description = nil, &block)
        $stderr.print(description + '... ') if @verbose and not description.nil?

        t0 = Time.now
        o = block.call()
        t1 = Time.now
        delta = t1 - t0
        $stderr.puts('%.05f s' % delta) if @verbose and not description.nil?

        @actions[sym] = Action.new(sym, description, delta)
        o
      end
    end
  end
end
