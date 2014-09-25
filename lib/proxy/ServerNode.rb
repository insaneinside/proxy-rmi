['Object', 'ObjectNode'].each { |n| Proxy.require File.expand_path('../' + n, __FILE__) }


module Proxy
  class ServerNode < ::Proxy::ObjectNode
    @server = nil

    attr_reader :server

    def initialize(_server, *a)
      @server = _server
      super(*a)
    end

    # Handle a message sent to this node from the remote peer by performing an
    # action appropriate to the message's contents.
    #
    # @param [Proxy::Message] msg Message to handle.
    #
    # @return [Boolean] `true` if we were able to handle the message, and `false` otherwise.
    def handle_message(msg)
      # $stderr.puts("[#{self.class}] Handling message: #{msg}") if @verbose
      case msg.type
      when :shutdown
        # $stderr.puts("[#{self.class}] Received server-shutdown command.") if @verbose
        close()
        @server.stop()
        true
      when :fetch
        # $stderr.puts("[#{self.class}] Received fetch request for \"#{msg.value}\"") if @verbose

        obj = @server.objects[msg.value]
        send_message(export(obj, msg.value))
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

      when :list_exported
        o = @server.objects.keys
        send_message(export(o, :note => :exports))
        true
      else
        super(msg)
      end
    end
  end
end
