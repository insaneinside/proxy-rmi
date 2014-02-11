# -*- coding: utf-8 -*-
Gem::Specification.new do |s|
  s.platform	= Gem::Platform::RUBY
  s.name        = 'ProxyRMI'
  s.summary     = ' Transport-agnostic RMI implementation similar to dRuby (DRb)'
  s.description = <<-EOF
  ProxyRMI is a transport-agnostic remote-method-invocation service similar in many ways to
  dRuby (DRb), the "distributed object system for Ruby" included in the standard library.  Unlike
  DRb, however, ProxyRMI is designed primarily for flexibility and ease-of-use.
EOF
  s.version     = '0.1.0'
  s.files       = [ 'lib/proxy.rb',
                    'lib/proxy/Client.rb',
                    'lib/proxy/Message.rb',
                    'lib/proxy/MessagePasser.rb',
                    'lib/proxy/Object.rb',
                    'lib/proxy/ObjectNode.rb',
                    'lib/proxy/Server.rb',
                    'lib/proxy/Notifier.rb'
                    ]
  s.authors	= ['Collin J. Sutton']
end  
