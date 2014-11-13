raise NotImplementedError.new('ProxyRMI requires Ruby 1.9.1+.') unless RUBY_VERSION >= '1.9.1'

# Provides a lightweight remote-object proxy interface similar to that provided by `drb`.
module Proxy

  # Define `Proxy.require' as either `load' or `require' (i.e., the builtin
  # `Kernel.require'), depending on which was used to load this file; this
  # ensures that _all_ Proxy files are (re)loaded when `load' is used.
  #
  # - We test against the second element in `caller' because `module Proxy'
  #   creates a new entry in the call stack.
  #
  # - `load' is already a singleton method, so we can't copy it into Proxy;
  #   instead we simply call it.
  #

  in_load = (caller[1] =~ /in `load'/) ? true : false

  define_singleton_method(:require,
                          in_load \
                          ? proc { |n| begin load(n); rescue LoadError; load(n+'.rb'); end } \
                          : Kernel.send(:method, (Kernel.private_method_defined?(:gem_original_require) \
                                                  ? :gem_original_require \
                                                  : :require)))

  # Do similarly for `Proxy.require_relative`.
  if in_load
    def self.require_relative(path)
      path = File.join(File.dirname(caller[0]), path.to_s)
      begin load(path); rescue LoadError; load(path+'.rb'); end
    end
  else
    define_singleton_method(:require_relative, Kernel.method(:require_relative).to_proc)
  end

  # Handle missing constants by attempting to autoload the ProxyRMI file.
  def self.const_missing(sym)
    path = File.join(__FILE__.sub(/\.rb\Z/, ''), sym.to_s + '.rb')
    if File.exist?(path)
      self.require(path)
      const_get(sym)
    else
      super
    end
  end

  # Find a class by name lookup.
  #
  # @param [String] name Fully-qualified name of the class to find.
  # @param [Class,Module] start Context where the search should be started.
  def self.find_class_by_name(name, start = ::Module)
    ref = start
    name.split('::').each do |part|
      begin
        ref = ref.const_get(part.intern)
      rescue NameError
        if ref == Module
          ref = Object
          retry
        else
          raise NameError.new('Referred type `%s` is undefined at `%s`' % [name, part])
        end
      end
    end
    ref
  end
end

# Don't load library files if this file was included by one.
unless caller[0] =~ /#{Regexp.escape(__FILE__.sub(/\.rb\Z/, ''))}\/[^\/]+.rb:/
  Proxy.require_relative('proxy/Message')
  Proxy.require_relative('proxy/Object')
  Proxy.require_relative('proxy/Client')
  Proxy.require_relative('proxy/Server')
end
