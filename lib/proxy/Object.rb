module Proxy
  # Remote-object proxy class.  Because Object is derived from the Ruby 1.9+ `BasicObject`
  # class, it can be written in comparatively less code than the equivalent `drb` class.
  class Object < ::BasicObject
    # Structure used to store information needed to cleanly de-reference remote objects once
    # they are no longer used locally.
    RemoteObjectEntry = ::Struct.new(:client, :remote_id)
    @ProxyObject_client = nil
    @ProxyObject_object_id = nil
    @ProxyObject_class_name = nil
    @@remote_objects_map = {}

    # Object's remote object-ID.
    # @!attribute [r] proxy_id
    #   @return [Integer]
    def proxy_id
      @ProxyObject_object_id
    end

    def proxy_class
      @ProxyObject_class_name
    end


    def proxy_client
      @ProxyObject_client
    end

    # Initialize a new remote-object reference/proxy.
    #
    # @param [ObjectNode] client ObjectNode _connected_ to the remote node that owns the object being
    #     proxied.
    # @param [Integer] remote_id  Object ID of the remote object.
    def initialize(client, remote_id, class_name)
      @@remote_objects_map[__id__] = RemoteObjectEntry.new(client, remote_id)

      @ProxyObject_client = client
      @ProxyObject_object_id = remote_id
      @ProxyObject_class_name = class_name

      ::ObjectSpace.define_finalizer(self, ::Proc.new do |local_id|
                                       entry = @@remote_objects_map[local_id]
                                       entry.client.release(entry.remote_id) if
                                         entry.client.connection_open?
                                       @@remote_objects_map.delete(local_id)
                                     end)
    end


    # Proxy any calls to missing methods to the remote object.
    def method_missing(sym, *args, &block)
      @ProxyObject_client.invoke(self, sym, args, block,
                                 ::Proxy::ObjectNode.get_method_attributes(@ProxyObject_class_name, sym))
    end
  end
end
