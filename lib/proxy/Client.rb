['Object', 'ObjectNode'].each { |n| Proxy.require File.expand_path('../' + n, __FILE__) }

module Proxy
  # An ObjectNode with support for fetching remote objects.
  class Client < ::Proxy::ObjectNode
    # List the objects exported by the remote server.
    # @return [Array<String>] An array of exported object names.
    def list_objects
      send_message(GenericMessage.new(:list_exported))
      handle_message(wait_for_message(:note => :exports))
    end

    # Fetch a remote object.
    #
    # @param [String] name The name of the remote object to fetch.  This should
    #   be one of the names returned by `list_objects`.
    def fetch(name)
      transaction(name) do
        send_message(GenericMessage.new(:fetch, name, :note => name))
        handle_message(wait_for_message(:note => name))
      end
    end
    alias_method :[], :fetch

    def initialize(*a)
      super(*a)
    end

    # Evaluate code on the other side of the connection.  Note that remote
    # evaluation is disabled by default in Server.
    #
    # @warning THIS METHOD IS PROBABLY A BAD IDEA.  You probably shouldn't use
    #     it.
    #
    # @param [String] string Code to be evaluated.
    def remote_eval(string)
      note = 'eval_' + Time.now.to_s
      send_message(GenericMessage.new(:eval, string, note))
      handle_message(wait_for_message(:note => note))
    end
  end
end
