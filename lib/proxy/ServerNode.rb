Proxy.require_relative('ObjectNode')
Proxy.require_relative('ThreadedService')

module Proxy

  # Extension of ObjectNode that provides methods specific to the server end of
  # a connection.
  class ServerNode < ::Proxy::ObjectNode
    include ThreadedService

    @server = nil
    @node_stopping = nil

    # Server associated with this node.
    # @!attribute [r]
    #   @return Server
    attr_reader :server

    # Whether the node is in the process of halting its service thread.
    #
    # @!attribute [r]
    #   @return [Boolean]
    def stopping?
      @node_stopping or @stopping
    end

    def initialize(_server, *a, **opts)
      @server = _server
      @node_stopping = false
      ObjectNode.instance_method(:initialize).
        bind(self).call(*a, **opts)

      ThreadedService.instance_method(:initialize).
        bind(self).call(method(:run_impl),
                        method(:halt_impl))
    end


    # Main loop for the service thread.
    def run_impl()
      handle_message(receive_message()) while connection_open? and not stopping?
    end

    # `halt` implementation for the service thread.
    def halt_impl()
      @node_stopping = true
      close()
    end


    private :halt
    private :launch
    private :run_impl
    private :halt_impl


    # Handle a message sent to this node from the remote peer by performing an
    # action appropriate to the message's contents.
    #
    # @param [Proxy::Message] msg Message to handle.
    #
    # @return [Boolean] `true` if we were able to handle the message, and `false` otherwise.
    def handle_message(msg)
      o = super
      if not o
        # $stderr.puts("[#{self.class}] Handling message: #{msg}") if @verbose
        case msg.type
        when :shutdown
          # $stderr.puts("[#{self.class}] Received server-shutdown command.") if @verbose
          close()
          @server.kill()        # FIXME: we should be using `halt()` here -- but it doesn't work
          true
        when :fetch
          # $stderr.puts("[#{self.class}] Received fetch request for \"#{msg.value}\"") if @verbose
          obj =
            if msg.value
              @server.front[msg.value]
            else
              @server.front
            end
          send_message(export(obj, msg.seq))
          true

        when :eval
          if @server.eval_enabled
            o = begin
                  Kernel.eval(msg.value)
                rescue => err
                  err
                end
            send_message(export(o, msg.note))
          end
          true

        when :list_exports
          o = @server.front.keys
          send_message(export(o, :exports))
          true
        else
          o
        end
        o
      end
    end
  end
end
