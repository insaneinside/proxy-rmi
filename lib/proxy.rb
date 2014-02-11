# Define `Proxy.require' as either `load' (from IRB) or `require' (i.e., the builtin
# `Kernel.require'), depending on which was used to load this file; this ensures that _all_
# Proxy files are (re)loaded when `load' is used.
#
# - We test against the second element in `caller' because `module Proxy' creates a new entry in
#   the call stack.
#
# - `load' is already a singleton method, so we can't copy it into Proxy;
#   instead we simply call it.
#


# Provides a lightweight remote-object proxy interface similar to that provided by `drb`.
module Proxy

  meth = if RUBY_VERSION >= '1.9.1'
           method(:define_singleton_method)
         else
           method(:define_method)
         end

  # p (caller[1] =~ /^\(irb\):[0-9]+:in `load'/).nil?
  meth.call(:require,
            (caller[1] =~ /^\(irb\):[0-9]+:in `load'/).nil? \
            ? Kernel.send(:method, (Kernel.private_method_defined?(:gem_original_require) \
                                    ? :gem_original_require \
                                    : :require))
            : proc { |n| $stderr.puts "load(#{n.inspect})";
              o = begin load(n); rescue LoadError; load(n+'.rb'); end
              p o
            }
            )

  # Here we rewrite the `raise` method (inherited from Kernel) to ensure that
  # ERROR information is printed to the standard ERROR output.
  #
  # Some use cases for ProxyRMI involve scripts that communicate over `$stdin`
  # and `$stdout`; in such cases, Ruby's (very stupid) default behaviour of
  # dumping debug/error information to `$stdout` would very much confuse the
  # remote MessagePasser.
  #
  # Note that this method will be called only within the scope of the Proxy
  # module; while we _could_ directly override the implementation in Kernel,
  # it's probably impolite to do so.
  alias _raise raise
  def self.raise(*a)
    begin
      _raise(*a)
    rescue Exception => e
      $stderr.puts(e.inspect)
      $stderr.puts(e.backtrace) unless e.backtrace.nil?
    end
  end
end

['Client', 'Server'].each { |n| Proxy.require(File.expand_path('../proxy/' + n, __FILE__)) }
