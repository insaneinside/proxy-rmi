#!/usr/bin/ruby

# This file illustrates basic use of ProxyRMI.  We fork the process, and then
# continue as either a remote-object proxy server, or client.  The server
# exports a two values, only one of which ProxyRMI will copy; the client fetches
# and displays both (using their `inspect` methods).

require 'fileutils'
require_relative '../lib/proxy.rb'

SocketFile = 'foo.sock'

class CustomTypeInstancesAreNotExportable
  def inspect()
    $stdout.puts("#{super()}.inspect(): running in process #{Process.pid}")
    super()
  end
end


$stdout.print("PIDs: server #{Process.pid}, ")
begin
  if (cpid = Process.fork)
    sleep(0.2)
    serv = Proxy::Server.new(UNIXServer, SocketFile) # Create the proxy server.

    # Uncomment the following line to get more diagnostic output from the server
    # object.
    # serv.verbose = true

    serv.add('path', $:)
    serv.add('an_object', CustomTypeInstancesAreNotExportable.new)

    serv.run()
  else
    $stderr.puts("client #{Process.pid}")

    sleep(1)                    # Wait for the server to initialize.
    cli = Proxy::Client.new(UNIXSocket, SocketFile) # Create client/connect to server.

    # Uncomment the following line to get more diagnostic output from the client
    # object.
    # cli.verbose = true

    $stdout.puts('Server exports list: ' + cli.list_objects.inspect)

    $stdout.puts('     `path\' object: ' + cli.fetch('path').inspect)
    $stdout.puts('`an_object\' object: ' + cli.fetch('an_object').inspect)

    cli.send_message(:shutdown, true) # tell the server to shut down
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
