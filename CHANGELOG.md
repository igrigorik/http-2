## 1.0.3

### Improvements

Adopting ruby 3.3:

* Backporting required `base64` lib support (`base64` will no longer be in standard lib)
* Using the `:buffer` kwarg from `Array#pack` to reduce string allocations

## 1.0.2

### improvements

Using `#drop_while` enumerable function to drop timed out recently closed streams, which reduced the complexity of it from O(n) to O(log n), making a difference in a few benchmarks.

## 1.0.1

### Bugfixes

Active stream count on a connection is no longer interpreted as a "max number of streams" cap on a given connection, and is correctly used as "max concurrent streams". This fixes an earlier patch which was motivated by solving an h2spec compliance issue, given that upstream `http-2` had a stream accounting bug (it decrements active stream count in cases where it shouldn't, including for push streams which go from "reserved" to "closed", and it does not increent it on the "h2c upgrade" case).

This also removes support for `HTTP2Next::Connection#max_streams`, which was a "hack" to circumvent the buggy implementation, and should therefore not be used.

## 1.0.0

There are no public API breaking changes.

### Breaking changes

Set ruby 2.7 as the lowest supported ruby version.

### Chore

Removing `base64` library usage for ruby 3.3 or higher (as it's going to be removed from bundled gems).

## 0.5.1

point release to update links in rubygems.

## 0.5.0

* optimization for header decompression of static headers

it was identified that traversing the static headers table for each incoming header was one of the bottlenecks, and it was O(n) for all cases where there was not an exact match. In order to circumvent this, an additional table derived from the static headers table with the header field as lookup key was created, which eliminated the main bottleneck (at the cost of roughly 1.5Kb extra).

* several rbs signature improvements and fixes.

## 0.4.3

* fixed "string too short" error when reading headers with no value.

## 0.4.2

* force-encode data payloads to ascii while creating DATA frames.

## 0.4.1

* fixed HTTP/2 trailers (particularly the case where an end-headers flag is sent before the data, and another after data, which also closes the stream, which is valid spec-wise).
* fixed comparison on callbacks when the returned value overwrite `eql?`.

## 0.4.0

No API changes.

* `HTTPX::Buffer` has been removed, and was replaced by `String` usage with an enhanced API via refinements.
* Using `String#byteslice` in significant chunks of the parsing process.
* Removed usage of `Time.now` and replaced it with monotonic time calculations.

All of the above contributed to a massive reduction in memory usage and GC pressure.

## 0.3.0

No significant API changes. The main "features" are the RBS type signatures for the library modules.

## 0.2.6

* feature: Connection#max_streams=(int); this way one can set the max number of streams, thereby bypassing the limits established in the handshake. A lot of servers treat MAX_CONCURRENT_STREAMS not as the limit of allowed streams, but the number of inflight streams. By setting this to Float::INFINITY, users can take advantage of it.

## 0.2.5

* bugfix: fixed bookkeeping of recently-closed streams.

## 0.2.4

* bugfix: wrong window update accounting check causing random flow control errors.

## 0.2.3

* bugfix: allow stream to send empty end-stream DATA frame even if remote window is exhausted.
* avoid needless header downcase calls.
* using class_eval instead of define_method for performant lookups.

## 0.2.2

* hotfix: the connection window was being updated when receiving WINDOW_UPDATEs for a stream.

## 0.2.1

* updated syntax to be ruby 2.7 compliant and warning free

## 0.2.0

* support for the ORIGIN frame

## 0.1.2

* bugfix: do not update connection remote window on SETTINGS frame (aka the Cloudfront issue)

## 0.1.1

* fixing pseudo headers verification
* do not close stream when receiving frames from streams we've refused locally

## 0.1.0

* first release
* change namespace to move away from forked project
* make it fully compliant with h2spec
* allow frame size negotiation
