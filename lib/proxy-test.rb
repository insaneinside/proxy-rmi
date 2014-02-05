#!/usr/bin/ruby

load File.expand_path('../proxy.rb', __FILE__)
$-w = true
$verbose = true
begin
  if (cpid = Process.fork)
    serv = Proxy::Server.new(UNIXServer, 'foo.sock')
    serv.verbose = true
    serv.add('p', $:)
    serv.start
    serv.wait
  else
    sleep(1)
      cli = Proxy::Client.new(UNIXSocket, 'foo.sock')
      # cli.verbose = false
      $stdout.puts('Object list: ' + cli.list_objects.inspect)
      p ['path', cli.fetch('p')]
      cli.send_message(:shutdown, true)
      cli.close
  end
rescue Exception => e
  puts e.inspect
  puts '    ' + e.backtrace.join("\n    ")
end
