# -*- coding: utf-8 -*-
Gem::Specification.new do |s|
  s.platform	= Gem::Platform::RUBY
  s.name        = 'proxy-rmi'
  s.summary     = 'Fast & flexible dRuby alternative'
  s.description = <<-EOF
  ProxyRMI is a transport-agnostic remote-method-invocation service similar to
  dRuby (DRb), the "distributed object system for Ruby" included in the standard library.  Unlike
  DRb, however, ProxyRMI is designed primarily for flexibility and ease-of-use.
EOF
  s.version     = '0.3.0'
  s.files       = [ 'lib/proxy.rb',
                    'lib/proxy/attributes.rb',
                    'lib/proxy/Client.rb',
                    'lib/proxy/Message.rb',
                    'lib/proxy/MessagePasser.rb',
                    'lib/proxy/Object.rb',
                    'lib/proxy/ObjectNode.rb',
                    'lib/proxy/Server.rb',
                    'lib/proxy/ServerNode.rb',
                    'lib/proxy/ThreadedService.rb',
                    ]
  s.authors	= ['Collin J. Sutton']

  s.add_runtime_dependency('atomic', '~> 1.1')
  s.add_development_dependency('ZenTest', '~> 4.9')
end  
