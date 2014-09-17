require 'socket'
require 'fileutils'
require 'continuation'

['Object', 'MessagePasser'].each { |n| Proxy.require File.expand_path('../' + n, __FILE__) }

module Proxy
  # Server class for managing an exported-object list and accepting and
  # managing remote connections.  `Server` is designed for connection-based
  # transports like TCP and UNIX sockets, but can handle single-peer style
  # usage as well.
  class Server
    @objects = nil
    @clients = nil

    @verbose = nil
    @eval_enabled = false

    @run_mutex = nil
    @run_thread = nil

    @main_args = nil
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

    # @!attribute [rw] eval_enabled
    #   Whether to allow clients to request code evaluation for them
    #   @return [Boolean]
    attr_accessor :eval_enabled

    # Initialize the server instance.
    # @param [*Object] args Arguments to be passed to Server#server_main.
    def initialize(*args)
      super()
      @verbose = false
      @eval_enabled = false
      @objects = {}
      @clients = []
      @run_mutex = Mutex.new
      @run_thread = nil
      @main_args = args
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
        @run_thread = Thread.new { server_main(*@main_args) }
        sleep(0.01)
        true
      else
        false
      end
    end

    # Run the server loop in the current thread.  If the server is already
    # running in a different thread, this call will block until that thread
    # exits.
    def run()
      if not running?
        server_main(*@main_args)
      elsif not @run_thread.nil? and @run_thread.alive?
        wait()
      end
    end
      

    # Kill the server thread.  This is a ruder version of {#stop}.
    def kill()
      @quit_server = true
      @server_socket.close()
      @run_thread.kill() if not @run_thread.nil? and @run_thread.alive?
    end

    # Stop the server thread gracefully.
    def stop()
      @quit_server = true
      @server_socket.close()
      @run_thread.join() if not @run_thread.nil? and @run_thread.alive?
    end

    # Wait for the server thread to finish.
    def wait()
      @run_thread.join() if not @run_thread.nil? and @run_thread.alive?
    end

    # Main routine for the server thread.
    #
    # @overload server_main(stream)
    #
    #   Service a single connection open on `stream`.
    #
    #   @param [IO,Array<IO>] An open IO object, or array of IO objects
    #     corresponding to input and output streams.
    #
    # @overload server_main(connection_class, *args)
    #
    #   Service a single connection opened by calling
    #   `connection_class.new(*args)`.
    #
    #   @param [#new] connection_class Class to instantiate for communication.
    #
    #   @param [Array] *args Arguments to be passed to `connection_class.new`
    # 
    # @overload server_main(server_class, *args)
    #
    #   Run the server with support for an arbitrary number of clients via a
    #   connection-based transport.
    #
    #   @param [#open(*args)->#accept] server_class A class on which `open`
    #     may be called (with arguments `*args`) to obtain an object that has
    #     an `accept` method.
    #
    #   @param [Array] *args Arguments to be passed to `server_class.open`.
    def server_main(obj, *args)
      @run_mutex.synchronize do
        if not obj.kind_of?(Class)
          client_loop(ObjectNode.new(obj, *args))
        elsif obj.respond_to?(:open)
          $stderr.puts("[#{self.class}] Entering main server loop; server is #{obj.name} #{args.inspect}") if @verbose

          # sighandler = proc { @run_thread.kill; Process.abort }
          # Signal.trap(:QUIT, &sighandler)
          # Signal.trap(:INT, &sighandler)
          # Signal.trap(:TERM, &sighandler)

          # Delete any old UNIX socket lying around, if needed, and open the server socket.
          FileUtils::rm_f(args[0]) if obj == UNIXServer
          obj.open(*args) do |serv|
            @server_socket = serv
            begin
              while not serv.closed? and not @quit_server do
                begin
                  sock = serv.accept_nonblock()
                rescue Errno::EAGAIN
                  IO.select([serv])
                  retry
                rescue Errno::EBADF
                  break
                end


                cli = ObjectNode.new(sock, @verbose)
                @clients << cli
                Thread.new {
                  client_loop(cli)
                }
              end
            rescue IOError, Errno::EPIPE, Errno::EBADF
              break
            end
          end

          @clients.each { |cli| cli.close() if cli.connection_open? }
          FileUtils::rm_rf(args[0]) if obj == UNIXServer
          $stderr.puts("[#{self.class}] Server loop exited.") if @verbose
        elsif obj.ancestors.include?(IO)
          client_loop(ObjectNode.new(obj.new(*args)))
        end
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
      rescue => err
        $stderr.puts(err.inspect)
        $stderr.puts("    " + err.backtrace.join("\n    "))
        Thread.exit
      ensure
        node.close() if node.connection_open?
        @clients.delete(node) if @clients.include?(node)
        @client_disconnect_handler.call() if not @client_disconnect_handler.nil?
      end

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
        node.close()
        @quit_server = true
        @server_socket.close()
        @run_thread.kill() if not @run_thread.nil? and @run_thread.alive? and @run_thread != Thread.current
        
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
        if @eval_enabled
          o = begin
                eval(msg.value)
              rescue => err
                err
              end
          node.send_message(node.export(o, msg.note))
        end

      when :list_exported
        o = @objects.keys
        node.send_message(node.export(o, :note => :exports))

      else
        node.send_message(ErrorMessage.new(RuntimeError.new("Unknown message type #{msg.type.inspect}")))
      end

    end


    # Add an object to the export list.
    #
    # @param [String] name Name for the exported object.
    # @param [Object] val Object to export.
    def add(name, val)
      @objects[name] = val
    end
  end
end
