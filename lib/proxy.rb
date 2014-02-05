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
end

['Client', 'Server'].each { |n| Proxy.require(File.expand_path('../proxy/' + n, __FILE__)) }
