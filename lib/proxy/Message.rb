module Proxy

    # Special value-type used for method invocation requests.
    class InvokeMsg
      @id = nil
      @sym = nil
      @args = nil
      @block = nil
      attr_reader :id, :sym, :args, :block
      def initialize(_remote_id, symbol, args_array, block_obj)
        begin
          @id = _remote_id
          @sym = symbol
          @args = args_array
          @block = block_obj
        rescue SystemStackError => err
          $stderr.puts(err.inspect)
          $stderr.puts(err.backtrace.join("\n"))
        end
      end
    end

  # Structured representation of a network message.
  class Message
    #  Classes of which instances will be copied rather than proxied.
    CopyableTypes = [ Bignum, Complex, FalseClass, File::Stat, Fixnum, Float, Integer,
                      MatchData, NilClass, Process::Status, Range, Regexp, String, TrueClass,
                      Exception ]

    @type = nil
    @value = nil
    @raw_value = nil
    @note = nil

    # Optional note about the value's significance.
    # @!attribute [r] note
    #   @return [String,nil]
    attr_reader :note

    # Kind of value enclosed in the message.
    # @!attribute [r] type
    #   @return [Symbol]
    attr_reader(:type)

    # Value that will be transmitted with the message.  This will _always_ be a copyable type (see
    # {is_copyable?}, {CopyableTypes}).
    #
    # @!attribute [r] value
    #   @return [Object]
    attr_reader(:value)

    # Original, unexported value.
    # @!attribute [r] raw_value
    #   @return [Object]
    attr_reader(:raw_value)

    # Encoding method for DataMapper.
    def encode_with(out)
      out.map = { 'type' => '!ruby/symbol ' + @type.inspect, 'value' => @value }
      case @type
      when :literal, :proxied
        out['note'] = @note if not @note.nil?
      end
    end

    # Determine if an object can be sent by value.
    # @param [Object] val Value to test
    # @return [true,false] `true` if the object can be sent by value.
    # @see {CopyableTypes}
    def self.is_copyable?(val)
      (val.kind_of?(Array) and not val.collect {|x| is_copyable?(x) }.include?(false)) or
        (val.kind_of?(Hash) and is_copyable?(val.keys) and is_copyable?(val.values)) or
        CopyableTypes.include?(val.class)
    end

    # Enumerator specifying which values should be dumped by `::Marshal.dump`.
    def marshal_dump
      [@type, @value, @note]
    end

    # Restores a Message from from the values dumped by `::Marshal.dump`.
    # @see marshal_dump
    def marshal_load(ary)
      @type, @value, @note = ary
    end

    # Initialize a new Message instance.
    #
    # @overload initialize(object)
    #
    #   Initializes as a "value"-type message (i.e. either as a literal value or as a proxied
    #   object, as appropriate for the object's type (see {is_copyable?}, {CopyableTypes}).
    #
    #   @param [Object] object The object to export.
    #    
    #
    # @overload initialize(type, value)
    #
    #   Initializes as the given type of 
    def initialize(a, b = nil, note = nil)
      @note = note
      case a
      when Symbol
        @type = a
        @value = Message.is_copyable?(b) ? b : 
        @raw_value = b
      else
        @raw_value = a
        if Message.is_copyable?(a)
          @type = :literal
          @value = @raw_value if not @raw_value.nil?
        else
          @type = :proxied
          @value = @raw_value.__id__
        end
      end
      # $stderr.puts("#{self.class}::#{__method__}(): result = #{self}")
      self
    end

    # Create a result or value message.  
    def self.export(obj, note = nil)
      new(obj, nil, note)
    end

    # Create a release message.
    def self.release(obj)
      raise TypeError.new('We should not be creating a release message from anything except an Integer/Fixnum!') if
        not Integer === obj
      new(:release, obj)
    end

    # Create an invocation-request message.
    def self.invoke(remote_id, symbol, args_array, block_obj)
      new(:invoke, InvokeMsg.new(remote_id, symbol, args_array, block_obj))
    end


    # Check if the message contains some sort of error object.
    def is_error?
      @type == :error
    end

    # Check if this is a result or value message.
    def is_result?
      [:proxied, :literal].include?(@type)
    end

    # Check if this is a "release" command message.
    def is_release?
      @type == :release
    end

    # Check if this is a proxied object message and must be registered with the local ObjectNode
    # before being sent.
    def must_register?
      @type == :proxied
    end
    alias_method :is_proxied?, :must_register?

    def inspect
      to_s
    end

    def to_s
      sup = super()
      [ sup[0..-2], @type.to_s, @value.inspect ].join(?:) +
        ( @note.nil? ? "" : " (note #{@note.inspect})" ) +
        '>'
    end
  end
end
