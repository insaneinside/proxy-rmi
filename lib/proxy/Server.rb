require_relative('../proxy') unless ::Kernel::const_defined?(:Proxy) and ::Proxy.respond_to?(:require_relative)
Proxy.require_relative('ThreadedService')
Proxy.require_relative('ServerNode')
require 'socket'
require 'fileutils'

module Proxy
  # Server class for managing an exported-object list and accepting and
  # managing remote connections.  `Server` is designed for connection-based
  # transports like TCP and UNIX sockets, but can handle single-peer style
  # usage as well.
  class Server
    include ThreadedService
    @front = nil
    @clients = nil

    @verbose = nil
    @eval_enabled = false

    @main_args = nil
    @server_socket = nil
    @quit_server = nil

    @client_connect_handler = nil
    @client_disconnect_handler = nil

    # "Front" object presented by the server.
    # @!attribute [rw]
    #   @return [Object]
    attr_accessor(:front)

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
      verbose = false
      verbose = args.pop if args.size > 1 and
        (args[-1].kind_of?(FalseClass) or args[-1].kind_of?(TrueClass))

      @verbose = verbose
      @eval_enabled = false
      @front = nil
      @clients = []
      @main_args = args
      @server_socket = nil
      @quit_server = false


      @client_connect_handler = nil
      @client_disconnect_handler = nil

      if args[0].kind_of?(Class) and args[0] == UNIXServer
        ObjectSpace.define_finalizer(self, proc { |id| FileUtils::rm_f(args[1]) if File.exist?(args[1]) })
      end

      super(proc { server_main(*@main_args) }, method(:halt_impl))
    end

    # Add an object to the export list.  The front object must be either `nil`,
    # or a hash.
    #
    # @param [Object] name Key for the exported object.
    # @param [Object] val Object to export.
    def add(name, val)
      raise 'Front object is already initialized and not a hash!' unless @front.nil? or @front.kind_of?(Hash)
      @front = {} if @front.nil?
      @front[name] = val
    end


    private
    # Stop the server's main loop.
    def halt_impl()
      @quit_server = true
      @server_socket.close() unless @server_socket.nil? or @server_socket.closed?
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
      if not obj.kind_of?(Class)
        client_loop(ServerNode.new(self, obj, *args))
      elsif obj.respond_to?(:open)
        $stderr.puts("[#{self.class}] Entering main server loop; server is #{obj.name} #{args.inspect}") if @verbose

        # Delete any old UNIX socket lying around, if needed, and open the server socket.
        FileUtils::rm_f(args[0]) if obj == UNIXServer
        def obj.open(*a)
          super(*a)
        end
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


              cli = ServerNode.new(self, sock, @verbose)
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
        client_loop(ServerNode.new(obj.new(*args)))
      end
    end

    # This method contains the loop for each client connection.
    def client_loop(node)
      @client_connect_handler.call(node) if not @client_connect_handler.nil?
      $stderr.puts("[#{self.class}] Entered client loop for connection #{node.socket}") if @verbose

      begin
        node.run()
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
  end
end
