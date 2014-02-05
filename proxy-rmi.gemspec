# -*- coding: utf-8 -*-
Gem::Specification.new do |s|
  s.platform	= Gem::Platform::RUBY
  s.name        = 'ProxyRMI'
  s.summary     = 'Simple, lightweight, and transport-agnostic RMI implementation similar to DRb'
  s.description = <<-EOF
  ProxyRMI is a transport-agnostic remote-method-invocation service similar in many ways to DRb,
  the "distributed object system for Ruby" included in the standard library.  Unlike DRb,
  however, ProxyRMI leverages as much as possible the language's unique features to enable a
  concise and lean implementation.
EOF
  s.version     = '1.0.0'
  s.files       = [ 'lib/proxy.rb',
                    'lib/proxy/Client.rb',
                    'lib/proxy/Message.rb',
                    'lib/proxy/MessagePasser.rb',
                    'lib/proxy/Object.rb',
                    'lib/proxy/ObjectNode.rb',
                    'lib/proxy/Server.rb'
                    ]
  s.authors	= ['Collin J. Sutton']
  # s.add_runtime_dependency('gstreamer', '~> 2.0', '>= 2.0.2')
  # s.executables << 'crispcam-client' \
  # 		<< 'crispcam-daemon'
end  
