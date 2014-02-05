module Proxy
  # Remote-object proxy class.  Because Object is derived from the Ruby 1.9+ `BasicObject`
  # class, it can be written in comparatively less code than the equivalent `drb` class.
  class Object < ::BasicObject
    # Structure used to store information needed to cleanly de-reference remote objects once
    # they are no longer used locally.
    RemoteObjectEntry = ::Struct.new(:client, :remote_id)
    @ProxyObject_client = nil
    @ProxyObject_object_id = nil
    @@remote_objects_map = {}

    # Object's remote object-ID.
    # @!attribute [r] proxy_id
    #   @return [Integer]
    def proxy_id
      @ProxyObject_object_id
    end

    # Initialize a new remote-object reference/proxy.
    #
    # @param [ObjectNode] client ObjectNode _connected_ to the remote node that owns the object being
    #     proxied.
    # @param [Integer] remote_id  Object ID of the remote object.
    def initialize(client, remote_id)
      @@entries = {} if not :@@entries.nil?

      @ProxyObject_client = client
      @ProxyObject_object_id = remote_id

      @@remote_objects_map[__id__] = RemoteObjectEntry.new(client, remote_id)

      ::ObjectSpace.define_finalizer(self, ::Proc.new { |local_id|
                                       @@remote_objects_map[local_id].client.release(@@remote_objects_map[local_id].remote_id)
                                       @@remote_objects_map.delete(local_id)
                                     })
    end


    # Proxy any calls to missing methods to the remote object.
    def method_missing(sym, *args, &block)
      @ProxyObject_client.invoke(@ProxyObject_object_id, sym, args, block)
    end
  end
end
