require_relative('../proxy') unless ::Kernel::const_defined?(:Proxy) and ::Proxy.respond_to?(:require_relative)
Proxy.require_relative('MessagePasser')

require 'atomic'

module Proxy
  # Encapsulates the object-proxy functionality for each end of a client-server
  # connection.  It mediates data-sharing and remote reference-counting.
  #
  # ObjectNode is comparable to dRuby's `DrbServer`; however unlike with dRuby, there is no need
  # to start one explicitly (since one necessarily exists to enable remote method-calls from
  # local references).  Also unlike dRuby, calls to remote methods are performed via
  # `public_send`, ensuring that method visibility is preserved.
  class ObjectNode < MessagePasser
    # Reference holder for local objects proxied to the other end of the
    # connection.  This is the local equivalent of Proxy::Object, although it
    # is used only within ObjectNode.
    #
    # ObjectReference fetches and stores the method-attributes hash for the
    # object's class to reduce the number of hash lookups at each method call.
    #
    # @internal
    class ObjectReference
      attr_reader :object
      attr_reader :method_attributes
      attr_accessor :refcount

      def initialize(_object, _refcount=0)
        @object = _object
        @refcount = _refcount
        # @method_attributes = ::Proxy.get_method_attributes(_object.class)
      end
    end

    # Simple remote-object reference used when passing parameters to remote
    # methods.  The class exists solely to differentiate proxied-argument ID
    # values from normal integer arguments.
    class ProxyArgument
      @id = nil
      @receiver_local = nil

      attr_reader(:id)

      # Whether the value in `id` refers to an object in the receiver's
      # object space.
      #
      # @attribute [r]
      #   @return [Boolean]
      def receiver_local?
        @receiver_local
      end

      def initialize(_id, _receiver_local = false)
        @id = _id
        @receiver_local = _receiver_local
      end

      def marshal_dump
        [@id, @receiver_local]
      end

      def marshal_load(ary)
        @id, @receiver_local = ary
      end

      def import(node)
        @receiver_local \
          ? ObjectSpace._id2ref(@id) \
          : Object.new(node, @id, nil)
      end

      def inspect
        '#<%s:0x%x:%s%s/%x>' % [self.class.name, self.__id__,
          @receiver_local ? 'local:' : '',
          begin
            ObjectSpace._id2ref(id).class.name
          rescue
            '(unknown class)'
          end, id]
      end
    end

    # Object-reference hash.
    @object_references = nil

    # Initialize a new object-proxy node.
    #
    # @overload initialize(klass, *args, **opts)
    #   @param [#new] klass An IO-like class to be instantiated for communication.
    #   @param [Array<Object>] args Arguments to pass to `klass.new`.
    #   @param [Hash] opts Options hash to pass to {MessagePasser#new}.
    #
    # @overload initialize(stream, verbose=false)
    #   @param [IO,Array<IO>] stream The stream or streams to use for communication.
    #   @param [Hash] opts Options hash to pass to {MessagePasser#new}.
    #
    # @see MessagePasser#set_streams for information on the requirements placed
    #     on the communication streams.
    def initialize(*args, **opts)
      f = args.first
      if f.kind_of?(IO) or f.kind_of?(Array)
        super(*args, **opts)
      elsif f.respond_to?(:new)
        args.shift
        super(f.new(*args), **opts)
      else
        raise ArgumentError.new("Don't know what to do with arguments: #{args.inspect}")
      end

     @object_references = {}
    end

    # Close the node's connection to the remote host.
    def close(reason=nil)
      if connection_open?
        begin
          @object_references.each_value { |ref| release(ref.object, true) }
          @object_references.clear()
          if reason.nil?
            send_message(GenericMessage.new(:bye))
          else
            send_message(GenericMessage.new(:bye, reason))
          end
        rescue Errno::EBADF, Errno::EPIPE
        end
      end
      super()
    end


    private
    # Prepare an item for export to remote nodes by saving an ObjectReference to it to prevent
    # premature garbage collection.
    #
    # @overload register(message)
    #
    #   Register an object by direct reference.
    #
    #   @param [Message] message The pre-exported item to process.
    #
    #   @return [Message] `message`
    #
    # @overload register(id)
    #
    #   Register an object by ID.  The actual object reference will be fetched automatically via
    #   `ObjectSpace._id2ref`.
    #
    #   @param [Integer] id ID of the local object being exported.
    #
    #   @return [Integer] `id`
    def register(arg)
      $stderr.puts("#{self}.#{__method__}(#{arg.inspect})") if @verbose
      case arg
      when Integer
        if not @object_references.has_key? arg
          @object_references[arg] = ObjectReference.new(ObjectSpace._id2ref(arg), 1)
        else
          @object_references[arg].refcount += 1
        end

      when Message
        raise ArgumentError.new('Attempt to register non-exported object!') if
          arg.type != :proxied
        register(arg.value[0])
      else
        raise ArgumentError.new('Attempt to register unknown object: `%s`'%arg.inspect)
      end
      arg
    end

    # Release a remote object.
    # @param [Integer,Proxy::Object] id Proxied object or remote object ID.
    def release(id, all=false)
      $stderr.puts("#{self}.#{__method__}(#{id})") if @verbose
      case id
      when Integer
        send_message(Message.release(id, all))
      when Proxy::Object
        send_message(Message.release(id.proxy_id, all))
      end
    end

    # De-reference a local object.
    # @param [Integer] id Object-id of a local object that is to be de-referenced.
    def release_local(id, all=false)
      raise ArgumentError.new('Attempt to release non-exported object!') if not @object_references.has_key?(id)
      ref = @object_references[id]
      ref.refcount -= 1
      if ref.refcount <= 0 or all == true
        $stderr.puts("Dropping reference to ID #{obj}") if @verbose
        @object_references.delete(id)
      end
    end


    # Ready a local object for transmission to the node's peer.  If the object is copy-safe, we
    # send a copy -- otherwise we send a proxy.
    #
    # @param [Object] obj Object to send
    #
    # @return [Proxy::Message] A message ready to send to the remote node.
    def export(obj, seq)
      if obj.kind_of?(Message)
        obj
      else
        m =
          if Proxy::Object === obj and obj.proxy_client == self
            GenericMessage.new(:local, :value => obj.proxy_id, :seq => note)
          else
            Message.export(obj, :seq => seq)
          end
        register(m) if m.must_register?
        m
      end
    end


    # Import an object contained in a Proxy message.
    #
    # @param [Proxy::Message] msg Message from which to import.
    # @return [Proxy::Object,Object] A proxied or copied object.
    def import(msg)
      raise msg.inspect unless msg.kind_of?(Message)
      raise msg.inspect unless [:literal, :proxied, :class].include?(msg.type)

      case msg.type
      when :proxied
        Proxy::Object.new(self, *(msg.value))
      when :literal
        msg.value
      end
    end

    def export_argument(x)
      if Proxy::Object === x and x.proxy_client == self
        ProxyArgument.new(x.proxy_id, true)
      elsif Message.copyable?(x)
        x
      else
        o = ProxyArgument.new(x.__id__)
        register(o.id)
        o
      end
    end

    def import_argument(a)
      ProxyArgument === a ? a.import(self) : a
    end


    # Invoke a method on a remote object.
    #
    # @param [Proxy::Object] obj Local proxied object reference.
    # @param [Symbol] sym Method to invoke.
    # @param [Array] args Object
    # @return Result of the remote method call.
    def invoke(obj, sym, args, block, attrs = nil)
      msg_id = @message_sequence.value
      msg = Message.invoke(obj, sym,
                           args.collect { |a| export_argument(a) },
                           block ? export_argument(block) : nil, msg_id)

      if @verbose
        transaction(msg_id) do
          if attrs.kind_of?(Array) and attrs.include?(:noreturn)
            send_message(msg, msg_id)
            true
          else
            handle_message(send_message_and_wait(msg, msg_id))
          end
        end
      else
        if attrs.kind_of?(Array) and attrs.include?(:noreturn)
          send_message(msg, msg_id)
          true
        else
          handle_message(send_message_and_wait(msg, msg_id))
        end
      end
    end


    # Invoke a method on a local object as specified in a message.
    #
    # @param [InvokeMessage] msg The received invocation request.
    # @return [] The result of the invocation.
    def perform_local_invocation(msg)
      obj = @object_references[msg.id].object
      args = msg.args.collect { |a| import_argument(a) }
      begin
        q = if not msg.block.nil?
              _block = import_argument(msg.block)
              obj.public_send(msg.sym, *args, &_block)
            else
              obj.public_send(msg.sym, *args)
            end
        export(q, msg.seq)
      rescue => e
        ErrorMessage.new(e, [caller(), 2], msg.seq)
      end
    end

    public
    # Handle a message sent to this object node from the remote peer by performing an action
    # appropriate to the message's contents.
    #
    # @param [Proxy::Message] msg The message to handle.
    #
    # @return [Boolean] `true` if we were able to handle the message, and `false` otherwise.
    def handle_message(msg)
      raise RuntimeError.new("Invalid `nil` message!") if msg.nil? or msg.type.nil?
      case msg.type
      when :invoke
        # transaction(msg.note) do
        raise SecurityError.new('Illegal invocation request on non-exported object: %s' % msg.inspect) \
          unless @object_references.has_key?(msg.id)
          # ref = @object_references[msg.id]
          # attrs = ref.method_attributes.nil? ? [] : ref.method_attributes[msg.sym]
          # if ! attrs.nil? and attrs.include?(:noreturn)
          #   send_message(export(nil, msg.note))
          #   perform_local_invocation(msg)
          # else
            result = perform_local_invocation(msg)
            send_message(result) if connection_open? and not stopping?
          # end
        # end if not stopping?
        true

      when :error
        raise msg.exception(caller())
        true

      when :literal, :proxied
        # This case is special w.r.t. return value: `handle_message` was called
        # by the initiator of a transaction, with the remote node's response to
        # the initiating message (`handle_message` is a better choice than
        # `import` because that response could have had type `:error`).
        import(msg)

      when :local
        @object_references[msg.value].object

      when :bye
        $stderr.puts("[#{self}] Received \"bye\" message: shutting down.") if @verbose
        close()
        true

      when :release
        if msg.value.kind_of?(Array)
          release_local(*(msg.value))
        else
          release_local(msg.value)
        end
        true

      else
        false
      end
    end

    public
    def inspect
      "#<#{self.class}:#{'%#x' % self.object_id.abs}>"
    end
  end                           # class ObjectNode
end                             # module Proxy
