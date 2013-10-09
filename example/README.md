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
# Direct request (http-2 > nghttp2)
$> ruby client.rb http://106.186.112.116/

# Direct request (nghttp2 > http-2)
$> ruby server.rb
$> nghttp -vnu http://localhost:8080       # Direct request to Ruby server
```

### node-http2

```bash
# NPN + GET request
$> ruby client.rb https://gabor.molnar.es:8080/

# NPN + GET request with server push
$> ruby client.rb https://gabor.molnar.es:8080/test/push.html

# NPN + POST request
$> ruby client.rb https://gabor.molnar.es:8080/post -d'some data'
```
