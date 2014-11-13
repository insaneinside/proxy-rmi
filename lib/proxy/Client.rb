require_relative '../proxy' unless Object.const_defined?(:Proxy) and ::Proxy.respond_to?(:require_relative)
Proxy.require_relative 'ObjectNode'
Proxy.require_relative 'Message'

module Proxy
  # An ObjectNode with support for fetching remote objects.
  class Client < ::Proxy::ObjectNode
    # List the objects exported by the remote server.
    # @return [Array<String>] An array of exported object names.
    def list_exports
      handle_message(send_message_and_wait(:list_exports, :exports))
    end

    # Fetch a remote object.
    #
    # @param [String] name The name of the remote object to fetch.  This should
    #   be one of the names returned by `list_objects`.
    def fetch(name=nil)
      transaction(name) do
        handle_message(send_message_and_wait(GenericMessage.new(:fetch, :value => name), name || @message_sequence.value))
      end
    end
    alias_method :[], :fetch

    # Evaluate code on the other side of the connection.  Note that remote
    # evaluation is disabled by default in Server.
    #
    # @warning THIS METHOD IS PROBABLY A BAD IDEA.  You probably shouldn't use
    #     it.
    #
    # @param [String] string Code to be evaluated.
    def remote_eval(string)
      note = 'eval_' + Time.now.to_s
      handle_message(send_message_and_wait(GenericMessage.new(:eval, string, note), note))
    end
  end
end
