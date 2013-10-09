## Interop

First, a quick test to ensure that we can talk to ourselves:

```bash
$> ruby server.rb
$> ruby client.rb http://localhost:8080/                 # GET
$> ruby client.rb http://localhost:8080/ -d 'some data'  # POST
```

### [nghttp2](https://github.com/tatsuhiro-t/nghttp2) (HTTP/2.0 C Library)

Public test server: http://106.186.112.116 (Upgrade + Direct)

```bash
$> ruby client.rb http://106.186.112.116/
```

