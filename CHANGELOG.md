## 1.0.2

### Improvements

* Freezing static tables (used for header huffman coding) correctly. This makes them shareable, which makes `http-2` usable across ractors.
* Moved buffer helpers from String refinements into mixins. Refinements impose a relevant performance penalty, unfortunately, despite its cleaner API.

## 1.0.1

### Improvements

* discard closed streams from the connection (reduces memory consumption).

### Bugfixes

* allow RST_STREAM frames to be ignored on closed streams.
* prevent already closed streams from being initialized again.

## 1.0.0

### Breaking changes

Set ruby 2.7 as the lowest supported ruby version.

There are no public API breaking changes.

### Improvements

* it passes the h2spec compliance suite.
* RBS signatures.
* ruby 3.3: Backporting required `base64` lib support (`base64` will no longer be in standard lib)
* Using the `:buffer` kwarg from `Array#pack` to reduce string allocations
* Using `#drop_while` enumerable function to drop timed out recently closed streams, which reduced the complexity of it from O(n) to O(log n), making a difference in a few benchmarks.
* optimization for header decompression of static headers.
  * it was identified that traversing the static headers table for each incoming header was one of the bottlenecks, and it was O(n) for all cases where there was not an exact match. In order to circumvent this, an additional table derived from the static headers table with the header field as lookup key was created, which eliminated the main bottleneck (at the cost of roughly 1.5Kb extra).
* `HTTPX::Buffer` has been removed, and was replaced by `String` usage with an enhanced API via refinements.
* Using `String#byteslice` in significant chunks of the parsing process.
* Removed usage of `Time.now` and replaced it with monotonic time calculations.
* avoid needless header downcase calls.
* using class_eval instead of define_method for performant lookups.
* support for the ORIGIN frame.

### Bugfixes

* force-encode data payloads to ascii while creating DATA frames.
* fixed "string too short" error when reading headers with no value.
* fixed HTTP/2 trailers (particularly the case where an end-headers flag is sent before the data, and another after data, which also closes the stream, which is valid spec-wise).
* fixed comparison on callbacks when the returned value overwrite `eql?`.
* bugfix: fixed bookkeeping of recently-closed streams.
* bugfix: wrong window update accounting check causing random flow control errors.
* bugfix: allow stream to send empty end-stream DATA frame even if remote window is exhausted.
* fix: the connection window was being updated when receiving WINDOW_UPDATEs for a stream.
* bugfix: do not update connection remote window on SETTINGS frame (aka the Cloudfront issue).
* do not close stream when receiving frames from streams we've refused locally

### Chore

Removing `base64` library usage for ruby 3.3 or higher (as it's going to be removed from bundled gems).
