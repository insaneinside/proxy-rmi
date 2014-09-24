module Proxy
  # Structured representation of a network message.
  class Message
    # Classes of which instances will be copied rather than proxied.
    CopyableTypes = [ Bignum, Complex, FalseClass, File::Stat, Fixnum, Float,
                      Integer, MatchData, NilClass, Process::Status, Range,
                      Regexp, String, Symbol, TrueClass ]
    DumpVarCount = 2

    @type = nil
    @note = nil
    @source_thread = nil

    # Thread in which the message was created.  This is currently used for
    # ProxyRMI diagnostic output only.
    #
    # @!attribute [r]
    #   @return [Thread]
    attr_reader(:source_thread)

    # Optional note about the value's significance.
    # @!attribute [r] note
    #   @return [String,nil]
    attr_reader(:note)

    # Kind of value enclosed in the message.
    # @!attribute [r] type
    #   @return [Symbol]
    attr_reader(:type)

    # Enumerator specifying which values should be dumped by `::Marshal.dump`.
    def marshal_dump
      raise self.inspect if @type.nil? and @note.nil?
      [@type, @note]
    end

    # Restores a Message from from the values dumped by `::Marshal.dump`.
    # @see marshal_dump
    def marshal_load(ary)
      @type, @note = ary
    end


    # Encoding method for DataMapper.
    def encode_with(out)
      out.map = {
        'type' => '!ruby/symbol ' + @type.inspect,
      }
      out['note'] = @note unless @note.nil?
    end



    # Determine if an object can be sent by value.
    # @param [Object] val Value to test
    # @return [true,false] `true` if the object can be sent by value.
    # @see {CopyableTypes}
    def self.copyable?(val, attrs=nil)
      attrs = ObjectNode.get_class_attributes(val.class) if attrs.nil?
      not attrs.include?(:nocopy) and
        case val
        when Array
          not val.collect {|x| copyable?(x) }.include?(false)
        when Hash
          val.kind_of?(Hash) and
            copyable?(val.keys) and
            copyable?(val.values)
        else
          CopyableTypes.include?(val.class)
        end
    end

    # Initialize a new Message instance.
    #
    # @overload initialize(object)
    #
    #   Initializes as a "value"-type message (i.e. either as a literal value
    #   or as a proxied object, as appropriate for the object's type (see
    #   {copyable?}, {CopyableTypes}).
    #
    #   @param [Object] object The object to export.
    #
    #
    # @overload initialize(type, value, note = nil)
    #
    #   Initializes as the given type of message with a specific value.
    #
    #   @param [Symbol] type Type of message to create.
    #   @param [Object] value Message's body.
    #   @param [Object] note A transaction-ID or similar.
    def initialize(_type, *rest)
      @source_thread = Thread.current
      @type = _type
      @note = nil
      opts = {}

      rest.
        select { |el| el.kind_of?(Hash) }.
        each { |hsh| rest.delete(hsh); opts.merge!(hsh) }
      @note = rest.shift || opts[:note]

      # $stderr.puts("#{self.class}::#{__method__}(): result = #{self}")
      self
    end

    ## Create a result or value message.
    #
    # @param [Symbol] type either `:literal` or `:proxied`
    #
    # @param [Object] note Object or object-identifying data to export.
    def self.export(type, obj, *rest)
      raise ArgumentError.new('Invalid export type `%s`' % type.inspect) unless [:literal, :proxied, :class].include?(type)
      GenericMessage.new(type, obj, *rest)
    end

    # Create a release message.
    def self.release(obj)
      raise TypeError.new('We should not be creating a release message from anything except an Integer/Fixnum!') if
        not Integer === obj
      GenericMessage.new(:release, obj)
    end

    # Create an invocation-request message.
    def self.invoke(remote_id, symbol, args_array, block_obj, note = nil)
      InvokeMsg.new(remote_id, symbol, args_array, block_obj, :note => note)
    end


    # Check if the message contains some sort of error object.
    def is_error?
      @type == :error
    end

    # Check if this is a result or value message.
    def is_result?
      [:proxied, :literal, :local].include?(@type)
    end

    # Check if this is a "release" command message.
    def is_release?
      @type == :release
    end

    # Check if this is a proxied object message and must be registered with the
    # local ObjectNode before being sent.
    def must_register?
      @type == :proxied
    end
    alias_method :is_proxied?, :must_register?
  end

  class GenericMessage < Message
    @value = nil

    # Value that will be transmitted with the message.  This will _always_ be a
    # copyable type (see {copyable?}, {CopyableTypes}).
    #
    # @!attribute [r] value
    #   @return [Object]
    attr_reader(:value)

    # Encoding method for DataMapper.
    def encode_with(out)
      out.map = {
        'type' => '!ruby/symbol ' + @type.inspect,
        'value' => @value }
      case @type
      when :literal, :proxied
        out['note'] = @note if not @note.nil?
      end
    end

    # Enumerator specifying which values should be dumped by `::Marshal.dump`.
    def marshal_dump
      super() + [@value]
    end

    # Restores a Message from from the values dumped by `::Marshal.dump`.
    # @see marshal_dump
    def marshal_load(ary)
      super(ary.slice!(0, Message::DumpVarCount))
      @value = ary[0]
    end

    def initialize(_type, _value = nil, *rest)
      super(_type, *rest)
      @value = _value
    end

    def to_s
      @value.inspect
    end

    def inspect
      [ "#<#{self.class}:#{'%#x' % self.object_id.abs}",
        case @type
        when :proxied
          @value.reverse.join(?/)
        else
          @value.inspect
        end].join(?:) +
        ( @note.nil? ? "" : " (note #{@note.inspect})" ) +
        '>'
    end
  end


  # Special value-type used for method invocation requests.
  class InvokeMsg < Message
    @proxy_klass = nil
    @id = nil
    @sym = nil
    @args = nil
    @block = nil
    attr_reader :id, :sym, :args, :block

    # Enumerator specifying which values should be dumped by `::Marshal.dump`.
    def marshal_dump
      super() + [@id, @sym, @args, @block]
    end

    # Restores a Message from from the values dumped by `::Marshal.dump`.
    # @see marshal_dump
    def marshal_load(ary)
      super(ary.slice!(0, Message::DumpVarCount))
      @id, @sym, @args, @block = ary
      @proxy_klass = ObjectSpace._id2ref(@id).class.name
    end

    def initialize(_proxy_obj, symbol, args_array, block_obj, *rest)
      super(:invoke, *rest)
      begin
        @id = _proxy_obj.proxy_id
        @proxy_klass = _proxy_obj.proxy_class
        @sym = symbol
        @args = args_array
        @block = block_obj
      rescue SystemStackError => err
        $stderr.puts(err.inspect)
        $stderr.puts(err.backtrace.join("\n"))
      end
    end

    def to_s()
      "#<%s:0x%x>.#{@sym.to_s}(#{@args.collect { |a| a.inspect }.join(', ')})" % [@proxy_klass, @id]
    end
    alias :inspect :to_s
  end

  class ErrorMessage < Message
    @exception_class = nil
    @message = nil
    @backtrace = nil

    attr_reader(:exception_class)
    attr_reader(:message)
    attr_reader(:backtrace)


    # Enumerator specifying which values should be dumped by `::Marshal.dump`.
    def marshal_dump
      super() + [@exception_class, @message, @backtrace]
    end

    # Restores a Message from from the values dumped by `::Marshal.dump`.
    # @see marshal_dump
    def marshal_load(ary)
      super(ary.slice!(0, Message::DumpVarCount))
      @exception_class, @message, @backtrace = ary
    end

    def initialize(exception, *rest)
      super(:error, *rest)
      @exception_class = exception.class.name
      @message = exception.message
      @backtrace = exception.backtrace
    end

    def exception
      klass = Module.const_get(@exception_class.intern)
      e = klass.new(@message)
      e.set_backtrace(@backtrace)
      e
    end      
  end
end
