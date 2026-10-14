import os, sys, time, json, urllib.request, urllib.error
import jwt

KEY_ID = "2S4TCQ3924"
ISSUER_ID = "7c42433f-b18c-493a-9176-872169477e7b"
KEY_PATH = os.path.expanduser("~/.appstoreconnect/private_keys/AuthKey_2S4TCQ3924.p8")
BASE = "https://api.appstoreconnect.apple.com/v1"

def make_token():
    with open(KEY_PATH) as f:
        private_key = f.read()
    now = int(time.time())
    payload = {
        "iss": ISSUER_ID,
        "iat": now,
        "exp": now + 1000,
        "aud": "appstoreconnect-v1",
    }
    headers = {"kid": KEY_ID}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)

def request(method, path, body=None):
    token = make_token()
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode(errors="replace")

if __name__ == "__main__":
    method = sys.argv[1]
    path = sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    status, result = request(method, path, body)
    print(f"STATUS {status}")
    print(json.dumps(result, indent=2) if isinstance(result, (dict, list)) else result)
