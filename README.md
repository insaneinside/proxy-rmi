Proxy: Simple, Lightweight Remote-Method Invocation for Ruby
===

dRuby, the "distributed-object system for Ruby" that comes bundled in the Ruby
standard library, is a great piece of code -- but it's also an
industrial-strength heavyweight with very specific use-cases and some rather
"interesting" -- by which we mean arbitrary -- limitations.

ProxyRMI is a light-weight alternative to dRuby that does what it needs to do,
and little else.  Using a custom transport is as easy as passing to
`ObjectNode.new` any object that has `read` and `write` methods.


This README will be expanded at some point in the future (during my  *oodles* of
free time).

[The "oodles of free time" bit was sarcasm, if you couldn't tell.]


Legalese
---
ProxyRMI is licensed under the GNU General Public License v2.
