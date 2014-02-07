require 'thread'

module Proxy
  # Cross-thread event notification utility.  Notifier uses an internal Mutex/ConditionVariable
  # pair to facilitate notification of events and communication of values across threads.
  class Notifier
    @result = nil
    @mutex = nil
    @condition_variable = nil

    # Initialize the notifer's internal machinery.
    def initialize()
      @result = nil
      @mutex = Mutex.new
      @condition_variable = ConditionVariable.new
    end

    # Notify any threads waiting on this object, optionally with a result value.
    #
    # @param [Object,nil] arg An optional value that will be returned from waiting threads'
    #     calls to `wait`.
    def signal(arg = nil)
      @mutex.synchronize do
        @result = arg
        @condition_variable.signal
      end
    end

    # Wait for another thread to call `signal` on this object.
    #
    # @return [Object,nil] Any argument passed to the call to `signal` that wakes the current
    #     thread.
    def wait
      @mutex.synchronize do
        @condition_variable.wait(@mutex)
        @result
      end
    end
  end

  # A queued outgoing message.
  class OutgoingMessage < Notifier
    @data = nil

    # Serialized message data.
    # @!attribute [r] data
    #   @return [String]
    attr_reader :data

    # Initialize an OutgoingMessage object.
    #
    # @param [Proxy::Message,String] msg The Message object being queued, or a string acquired
    #     by calling `Marshal.dump` on the same.
    def initialize(msg)
      super()
      case msg
      when Proxy::Message
        @data = Marshal.dump(msg)
      when String
        @data = msg
      else
        raise ArgumentError.new("Invalid type #{msg.class} for initialization of #{__class__}")
      end
    end
  end

  # A notifier that waits for a specific incoming message.
  class PendingMessageWait < Notifier
    @properties = nil

    # Initialize the object, specifying the match criteria.
    #
    # @param [Hash] opts Property/value pairs that must exist on matching messages.
    def initialize(opts)
      super()
      @properties = opts
    end

    # Check if a message matches the waiter's requirements.
    #
    # @param [Proxy::Message] msg The message to check against.
    def matches?(msg)
      result = true
      begin
        @properties.each_pair { |k, v|
          if msg.public_send(k.intern) != v
            result = false
            break
          end
        }
      rescue NoMethodError
        result = false
      end
      result
    end
  end

  # Message-passing interface specialized for use by Proxy's ObjectNodes.
  class MessagePasser
    @input_stream = nil
    @output_stream = nil
    @verbose = nil

    @incoming_messages = nil
    @outgoing_messages = nil

    @recieve_thread = nil
    @send_thread = nil

    @pending_messages = nil
    @pending_messages_mutex = nil

    # @!attribute [r]
    #   Instance's input stream.
    #   @return [IO]
    attr_reader(:input_stream)

    # @!attribute [r]
    #   Instance's output stream.
    #   @return [IO]
    attr_reader(:output_stream)

    # @!attribute [r]
    #   Input *and* output streams.
    #   @return [Array<IO>]
    def socket
      [@input_stream, @output_stream]
    end

    # Whether verbose (debug) output is enabled.
    # @!attribute [rw] verbose
    #   @return [Boolean]
    attr_accessor :verbose

    # Initialize a new instance of MessagePasser.
    #
    # @overload initialize(socket, verbose=false)
    #
    #   @param [IO] socket The socket or IO stream to use for sending and
    #     receiving messages.
    #
    # @overload initialize(streams, verbose=false)
    #
    #   @param [Array<IO>] streams Input and output streams to use for sending
    #     and receiving messages, respectively.
    def initialize(socket, verbose = false)
      if socket.kind_of?(Array)
        @input_stream = socket[0]
        @output_stream = socket[1]
      else
        @input_stream = socket
        @output_stream = socket
      end
      @input_stream.sync = true if @input_stream.respond_to?(:sync=)
      @output_stream.sync = true if @output_stream.respond_to?(:sync=)
      @verbose = verbose


      @incoming_messages = Queue.new
      @outgoing_messages = Queue.new

      @pending_messages = []
      @pending_messages_mutex = Mutex.new

      @receive_thread = Thread.new { receive_message_loop() }
      @send_thread = Thread.new { send_message_loop() }
    end

    # Close the connection.
    def close()
      @input_stream.close() if not @input_stream.closed?
      @output_stream.close() if not @output_stream.closed?
      @receive_thread.kill if @receive_thread.alive?
      @send_thread.kill if @send_thread.alive?
    end
      
    # Whether or not the connection is currently open.
    # @!attribute [r] connection_open?
    #   @return [Boolean]
    def connection_open?
      not @input_stream.closed? and not @output_stream.closed? and
        @receive_thread.alive? and @send_thread.alive?
    end

    # Queue a message to be sent to the remote node.
    # @param [Proxy::Message] msg Message to send.
    def send_message(msg, blocking=false)
      msg = Message.new(msg) if msg.kind_of?(Symbol)
      raise TypeError.new("Bad message type #{msg.class.name}") if
        not msg.kind_of?(Proxy::Message)

      if connection_open?
        $stderr.puts("#{self}.#{__method__}(#{msg}#{blocking ? ', true' : ''})") if @verbose
        qm = OutgoingMessage.new(msg)
        @outgoing_messages.push(qm)
        qm.wait if blocking
      end
    end

    # Fetch the next (unfiltered) message from the remote node.
    def receive_message()
      if connection_open?
        # $stderr.print("Waiting for message... ")
        # if @incoming_messages.empty?
        #   @have_incoming_message_mutex.synchronize do
        #     @have_incoming_message.wait(@have_incoming_message_mutex)
        obj = @incoming_messages.pop
        #   end
        # else
        #   o = @incoming_messages.pop
        # end
        # $stderr.puts("got " + o.inspect)

        obj.instance_variable_set(:@type, obj.instance_variable_get(:@type).intern)
        obj
      end
    end

    # Wait for the next message from the remote node that matches specific criteria.
    #
    # @param [Hash] opts
    def wait_for_message(opts)
      $stderr.puts("#{self}.#{__method__}(#{opts.inspect})") if @verbose
      waiter = PendingMessageWait.new(opts)
      @pending_messages_mutex.synchronize do
        @pending_messages.push(waiter)
      end
      waiter.wait
    end

    private
    # "Send" thread main loop.  Fetches `OutgoingMessage`s from the outgoing queue, sends them,
    # and signals the `OutgoingMessage` object for send-notification.
    def send_message_loop()
      begin
        while not @output_stream.closed?
          msg = @outgoing_messages.pop
          @output_stream.write_nonblock([msg.data.length].pack('N') + msg.data)
          msg.signal
        end
      rescue EOFError, Errno::EPIPE
        # $stderr.puts(e.message)
        # $stderr.puts(e.backtrace.join(?\n))
        @output_stream.close()
        Thread.exit
      end
    end

    # "Receive" thread main loop.  Fetches messages sent by the remote node and, for each
    # message, either signals threads waiting on criteria matching that message or (if no
    # threads were waiting for such a message) pushes it onto the "incoming messages" queue.
    def receive_message_loop()
      begin
        while not @input_stream.closed?
          # Receive and load the message.
          len = @input_stream.read(4).unpack('N')[0]
          break if len.nil? 

          data = @input_stream.read(len)
          msg = Marshal.load(data)

          # Check if there was a wait for it.
          @pending_messages_mutex.synchronize do
            matches = @pending_messages.select { |pm| pm.matches?(msg) }
            if not matches.empty?
              @pending_messages -= matches
              matches.each { |m| m.signal(msg) }
            else
              @incoming_messages.push(msg)
            end
          end
        end
      rescue EOFError, Errno::EBADF, Errno::EPIPE
        stream.close()
        Thread.exit
      end
    end
  end
end
