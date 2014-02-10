require 'socket'
['Object', 'ObjectNode'].each { |n| Proxy.require File.expand_path('../' + n, __FILE__) }

module Proxy
  # An ObjectNode with support for fetching remote objects.
  class Client < ::Proxy::ObjectNode
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


    # Evaluate code on the other side of the connection.
    #
    # @warning THIS METHOD IS PROBABLY A BAD IDEA.  You probably shouldn't use
    #     it.
    #
    # @param [String] string Code to be evaluated.
    def remote_eval(string)
      note = 'eval_' + Time.now.to_s
      send_message(Message.new(:eval, string, note))
      import(wait_for_message(:note => note))
    end
  end
end
