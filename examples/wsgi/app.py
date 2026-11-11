"""Run via mise run wsgi -- --app-dir examples/wsgi --app app:application."""
import json

def application(environ, start_response):
    if environ['PATH_INFO'] == '/error': raise RuntimeError('example failure')
    data = environ['wsgi.input'].read(int(environ.get('CONTENT_LENGTH') or 0))
    payload = json.dumps({'method': environ['REQUEST_METHOD'], 'path': environ['PATH_INFO'],
                          'query': environ['QUERY_STRING'], 'body': data.decode('utf-8'),
                          'scheme': environ['wsgi.url_scheme']}).encode()
    start_response('200 OK', [('Content-Type', 'application/json'), ('Content-Length', str(len(payload)))])
    return [payload]
