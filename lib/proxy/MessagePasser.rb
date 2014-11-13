require 'thread'
require 'fcntl'
require 'atomic'

module Proxy
  # Message-passing interface specialized for use by Proxy's ObjectNodes.
  class MessagePasser
    WRITE_METHODS = [:send_nonblock, :syswrite, :write]
    READ_METHODS = [:recv_nonblock, :sysread, :read]

    @input_stream = nil
    @output_stream = nil
    @verbose = nil

    @transaction_stacks = nil
    @message_sequence = nil

    @stopping = nil

    # Transaction nesting for each thread using this MessagePasser.  Used for
    # diagnostic output.
    #
    # @!attribute [r]
    #   @return Hash<Thread,Array>
    attr_reader(:transaction_stacks)

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
      @input_stream == @output_stream \
        ? @input_stream \
        : [@input_stream, @output_stream]
    end

    # Whether or not the connection is currently open.
    # @!attribute [r] connection_open?
    #   @return [Boolean]
    def connection_open?
      not @input_stream.closed? and not @output_stream.closed?
    end


    # Whether the message passer has shut down or is in the process of shutting
    # down.
    # @!attribute [r]
    #   @return [Boolean]
    def stopping?
      @stopping
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
    def initialize(_sock, _verbose = false)
      _sock = [_sock] unless _sock.kind_of?(Array)
      if _sock.length == 2
        set_streams(*_sock)
      else
        set_streams(_sock[0], _sock[0])
      end

      @message_sequence = Atomic.new(0)

      @verbose = _verbose

      @stopping = false

      @transaction_stacks = Hash.new { [] }
    end


    # Set the input and output streams to use for communication.
    #
    # @param [#sysread,#recv_nonblock] istream IO-like object to use as the
    #     input channel.
    #
    # @param [#syswrite,#send_nonblock] ostream IO-like object to use as the
    #     output channel.
    def set_streams(istream, ostream)
      @input_stream = istream
      @output_stream = ostream

      # @input_stream.sync = true if @input_stream.respond_to?(:sync=)
      # @output_stream.sync = true if @output_stream.respond_to?(:sync=)

      @input_stream.fcntl(::Fcntl::F_SETFL, ::Fcntl::O_NONBLOCK) if @input_stream.respond_to?(:fcntl)
      @output_stream.fcntl(::Fcntl::F_SETFL, ::Fcntl::O_NONBLOCK) if @output_stream.respond_to?(:fcntl)

      @input_read_method = READ_METHODS.select { |sym| @input_stream.respond_to?(sym) }.first
      @output_write_method = WRITE_METHODS.select { |sym| @output_stream.respond_to?(sym) }.first
    end


    # Close the connection.
    def close()
      @stopping = true
      # $stderr.puts("#{self}.#{__method__}()") if @verbose
      begin
        @input_stream.close() if not @input_stream.closed?
        @output_stream.close() if not @output_stream.closed? and @output_stream != @input_stream
      # rescue Errno::EBADF
      end
    end

    # Helper for keeping track of use by MessagePasser subclasses.
    def transaction(id, &block)
      @transaction_stacks[Thread.current].push(id) if @verbose
      o = block.call()
      @transaction_stacks[Thread.current].pop if @verbose
      o
    end


    # Send a a message to the remote node.
    #
    # @param [Proxy::Message,Symbol] msg Message to send. If a `Symbol`, a new
    #     `GenericMessage` will be created with this value as its type.
    #
    # @param [Object] _mid "Note" or message-ID to use if `msg` is not
    #     a Message or has a `nil` `seq`.
    def send_message(msg, _seq = nil)
      raise 'No longer accepting messages' if stopping?
      seq = _seq || @message_sequence.value
      if msg.kind_of?(Symbol)
        msg = GenericMessage.new(msg, :seq => seq)
      elsif msg.seq.nil?
        msg.instance_variable_set(:@seq, seq)
      end

      data = Marshal.dump(msg)

      begin
        @output_stream.public_send(@output_write_method, [data.length].pack('N') + data)
      rescue IO::WaitWritable
        IO.select(nil, [@output_stream])
        retry
      end
      seq = @message_sequence.value
      @message_sequence.update { |v| v + 1 }
      log_message_transaction(msg, seq, :outgoing, _seq) if @verbose
    end

    # Read the next message sent by the remote node.
    #
    # @return Proxy::Message
    def receive_message()
      data = nil

      # Read the message length.
      lenbuf = ''
      begin
        lenbuf += @input_stream.public_send(@input_read_method, 4 - lenbuf.size) while lenbuf.size != 4
      rescue Errno::EWOULDBLOCK, IO::WaitReadable
        IO.select([@input_stream])
        retry
      rescue Errno::EBADF
        close
        return
      end

      len = lenbuf.unpack('N')[0]
      # Now read the message data.
      data = ''
      begin
        data += @input_stream.public_send(@input_read_method, len - data.size) while data.size != len
      rescue Errno::EWOULDBLOCK, IO::WaitReadable
        IO.select([@input_stream])
        retry
      rescue Errno::EBADF
        close
        return
      end
      msg = Marshal.load(data)

      # raise TypeError.new(msg.inspect) unless msg.kind_of?(Message)
      # seq = @message_sequence.value
      @message_sequence.update { |v| v + 1 }

      log_message_transaction(msg, @message_sequence.value, :incoming,
                              (not msg.seq.nil? and @transaction_stacks[Thread.current][-1] == msg.seq) \
                              ? true \
                              : nil) if @verbose

      msg
    end

    # Send a message, then wait for an incoming message matching specified
    # criteria via `#wait_for_message`.
    #
    # @param [Message] msg Message to be sent.
    # @param [Object] seq "Seq" value for positive message match.
    def send_message_and_wait(msg, seq)
      send_message(msg, seq)
      wait_for_message(seq)
    end

    # Wait for next message from remote node that has a specific "seq"
    # attached.  Messages that do *not* match will be handled with
    # `#handle_message`.
    #
    # @param [Object] seq Value of the `seq` field to look for on incoming
    #     messages.
    def wait_for_message(seq)
      next_message = receive_message()
      while next_message.seq != seq
        handle_message(next_message)
        next_message = receive_message()
      end
      next_message
    end

    private


    def log_message_transaction(msg, seq, direction, flag = false)
      if @verbose
        dstring = {:outgoing => '[31m->[0m', :incoming => '[32m<-[0m'}[direction]
        seq = msg.seq.nil? ? '' : msg.seq.inspect

        $stderr.puts('%04u %-48s [1;97m%-2s[0m%3s [33m%-16s[0m %-16s %s' %
                     [@message_sequence.value, '%s[94m%s[0m' % ['<%s>' % @transaction_stacks[Thread.current].join('+'), self.inspect],
                      dstring, flag ? ((direction == :outgoing) ? '[#]' : '[*]') : '', seq, msg.type, msg.inspect])

        $stderr.flush()
      end
    end
  end
end
