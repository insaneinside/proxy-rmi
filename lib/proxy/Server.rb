require 'socket'
require 'fileutils'
require 'continuation'

['Object', 'MessagePasser'].each { |n| Proxy.require File.expand_path('../' + n, __FILE__) }

module Proxy
  # Server class for accepting and managing remote connections.
  class Server
    @objects = nil
    @clients = nil

    @verbose = nil

    @run_mutex = nil
    @run_thread = nil

    @server_class = nil
    @server_args = nil
    @server_socket = nil
    @quit_server = nil

    @client_connect_handler = nil
    @client_disconnect_handler = nil

    # Set the server's client-connect handler.
    #
    # @param [Proc] block Code to run after a client has connected.  The block will be called
    #     with the server-side ObjectNode associated with the client as an argument.
    def on_client_connect(&block)
      @client_connect_handler = block
    end

    # Set the server's client-connect handler.
    #
    # @param [Proc] block Code to run after a client has connected.  The block will be called
    #     without arguments.
    def on_client_disconnect(&block)
      @client_disconnect_handler = block
    end

    # @!attribute [r] running?
    #   Whether the server is currently running.
    #   @return [Boolean]
    def running?
      @run_mutex.locked?
    end

    # Whether verbose output is enabled.
    # @!attribute [rw] verbose
    #   @return [Boolean]
    attr_accessor :verbose

    def initialize(*args)
      super()
      @verbose = false
      @objects = {}
      @clients = []
      @run_mutex = Mutex.new
      @run_thread = nil
      @server_class = args[0]
      @server_args = args[1..-1]
      @server_socket = nil
      @quit_server = false


      @client_connect_handler = nil
      @client_disconnect_handler = nil

      if args[0].kind_of?(Class) and args[0] == UNIXServer
        ObjectSpace.define_finalizer(self, proc { |id| FileUtils::rm_f(args[1]) if File.exist?(args[1]) })
      end
    end

    # Start the server loop in a separate thread.
    # @return [Boolean] `true` if a new thread was created, and `false` if it was already
    #     running.
    def launch()
      if not running?
        @run_thread = Thread.new { server_main(@server_class, *@server_args) }
        sleep(0.01)
        true
      else
        false
      end
    end

    # Run the server loop in the current thread.
    def run
      if not running?
        server_main(@server_class, *@server_args)
      end
    end
      

    # Kill the server thread.  This is a ruder version of {#stop}.
    def kill()
      @quit_server = true
      @run_thread.kill()
    end

    # Stop the server thread gracefully.
    def stop()
      @quit_server = true
      @run_thread.join()
    end

    # Wait for the server thread to finish.
    def wait()
      @run_thread.join()
    end

    # Main routine for the server thread.  Waits for incoming connections, and spawns a new
    # client thread (each with its own ObjectNode) for each incoming connection.
    def server_main(server_class, *args)
      @run_mutex.synchronize do
          $stderr.puts("[#{self.class}] Entering main server loop; server is #{server_class.name} #{args.inspect}") if @verbose

          # sighandler = proc { @run_thread.kill; Process.abort }
          # Signal.trap(:QUIT, &sighandler)
          # Signal.trap(:INT, &sighandler)
          # Signal.trap(:TERM, &sighandler)

          # Delete any old UNIX socket lying around, if needed, and open the server socket.
          FileUtils::rm_f(args[0]) if server_class == UNIXServer
          callcc do |cc|
          begin
            server_class.open(*args) do |serv|
              @server_socket = serv
              while not serv.closed? and not @quit_server do
                sock = serv.accept

                cli = ObjectNode.new(sock, @verbose)
                @clients << cli
                Thread.new {
                  begin
                    client_loop(cli)
                  rescue IOError, Errno::EPIPE
                    cli.close!
                    Thread.exit
                  end
                }
              end
            end
          rescue IOError, Errno::EPIPE
            Thread.exit
          end
        end
        @clients.each { |cli| cli.close if cli.connection_open? }
        FileUtils::rm_rf(args[0]) if server_class == UNIXServer
        $stderr.puts("[#{self.class}] Server loop exited.") if @verbose
        end
    end

    # This method contains the loop for each client connection.
    def client_loop(node)
      @client_connect_handler.call(node) if not @client_connect_handler.nil?
      $stderr.puts("[#{self.class}] Entered client loop for connection #{node.socket}") if @verbose
      begin
        while node.connection_open? do
          msg = node.receive_message()
          handle_message(node, msg) if not msg.nil? and not node.handle_message(msg)
        end
      rescue => e
        node.close
        raise e
      end
      @clients.delete(node)
      @client_disconnect_handler.call() if not @client_disconnect_handler.nil?

      $stderr.puts("[#{self.class}] Exited client loop for connection #{node.socket.inspect}\n") if @verbose
    end

    # Handle a message sent to a local object node from the remote peer by performing an action
    # appropriate to the message's contents.
    #
    # @param [Proxy::ObjectNode] node Node that received the message.
    #
    # @param [Proxy::Message] msg Message to handle.
    #
    # @return [Boolean] `true` if we were able to handle the message, and `false` otherwise.
    def handle_message(node, msg)
      $stderr.puts("[#{self.class}] Handling message: #{msg}") if @verbose

      case msg.type
      when :shutdown
        $stderr.puts("[#{self.class}] Received server-shutdown command.") if @verbose
        @quit_server = true
        @server_socket.close
        @run_thread.kill
        true
        
      when :fetch
        $stderr.puts("[#{self.class}] Received fetch request for \"#{msg.value}\"") if @verbose
        obj = @objects[msg.value]
        o = case obj
            when Proc
              obj.call
            else
              obj
            end
        node.send_message(node.export(o, msg.value))

      when :eval
        o = begin
              Kernel.eval(msg.value)
            rescue SyntaxError => err
              err
            end
        node.send_message(node.export(o, msg.note))

      when :list_exported
        o = @objects.keys
        node.send_message(Message.export(o, :exports))

      else
        node.send_message(Message.new(:error, "Unknown message type #{msg.type.inspect}"))
      end

    end


    # Add an object to the export list.
    def add(name, val)
      @objects[name] = val
    end
  end
end
