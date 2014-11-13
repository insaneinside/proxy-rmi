require_relative('../proxy') unless ::Kernel::const_defined?(:Proxy) and ::Proxy.respond_to?(:require_relative)
Proxy.require_relative 'attributes'

module Proxy
  # Structured representation of a network message.
  module Message
    module Type
      LITERAL = 0
      PROXIED = 1
      LOCAL   = 2
      FETCH   = 3
      ERROR   = 4
      INVOKE  = 5
      RELEASE = 6
      BYE     = 7
      LIST_EXPORTS = 8

      @@vcmap = {}
      constants(false).each  { |c| @@vcmap[const_get(c)] = c }
      @@vsmap = {}
      constants(false).each { |c| @@vsmap[const_get(c)] = c.to_s.downcase.intern }

      def self.intern(value)
        raise TypeError.new('Value to intern must be an Integer (given `%s`)' %
                            value.inspect) unless value.kind_of?(Integer)
        @@vsmap[value]
      end

      def self.extern(sym)
        raise TypeError.new('Value to extern must be a Symbol') unless sym.kind_of?(Symbol)
        const_get(sym.to_s.upcase.intern)
      end

      def self.const_missing(sym)
        if sym.to_s =~ /\A[A-Z_]+\Z/
          value = constants(false).collect { |c| const_get(c) }.max + 1
          @@vsmap[value] = sym.downcase.intern
          @@vcmap[value] = sym.to_s.upcase.intern
          const_set(sym, value)
        else
          super
        end
      end
    end

    public
    # Classes of which instances will be copied rather than proxied.
    CopyableTypes = [ Bignum, Complex, FalseClass, File::Stat, Fixnum, Float,
                      Integer, MatchData, NilClass, Process::Status, Range,
                      Regexp, String, Symbol, TrueClass ]
    @type = nil
    @seq = nil

    # Optional message-sequence-ID or other message identifier.
    # @!attribute [r] seq
    #   @return [Object,nil]
    attr_reader(:seq)

    # Kind of value enclosed in the message.
    # @attribute [r] type
    #   @return [Symbol]
    def type
      Type.intern(@type)
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
    # @overload initialize(type, value, seq = nil)
    #
    #   Initializes as the given type of message with a specific value.
    #
    #   @param [Symbol] type Type of message to create.
    #   @param [Object] value Message's body.
    #   @param [Object] seq A transaction-ID or similar.
    def initialize(_type, _seq = nil)
      @type = _type.kind_of?(Symbol) ? Type.extern(_type) : _type
      $stderr.puts('WARNING: `%s` may not be a valid message type for %s' %
                   [_type, self.class.name]) if
        self.class.const_defined?(:VALID_TYPES) and
        not self.class.const_get(:VALID_TYPES).include?(@type)
      @seq = _seq
    end


    # Determine if an object can be sent by value.
    # @param [Object] val Value to test
    # @return [true,false] `true` if the object can be sent by value.
    # @see {CopyableTypes}
    def self.copyable?(val, attrs=nil)
      return true if
        val.kind_of?(Proxy::Object) or
        (val.kind_of?(Proxy::ObjectNode::ProxyArgument) and
         val.receiver_local?)
      attrs = Proxy.get_class_attributes(val.class) if attrs.nil?
      not attrs.include?(:nocopy) and
        ((val.class == Array and not val.collect {|x| copyable?(x) }.include?(false)) or
         (val.class == Hash and copyable?(val.keys) and copyable?(val.values)) or
         CopyableTypes.include?(val.class))
    end


    ## Create a result or value message.
    #
    # @param [Symbol] type either `:literal` or `:proxied`
    #
    # @param [Object] *rest Object or object-identifying data to export.
    def self.export(obj, opts = {})
      raise 'fixme' if obj.kind_of?(Symbol)
      if Message.copyable?(obj)
        GenericMessage.new(Type::LITERAL, {:value => obj}.merge(opts))
      else
        GenericMessage.new(Type::PROXIED, {:value => [obj.__id__, obj.class.name]}.merge(opts))
      end
    end

    # Create a release message.
    def self.release(obj, all=false)
      raise TypeError.new('We should not be creating a release message from anything except an Integer/Fixnum!') if
        not Integer === obj
      if all
        GenericMessage.new(Type::RELEASE, [obj, true])
      else
        GenericMessage.new(Type::RELEASE, obj)
      end
    end

    # Create an invocation-request message.
    def self.invoke(*a)#remote_id, symbol, args_array, block_obj, sequence = nil)
      InvokeMsg.new(*a)#remote_id, symbol, args_array, block_obj, sequence)
    end


    # Check if the message contains some sort of error object.
    def error?
      @type == Type::ERROR
    end

    # Check if this is a result or value message.
    def result?
      [Type::PROXIED, Type::LITERAL, Type::LOCAL].include?(@type)
    end

    # Check if this is a "release" command message.
    def release?
      @type == Type::RELEASE
    end

    def invocation?
      @type == Type::INVOKE
    end

    # Check if this is a proxied object message and must be registered with the
    # local ObjectNode before being sent.
    def must_register?
      @type == Type::PROXIED
    end
    alias_method :proxied?, :must_register?

    def self.included(mod)
      mod.send(:define_method, :==) do |other|
          ivs = instance_variables
          instance_variables == other.instance_variables and
            ivs.collect { |iv| instance_variable_get(iv) ==
              other.instance_variable_get(iv) }.all?
      end
    end
  end

  class GenericMessage
    include Message
    VALID_TYPES = [Type::PROXIED, Type::LITERAL, Type::LOCAL,
                   Type::FETCH, Type::RELEASE, Type::BYE,
                   Type::LIST_EXPORTS, Type::SHUTDOWN]
    @value = nil

    # Value that will be transmitted with the message.  This will _always_ be a
    # copyable type (see {Message.copyable?}, {Message::CopyableTypes}).
    #
    # @!attribute [r] value
    #   @return [Object]
    attr_reader(:value)


    # Initialize a new GenericMessage.
    #
    # @overload initialize(type)
    # @overload initialize(type, value)
    # @overload initialize(type, value, seq)
    def initialize(_type, opts = {})
      super(_type, opts[:seq])
      @value = opts[:value]
      raise TypeError.new('Cannot send a proxied OBJECT as a value!') if
        Proxy::Object === @value
    end


    # Enumerator specifying which values should be dumped by `::Marshal.dump`.
    def marshal_dump
      @value.nil? ? [@type, @seq] : [@type, @seq, @value]
    end

    # Restores a Message from from the values dumped by `::Marshal.dump`.
    # @see marshal_dump
    def marshal_load(ary)
      @type, @seq, @value = ary
    end


    def to_s
      @value.inspect
    end

    def inspect
      [ '#<%s:%#x' % [self.class,  self.object_id.abs],
        case @type
        when Message::Type::PROXIED
          '%s/0x%x' % (@value.reverse)
        else
          [type, @value.inspect].join(":")
        end].join(?:) +
        ( @seq.nil? ? "" : " (#{@seq.inspect})" ) +
        '>'
    end
  end


  # Special value-type used for method invocation requests.
  class InvokeMsg
    include Message
    VALID_TYPES = [Type::INVOKE]
    @id = nil
    @sym = nil
    @args = nil
    @block = nil
    attr_reader :id, :sym, :args, :block

    # Enumerator specifying which values should be dumped by `::Marshal.dump`.
    def marshal_dump
      [@seq, @id, @sym, @args, @block]
    end

    # Restores a Message from from the values dumped by `::Marshal.dump`.
    # @see marshal_dump
    def marshal_load(ary)
      @seq, @id, @sym, @args, @block = ary
      @type = Type::INVOKE
    end

    def initialize(_proxy_obj, symbol, args_array, block_obj, _seq = nil)
      super(Message::Type::INVOKE, _seq)
      @id = Integer === _proxy_obj ? _proxy_obj : _proxy_obj.proxy_id 
      @sym = symbol
      @args = args_array
      @block = block_obj
    end

    def to_s()
      # We look up the class name only when needed -- it turns out that looking
      # it up in `marshal_load` causes very significant slowdowns.
      if @proxy_class.nil?
        @proxy_class =
          begin
            ObjectSpace._id2ref(@id).class.name
          rescue
            '(unknown class)'
          end
      end

      "#<%s:0x%x>.%s(%s)" %
        [@proxy_class, @id, @sym.to_s,
         @args.collect { |a| a.kind_of?(Proxy::Object) \
             ? a.inspect(:PROXY_LOCAL_INSPECT) \
             : a.inspect }.join(', ')]
    end
    # alias :inspect :to_s
  end

  # Provides a Message encapsulation for exceptions.
  class ErrorMessage
    include Message
    VALID_TYPES = [Type::ERROR]

    @exception_class = nil
    @message = nil
    @backtrace = nil

    attr_reader(:exception_class)
    attr_reader(:message)
    attr_reader(:backtrace)


    # Enumerator specifying which values should be dumped by `::Marshal.dump`.
    def marshal_dump
      [@seq, @exception_class, @message, @backtrace]
    end

    # Restores an ErrorMessage from from the values dumped by `::Marshal.dump`.
    # @see marshal_dump
    def marshal_load(ary)
      @seq, @exception_class, @message, @backtrace = ary
      @type = Type::ERROR
    end

    def initialize(exception, bt_ignore, *rest)
      Message.instance_method(:initialize).bind(self).call(Message::Type::ERROR, *rest)
      @exception_class = exception.class.name
      @message = exception.message
      bt = exception.backtrace.clone
      bt_ignore.each do |ie|
        case ie
        when Array
          bt -= ie
        when Integer
          bt = bt[0...-(ie)]
        end
      end
      @backtrace = ErrorMessage.sanitize_local_backtrace(bt)
    end

    def self.sanitize_local_backtrace(ary)
      ary.collect { |el| el.sub(/[^ ]+\/(lib\/proxy.*)$/, '<...>/\1') }
    end

    def exception(local_backtrace = [])
      klass = Proxy.find_class_by_name(@exception_class)
      e = klass.new(@message)
      e.set_backtrace(@backtrace.collect { |l| l = l + ' (remote)' } | local_backtrace)
      e
    end      
  end
end
