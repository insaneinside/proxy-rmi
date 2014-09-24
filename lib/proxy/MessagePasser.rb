Proxy.require(File.expand_path('../Notifier', __FILE__))
require 'thread'

module Proxy
  # A queued outgoing message.
  class OutgoingMessage < Notifier
    @data = nil
    @source = nil
    @related_wait = nil

    # Serialized message data.
    # @!attribute [r] data
    #   @return [String]
    attr_reader :data

    # Source message data.
    attr_reader :source

    # A related Notifier object.  This may be e.g. a notifier that triggers on
    # the incoming reply to the message contained in this object.
    #
    # @!attribute [r]
    #   @return [Proxy::Notifier]
    attr_reader :related_wait


    # Initialize an OutgoingMessage object.
    #
    # @param [Proxy::Message,String] msg The Message object being queued, or a string acquired
    #     by calling `Marshal.dump` on the same.
    #
    # @param [Proxy::Notifier,nil] _related_wait A notifier somehow related to
    #     this message.  This is currently used to decide whether
    #     outgoing-message log messages should be marked as expecting a
    #     response when MessagePasser#verbose is `true`.
    def initialize(msg, _related_wait = nil)
      @source = msg
      @related_wait = _related_wait
      super()
      case msg
      when Proxy::Message
        begin
          @data = Marshal.dump(msg)
        rescue => err
          msg = 'Error dumping %s: %s' % [msg.inspect, err.message]
          e = err.class.new(msg)
          e.set_backtrace(err.backtrace)
          raise e
        end
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
    MESSAGE_SEPARATOR = '\0\0\0\0'

    @input_stream = nil
    @output_stream = nil
    @verbose = nil

    @incoming_messages = nil
    @outgoing_messages = nil

    @receive_thread = nil
    @send_thread = nil

    @pending_messages = nil
    @pending_messages_mutex = nil

    @transaction_stacks = nil
    @transaction_mutex = nil

    # Transaction nesting for each thread using this MessagePasser.  Used for
    # diagnostic output.
    #
    # @!attribute [r]
    #   @return Hash<Thread,Array>
    attr_reader :transaction_stacks

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


    def set_streams(istream, ostream)
      @input_stream = istream
      @output_stream = ostream
    end

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
        set_streams(socket[0], socket[1])
      else
        set_streams(socket, socket)
      end
      @input_stream.sync = true if @input_stream.respond_to?(:sync=)
      @output_stream.sync = true if @output_stream.respond_to?(:sync=)
      @verbose = verbose


      @incoming_messages = Queue.new
      @outgoing_messages = Queue.new

      @pending_messages = []
      @pending_messages_mutex = Mutex.new

      @transaction_stacks = Hash.new { |hsh, key| hsh[key] = [] }
      @transaction_mutex = Mutex.new

      @receive_thread = Thread.new { receive_message_loop() }
      @send_thread = Thread.new { send_message_loop() }
    end

    # Close the connection.
    def close()
      $stderr.puts("#{self}.#{__method__}()") if @verbose
      begin
        @input_stream.close() if not @input_stream.closed?
        @output_stream.close() if not @output_stream.closed?
      rescue Errno::EBADF
      end
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

    # Helper for keeping track of use by MessagePasser subclasses.
    def transaction(id, &block)
      @transaction_mutex.synchronize { @transaction_stacks[Thread.current].push(id) } if @verbose
      o = block.call()
      @transaction_mutex.synchronize { @transaction_stacks[Thread.current].pop() } if @verbose
      o
    end

    # Queue a message to be sent to the remote node.
    # @param [Proxy::Message] msg Message to send.
    def send_message(msg, blocking=false, related_wait = nil)
      msg = GenericMessage.new(msg) if msg.kind_of?(Symbol)
      raise TypeError.new("Bad message type #{msg.class.name}") if
        not msg.kind_of?(Proxy::Message)
      raise Errno::ESHUTDOWN if not connection_open?()

      qm = OutgoingMessage.new(msg, related_wait)
      @outgoing_messages.push(qm)
      qm.wait if blocking
    end

    # Fetch the next unfiltered message from the remote node.
    def receive_message(blocking=true)
      if connection_open?
        obj = blocking \
          ? @incoming_messages.pop \
          : begin
              @incoming_messages.pop(true)
            rescue
              nil
            end

        obj.instance_variable_set(:@type, obj.instance_variable_get(:@type).intern) unless obj.nil?
        obj
      end
    end

    # Enqueue a wait for a certain message pattern, enqueue the outgoing
    # message that should cause the peer to send a matching message, and wait
    # for the response.
    #
    # @param [Message] msg The message to be sent.
    # @param [Hash] opts Incoming-message match patterns.
    def send_message_and_wait(msg, opts)
      waiter = enqueue_waiter(opts)
      send_message(msg, false, waiter)
      waiter.wait()
    end

    # Wait for the next message from the remote node that matches specific criteria.
    #
    # @param [Hash] opts
    def wait_for_message(opts)
      enqueue_waiter(opts).wait()
    end

    private
    def enqueue_waiter(opts)
      waiter = PendingMessageWait.new(opts)
      # Check for unfiltered messages that match this waiter.  Used to depend
      # on being able to access instance variables of Queue, but doesn't work
      # in Ruby 2.1.2 anymore so we dump the entire incoming message queue,
      # look for a match, and rebuild it instead.
      messages = []
      @pending_messages_mutex.synchronize do
        messages << @incoming_messages.pop() while not @incoming_messages.empty?
        begin
          messages.each { |im|
            if waiter.matches?(im)
              messages.delete(im)
              waiter.signal(im)
              return waiter
            end }
          @pending_messages.push(waiter) if not waiter.signalled?
        ensure
          @incoming_messages.push(messages.pop()) while not messages.empty?
        end
      end
      return waiter
    end


    def log_message_transaction(msg, direction, flag = false)
      if @verbose
        dstring = {:outgoing => '[31m->[0m', :incoming => '[32m<-[0m'}[direction]
        note = msg.note.nil? ? '' : msg.note.inspect

        $stderr.puts('%-48s [1;97m%-2s[0m%3s [33m%-16s[0m %-16s %s' %
                     ['%s[94m%s[0m' % [@transaction_stacks[msg.source_thread].join('+') + '>', self.inspect],
                      dstring, flag ? ((direction == :outgoing) ? '[#]' : '[*]') : '', note, msg.type, msg.inspect])

        $stderr.flush()
      end
    end

    # "Send" thread main loop.  Fetches `OutgoingMessage`s from the outgoing queue, sends them,
    # and signals the `OutgoingMessage` object for send-notification.
    def send_message_loop()
      begin
        while not @output_stream.closed?
          msg = @outgoing_messages.pop
          @output_stream.write(MESSAGE_SEPARATOR)
          @output_stream.write([msg.data.length].pack('N') + msg.data)
          @output_stream.flush()
          msg.signal
          log_message_transaction(msg.source, :outgoing, (not msg.related_wait.nil?))
        end
      rescue EOFError, Errno::EPIPE => e
        $stderr.puts(e.message)
        $stderr.puts(e.backtrace.join("\n"))
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
          @input_stream.readline(MESSAGE_SEPARATOR)
          # Receive and load the message.
          len = @input_stream.read(4).unpack('N')[0]
          break if len.nil?

          data = @input_stream.read(len)
          begin
            msg = Marshal.load(data)
          rescue TypeError => e
            $stderr.puts("Failed to load message data: >>>#{data}<<<")
            raise e
          end

          # Check if there was a wait for it.
          matches = []
          @pending_messages_mutex.synchronize do
            matches = @pending_messages.select { |pm| pm.matches?(msg) }
            @pending_messages -= matches if not matches.empty?
          end

          if not matches.empty?
            matches.each { |m| m.signal(msg) }
            log_message_transaction(msg, :incoming, true)
          else
            @incoming_messages.push(msg)
            log_message_transaction(msg, :incoming)
          end
        end
      rescue EOFError, Errno::EBADF, Errno::EPIPE
        @input_stream.close()
        Thread.exit
      end
    end
  end
end
