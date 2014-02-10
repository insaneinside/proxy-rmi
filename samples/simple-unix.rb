#!/usr/bin/ruby -W

# This file illustrates basic use of ProxyRMI with UNIX sockets and a test
# object that gets passed by value.

# We fork the process, and then continue as either a proxy server, or as a
# client to that server.  The server exports a single value -- the Ruby search
# path -- and the client fetches and pretty-prints it.

require 'fileutils'
require_relative '../lib/proxy.rb'

SocketFile = 'foo.sock'

$stdout.print("PIDs: server #{Process.pid}, ")
begin
  if (cpid = Process.fork)
    sleep(0.2)
    serv = Proxy::Server.new(UNIXServer, SocketFile) # Create the proxy server.

    # Uncomment the following line to get more diagnostic output from the server
    # object.
    # serv.verbose = true

    serv.add('path', $:)

    serv.run()
  else
    $stderr.puts("client #{Process.pid}")

    sleep(0.5)                  # Wait for the server to initialize.
    cli = Proxy::Client.new(UNIXSocket, SocketFile) # Create client/connect to server.

    # Uncomment the following line to get more diagnostic output from the client
    # object.
    # cli.verbose = true

    $stdout.puts('Server exports list: ' + cli.list_objects.inspect)

    ha = '`path\' value: '
    $stdout.puts(ha + cli.fetch('path').join("\n" + (' ' * ha.length)))

    cli.send_message(:shutdown) # tell the server to shut down
    cli.close
  end
rescue Exception => e
  $stderr.puts('%u: %s' % [Process.pid, e.inspect])
  $stderr.puts('    ' + e.backtrace.join("\n    "))
ensure
  FileUtils::rm_f(SocketFile)
end

$stdout.sync = true
$stdout.puts("#{Process.pid} exiting.")
$stdout.flush()
