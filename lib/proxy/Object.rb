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
    @ProxyObject_class_attributes = nil
    @ProxyObject_method_attributes = nil
    @@remote_objects_map = {}

    # Object's remote object-ID.
    # @!attribute [r] proxy_id
    #   @return [Integer]
    def proxy_id
      @ProxyObject_object_id
    end

    def proxy_client
      @ProxyObject_client
    end

    # Initialize a new remote-object reference/proxy.
    #
    # @param [ObjectNode] client ObjectNode _connected_ to the remote node that owns the object being
    #     proxied.
    # @param [Integer] remote_id  Object ID of the remote object.
    def initialize(client, remote_id, class_name = nil)
      @@remote_objects_map[__id__] = RemoteObjectEntry.new(client, remote_id)

      @ProxyObject_client = client
      @ProxyObject_object_id = remote_id

      @ProxyObject_class_attributes = nil
      @ProxyObject_method_attributes = nil
      unless class_name.nil?
        begin
          @ProxyObject_class_attributes = ::Proxy.get_class_attributes(class_name)
          @ProxyObject_method_attributes = ::Proxy.get_method_attributes(class_name)
        rescue ::TypeError
          @ProxyObject_class_attributes = nil
          @ProxyObject_method_attributes = nil
        end
      end

      ::ObjectSpace.define_finalizer(self, ::Proc.new do |local_id|
                                       entry = @@remote_objects_map[local_id]
                                       entry.client.release(entry.remote_id) if
                                         entry.client.connection_open?
                                       @@remote_objects_map.delete(local_id)
                                     end)
    end


    # Proxy any calls to missing methods to the remote object.
    def method_missing(sym, *args, &block)
      begin
        @ProxyObject_client.send(:invoke, self, sym, args, block,
                                 @ProxyObject_method_attributes.nil? \
                                   ? nil : @ProxyObject_method_attributes[sym])
      rescue ErrorMessage => err
        raise err.exception(::Kernel.caller())
      end
    end

    def kind_of?(x)
      # $stdout.puts(inspect(:PROXY_LOCAL_INSPECT) + ".#{__method__}(#{x.inspect})")
      if ::Proxy::Object === x
        false
      elsif x == ::Proxy::Object
        true
      elsif ::Proxy.constants.include?(x.name.split('::')[-1].intern)
        false
      else
        method_missing(:kind_of?, x)
      end
    end

    # `inspect` handler.
    def inspect(*a, &b)
      # $stdout.puts(Object.instance_method(:inspect).bind(self).call() + ".#{__method__}(#{x.inspect})")
      if a.size == 1 && a[0] == :PROXY_LOCAL_INSPECT and b.nil?
        "#<Proxy::Object:#{'%#x' % __id__.abs} #{@ProxyObject_class_name.nil? ? '(unknown class)' : @ProxyObject_class_name}/#{@ProxyObject_object_id}>"
      else
        method_missing(:inspect, *a, &b)
      end
    end

    def to_proc
      ::Kernel.proc { |*a| self.call(*a) }
    end
  end
end
