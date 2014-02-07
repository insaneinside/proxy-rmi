require 'socket'
['Object', 'ObjectNode'].each { |n| Proxy.require File.expand_path('../' + n, __FILE__) }

module Proxy
  # An ObjectNode with support for fetching remote objects.
  class Client < ::Proxy::ObjectNode
    # Initialize a new Client instance.
    # @overload initialize(*args)
    #
    #   @param [] *args Arguments accepted by ObjectNode#initialize.
    #
    # @overload initialize(klass, *args)
    #   @param [Class] klass A subclass of IO to be instantiated for communication.
    #   @param [Object] args Arguments to pass to `klass.new`.
    def initialize(*s)
      if (s[0].kind_of?(BasicSocket) or s[0].kind_of?(IO)) or s[0].kind_of?(Array)
        super(*s)
      elsif s[0].respond_to?(:ancestors) and s[0].ancestors.include?(IO)
        super(s[0].new(*s[1..-1]))
      else
        raise ArgumentError.new("Don't know what to do with arguments: #{s.inspect}")
      end
    end

    # List the objects exported by the remote server.
    # @return [Array<String>] An array of exported object names.
    def list_objects
      send_message(Message.new(:list_exported), true)
      handle_message(wait_for_message(:note => :exports))
    end

    # Fetch a remote object.
    #
    # @param [String] name The name of the remote object to fetch.  This should be one of the
    #   names returned by `list_objects`.
    def fetch(name)
      send_message(Message.new(:fetch, name), true)
      handle_message(wait_for_message(:note => name))
    end
    alias_method :[], :fetch


    # Evaluate code on the other side of the connection.  This is probably a bad idea...
    # @param [String] string Code to be evaluated.
    def remote_eval(string)
      note = 'eval_' + Time.now.to_s
      send_message(Message.new(:eval, string, note))
      import(wait_for_message(:note => note))
    end
  end
end
