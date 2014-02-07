require 'yaml'

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
    # Reference holder for local objects proxied to the other end of the connection.  
    ObjectReference = Struct.new(:obj, :refcount)

    # Object-reference hash.
    @object_references = nil


    @last_pong_time = nil
    @ping_thread = nil

    # Initialize a new object-proxy node.
    #
    # @param [IO,Socket] socket The stream to use for communication.
    #
    # @param [Boolean] verbose Whether we should verbosely report message-passing activity.
    def initialize(socket, verbose = false)
      # $stderr.puts("#{self}.#{__method__}(#{socket})")
      super(socket, verbose)
      @object_references = {}
      @last_pong_time = nil
      ObjectSpace.define_finalizer(self, proc { |id|
                                     if not socket.closed?
                                       begin
                                         m = Marshal.dump(Message.new(:bye))
                                         socket.sendmsg([m.length].pack('N') + m)
                                       rescue Errno::EPIPE
                                       ensure
                                         socket.close()
                                       end
                                     end})
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
      # $stderr.puts("#{self}.#{__method__}(#{ei})")
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
        register(arg.value)
      else
        raise ArgumentError.new('Attempt to register unknown object!')
      end
      arg
    end

    # Release a remote object.
    # @param [Integer,Proxy::Object] id Proxied object or remote object ID.
    def release(id)
      $stderr.puts("#{self}.#{__method__}(#{id})")
      case id
      when Integer
        send_message(Message.release(id))
      when Proxy::Object
        send_message(Message.release(proxy_id))
      end
    end

    # De-reference a local object.
    # @param [Integer] id Object-id of a local object that is to be de-referenced.
    def release_local(id)
      raise ArgumentError.new('Attempt to release non-exported object!') if not @object_references.has_key?(id)
      ref = @object_references[id]
      ref.refcount -= 1
      if ref.refcount <= 0
        $stderr.puts("Dropping reference to ID #{obj}")
        @object_references.delete(obj)
      end
    end

    # Ready a local object for transmission to the node's peer.  If the object is copy-safe, we
    # send a copy -- otherwise we send a proxy.
    #
    # @param [Object] obj Object to send
    #
    # @param [String,nil] note A note indicating what the contained value is.
    #
    # @return [Proxy::Message] A message ready to send to the remote node.
    def export(obj, note = nil)
      # $stderr.print("#{self}.#{__method__}(#{obj}) ") if @verbose      
      m = Message.export(obj, note)
      register(m) if m.must_register?
      # $stderr.puts("=> #{m}") if @verbose
      m
    end

    # Import an object contained in a Proxy message.
    #
    # @param [Proxy::Message] msg Message from which to import.
    # @return [Proxy::Object,Object] A proxied or copied object.
    def import(msg)
      $stderr.puts("#{self}.#{__method__}(#{msg})") if @verbose
      if msg.must_register?
        Proxy::Object.new(self, msg.value)
      else
        msg.value
      end
    end

    # Invoke a method on a remote object.
    #
    # @param [Integer] id Remote object ID
    # @param [Symbol] sym Method to invoke.
    # @param [Array] args Object
    # @return Result of the remote method call.
    def invoke(id, sym, args, block)
      $stderr.puts("#{self}.#{__method__}: #<0x%x>.#{sym.to_s}(#{args.join(', ')})" % id) if @verbose
      send_message(Message.invoke(id, sym, args, block ? export(block) : nil))
      msg = wait_for_message(:note => id)

      case msg.type
      when :literal
        msg.value
      when :proxied
        import(msg)
      when :error
        raise msg.value
      else
        msg.value
      end
    end

    # Close the node's connection to the remote host.
    def close()
      send_message(Message.new(:bye), true)
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
        raise(import(msg))
        true

      when :literal, :proxied
        import(msg)
        
      when :bye
        send_message(Message.new(:bye_ACK), true)
        $stderr.puts("[#{self}] Received \"bye\" message: shutting down.") if @verbose
        close()
        true

      when :bye_ACK
        true

      when :invoke
        obj = @object_references[msg.value.id].obj
        $stderr.puts("[#{self}] Invoking #{obj}.#{msg.value.sym.to_s}(#{msg.value.args.collect { |a| a.inspect }.join(', ')})") if @verbose
        result = nil
        begin
          raise 'That\'s not an exported object!' if not @object_references.has_key?(msg.value.id)
          result = export(obj.public_send(msg.value.sym, *(msg.value.args), &(msg.value.block)), msg.value.id)
        rescue => e
          result = Message.new(:error,
                               if not e.kind_of?(Exception)
                                 RuntimeError.new(e)
                               else
                                 e
                               end)
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
