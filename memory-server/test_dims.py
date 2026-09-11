import json
import urllib.request

try:
    req = urllib.request.Request('http://localhost:11434/api/embeddings',
        data=json.dumps({"model": "qwen2.5:7b", "prompt": "test"}).encode('utf-8'),
        headers={'Content-Type': 'application/json'})
    resp = urllib.request.urlopen(req)
    data = json.loads(resp.read())
    print("qwen2.5:7b dims:", len(data['embedding']))
except Exception as e:
    print("Ollama not running locally to test")
