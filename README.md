# Proxy: flexible dRuby alternative

dRuby, the "distributed-object system for Ruby" that comes bundled in the Ruby
standard library, is a great piece of code -- but it's also an
industrial-strength heavyweight with very specific use-cases and some rather
"interesting" -- by which we mean arbitrary -- limitations.

ProxyRMI (which really needs a better name) is a light-weight but flexible
alternative to dRuby; it's contained in the `Proxy` module (for now):

```ruby
require 'proxy'
```

Any IO-like object can be used as a transport by passing it as the first
argument to `Proxy::ObjectNode.new`, `Proxy::Server.new`, or
`Proxy::Client.new`.

  * `ObjectNode` contains most of the object-proxy logic, and may be useful as
    a base for custom classes.  To relieve the developer of the burden of
    reference-management, it manages a table of remotely-held proxy objects for
    local objects, and makes use of object finalizers on locally-held proxies
    to release remote objects.

    ObjectNode's initializer accepts either a class to instantiate, plus
    arguments to supply when instantiating it

    ```ruby
    ObjectNode.new(TCPSocket, '192.168.0.100', 1234)
    ```

    or an instance (or two) of an IO-like object:

    ```ruby
    ObjectNode.new(TCPSocket.new('192.168.0.100', 1234))
    ObjectNode.new([$stdin, $stdout])  # note the array!
    ```

    In the latter usage, the ObjectNode instance will use the separate streams
    for input and output.  Note that because Ruby is braindead and uses
    standard output for things like reporting uncaught exceptions (which should
    be written to standard error instead), this particular example may be
    problematic...

  * `Server` implements a mechanism for exporting an enumerable list of named
    objects to connection peers.  In addition to the instantiation styles
    supported by ObjectNode, it also provides support for multi-connection
    server functionality:

    ```ruby
    server = Proxy::Server.new(TCPServer, '0.0.0.0', 1234)
    ```

    Server-like usage is chosen whenever the first argument to `new` is a class
    _and_ responds to `open`.

  * `Client` extends ObjectNode with methods `list_objects()` (which requests a
    list of the object names exported by a Server instance), and `fetch(name)`
    (which fetches a particular exported object by name).


## This code may break _everything_
and the author provides no guarantees of safety, suitability, _or_ sanity for a
particular purpose.  ProxyRMI is still undergoing some changes in its API, and
is by no means stable enough to use in production code unless you are willing
to pick up the pieces.  No support can be provided by the author at the current
time.

ProxyRMI currently has no support for sharing a local proxy for an object that
lives on one remote node to a third-party node.  Because its connection scheme
is not necessarily heterogenous (it's designed more for flexibility instead of
consistency), any such support would likely be inefficient in the general case.


## Install
This gem has not been uploaded to the (or any) RubyGems repository; to build
and install it, use the following commands.

```shell
gem build proxy-rmi.gemspec && gem install ProxyRMI-0.1.0.gem
```

## Legalese
ProxyRMI is licensed under the GNU General Public License v2.
