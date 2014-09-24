['Message', 'Object', 'MessagePasser'].each { |n| Proxy.require File.expand_path('../' + n, __FILE__) }

module Proxy
  # Encapsulates the object-proxy functionality for each end of a client-server
  # connection.  It mediates data-sharing and remote reference-counting.
  #
  # ObjectNode is comparable to dRuby's `DrbServer`; however unlike with dRuby, there is no need
  # to start one explicitly (since one necessarily exists to enable remote method-calls from
  # local references).  Also unlike dRuby, calls to remote methods are performed via
  # `public_send`, ensuring that method visibility is preserved.
  class ObjectNode < MessagePasser
    @@method_attributes_table = Hash.new(Hash.new([]))
    @@class_attributes_table = Hash.new([])

    def self.set_class_attributes(klass, attrs)
      @@class_attributes_table[klass] = attrs
    end
    public_class_method :set_class_attributes

    def self.get_class_attributes(klass)
      o = []
      klass.ancestors.each do |k|
        o += @@class_attributes_table[k] if @@class_attributes_table.has_key?(k)
      end
      o
    end

    # Set attributes on a specific method.
    def self.set_method_attributes(klass, method, attrs)
      klass = klass.name if klass.kind_of?(Class)
      @@method_attributes_table[klass][method] = attrs
    end
    public_class_method :set_method_attributes

    def self.get_method_attributes(klass, method)
      klass = klass.name if klass.kind_of?(Class)
      @@method_attributes_table[klass][method]
    end

    set_class_attributes(::Exception, [:nocopy])
    set_class_attributes(::Proc, [:nocopy])


    # Reference holder for local objects proxied to the other end of the connection.
    ObjectReference = Struct.new(:obj, :refcount)

    # Object-reference hash.
    @object_references = nil


    # Value to use for the next outgoing-message note (identifier) [e.g. so we
    # can wait for the reply]
    @next_message_id = nil
    @next_message_id_mutex = nil


    # Initialize a new object-proxy node.
    #
    # @overload initialize(klass, *args, verbose=false)
    #   @param [Class] klass A subclass of IO to be instantiated for communication.
    #   @param [Object] args Arguments to pass to `klass.new`.
    #
    # @overload initialize(stream, verbose=false)
    #   @param [IO,Array<IO>] stream The stream or streams to use for communication.
    #   @param [Boolean] verbose Whether we should verbosely report message-passing activity.
    def initialize(*s)
      if s[0].kind_of?(IO) or s[0].kind_of?(Array)
        super(*s)
      elsif s[0].respond_to?(:ancestors) and s[0].ancestors.include?(IO)
        verbose = false
        verbose = s.pop if s[-1].kind_of?(FalseClass) or s[-1].kind_of?(TrueClass)
        super(s[0].new(*s[1..-1]), verbose)
      else
        raise ArgumentError.new("Don't know what to do with arguments: #{s.inspect}")
      end

      # $stderr.puts("#{self}.#{__method__}(#{socket})")
      @object_references = {}

      @next_message_id = 0
      @next_message_id_mutex = Mutex.new
    end

    def next_message_id()
      value = nil
      @next_message_id_mutex.synchronize do
        value = @next_message_id
        @next_message_id += 1
      end
      value
    end

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
      $stderr.puts("#{self}.#{__method__}(#{arg})") if @verbose
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
        raise ArgumentError.new('Attempt to register unknown object!')
      end
      arg
    end

    # Release a remote object.
    # @param [Integer,Proxy::Object] id Proxied object or remote object ID.
    def release(id)
      $stderr.puts("#{self}.#{__method__}(#{id})") if @verbose
      case id
      when Integer
        send_message(Message.release(id))
      when Proxy::Object
        send_message(Message.release(id.proxy_id))
      end
    end

    # De-reference a local object.
    # @param [Integer] id Object-id of a local object that is to be de-referenced.
    def release_local(id)
      raise ArgumentError.new('Attempt to release non-exported object!') if not @object_references.has_key?(id)
      ref = @object_references[id]
      ref.refcount -= 1
      if ref.refcount <= 0
        $stderr.puts("Dropping reference to ID #{obj}") if @verbose
        @object_references.delete(obj)
      end
    end


    # Ready a local object for transmission to the node's peer.  If the object is copy-safe, we
    # send a copy -- otherwise we send a proxy.
    #
    # @param [Object] obj Object to send
    #
    # @return [Proxy::Message] A message ready to send to the remote node.
    def export(obj, *rest)
      # $stderr.print("#{self}.#{__method__}(#{obj}) ") if @verbose
      if obj.kind_of?(Message)
        obj
      else
        m =
          if Proxy::Object === obj and obj.proxy_client == self
            GenericMessage.new(:local, obj.proxy_id, *rest)
          elsif obj.kind_of?(Proxy::Notifier)
            export(obj.wait(), *rest)
          elsif Message.copyable?(obj)
            Message.export(:literal, obj, *rest)
          elsif obj.kind_of?(Class)
            Message.export(:class, obj.name, *rest)
          else
            Message.export(:proxied, [obj.__id__, obj.class.name], *rest)
          end
        register(m) if m.must_register?
        # $stderr.puts("=> #{m}") if @verbose
        m
      end
    end


    # Import an object contained in a Proxy message.
    #
    # @param [Proxy::Message] msg Message from which to import.
    # @return [Proxy::Object,Object] A proxied or copied object.
    def import(msg)
      case msg
      when Message
        # $stderr.puts("#{self}.#{__method__}(#{msg})") if @verbose
        raise msg.inspect unless [:literal, :proxied, :class].include?(msg.type)
        if msg.type == :proxied
          Proxy::Object.new(self, *(msg.value))
        elsif msg.type == :class
          ref = Module
          msg.value.split('::').each do |part|
            ref = ref.const_get(part.intern)
          end
          raise TypeError('Referred type `%s` is undefined' % msg.value) unless ref.name == msg.value
          ref
        else
          msg.value
        end
      else
        msg
      end
    end


    # Invoke a method on a remote object.
    #
    # @param [Integer] id Remote object ID
    # @param [Symbol] sym Method to invoke.
    # @param [Array] args Object
    # @return Result of the remote method call.
    def invoke(id, sym, args, block, attrs = nil)
      $stderr.puts("#{self}.#{__method__}: #<0x%x>.#{sym.to_s}(#{args.collect { |a| a.inspect }.join(', ')})" % id) if @verbose

      msg_id = next_message_id()

      msg = Message.invoke(id, sym, args.collect { |a| export(a) }, block ? export(block) : nil, msg_id)


      if attrs.kind_of?(Array) and attrs.include?(:noreturn)
        send_message(msg)
        return true
      else
        rmsg = send_message_and_wait(msg, :note => msg_id)
        handle_message(rmsg)
      end
    end

    # Close the node's connection to the remote host.
    def close(reason=nil)
      send_message(GenericMessage.new(:bye, nil, reason.nil? ? nil : { :note => reason }), true) if connection_open?
      @object_references.clear()
      super()
    end

    # Handle a message sent to this object node from the remote peer by performing an action
    # appropriate to the message's contents.
    #
    # @param [Proxy::Message] msg The message to handle.
    #
    # @return [Boolean] `true` if we were able to handle the message, and `false` otherwise.
    def handle_message(msg)
      raise RuntimeError.new("Invalid `nil` message!") if msg.nil?
      case msg.type
      when :error
        raise msg.exception
        true

      when :literal, :proxied
        # This case is special w.r.t. return value: `handle_message` was called
        # by the initiator of a transaction, with the remote node's response to
        # the initiating message (`handle_message` is a better choice than
        # `import` because that response could have had type `:error`).
        import(msg)

      when :local
        @object_references[msg.value].obj

      when :bye
        $stderr.puts("[#{self}] Received \"bye\" message: shutting down.") if @verbose
        close()
        true

      when :bye_ACK
        true

      when :invoke
        result = nil
        begin
          raise 'That\'s not an exported object!' if not @object_references.has_key?(msg.id)
          obj = @object_references[msg.id].obj
          # $stderr.puts("[#{self}] Invoking #{obj}.#{msg.sym.to_s}(#{msg.args.collect { |a| a.inspect }.join(', ')})") if @verbose
          args = msg.args.collect { |a| import(a) }

          if not msg.block.nil?
            block = import(msg.block)
            result = export((q = obj.public_send(msg.sym, *args, &proc { |*a| block.call(*a) })),
                            :attributes => (ObjectNode.get_method_attributes(obj.class, msg.sym) |
                                            ObjectNode.get_class_attributes(q.class)),
                            :note => msg.note)
          else
            result = export((q = obj.public_send(msg.sym, *args)),
                            :attributes => (ObjectNode.get_method_attributes(obj.class, msg.sym) |
                                            ObjectNode.get_class_attributes(q.class)),
                            :note => msg.note)
          end
        rescue => e
          result = ErrorMessage.new(e, :note => msg.note)
        end
        send_message(result)
        true

      when :release
        release_local(msg.value)
        true

      else
        false
      end
    end
  end                           # class ObjectNode
end                             # module Proxy
