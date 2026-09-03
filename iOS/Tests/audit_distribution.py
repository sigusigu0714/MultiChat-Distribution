"""Inspect the final unsigned IPA, including metadata and binary strings.
No authentication material or account identity belongs in this script's output.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import sys
import zipfile
from urllib.parse import urlsplit

DENIED_DIGESTS = {}  # Deployment-specific checks belong in private CI configuration.
ALLOWED_HOSTS = {
    'api.twitch.tv', 'id.twitch.tv', 'www.w3.org', 'www.apple.com',
    'chat.example.com', 'relay.example.com', 'example.com', 'example.invalid',
}
SECRET_PATTERNS = [
    rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    rb'ghp_[A-Za-z0-9]{36}', rb'github_pat_[A-Za-z0-9_]{40,}',
    rb'AKIA[A-Z0-9]{16}', rb'https://(?:discord(?:app)?\.com)/api/webhooks/\d+/[A-Za-z0-9_-]+',
]

def audit(path):
    issues = []
    with zipfile.ZipFile(path) as archive:
        files = [i for i in archive.infolist() if not i.is_dir()]
        permitted = {'MultiChatViewer', 'Info.plist', 'PkgInfo', 'Assets.car', 'AppIcon60x60@2x.png'}
        for item in files:
            prefix = 'Payload/MultiChatViewer.app/'
            if not item.filename.startswith(prefix) or item.filename[len(prefix):] not in permitted:
                issues.append('Unexpected bundled file: ' + item.filename)
            data = archive.read(item)
            for pattern in SECRET_PATTERNS:
                if re.search(pattern, data):
                    issues.append('Credential pattern in ' + item.filename)
            # Check ASCII and UTF-16 representations without printing matched values.
            texts = [data, data.decode('utf-16-le', errors='ignore').encode('utf-8'),
                     data.decode('utf-16-be', errors='ignore').encode('utf-8')]
            for text in texts:
                for match in re.finditer(rb'[\x20-\x7e]{5,}', text):
                    value = match.group().lower()
                    for digest, length in DENIED_DIGESTS.items():
                        if any(hashlib.sha256(value[i:i+length]).hexdigest() == digest
                               for i in range(len(value)-length+1)):
                            issues.append('Private identifier in ' + item.filename)
            if item.filename.endswith('/MultiChatViewer'):
                for match in re.finditer(rb'(?:https?|wss?)://[^\x00\s"<>\\]+', data):
                    url = match.group().decode('ascii', errors='ignore')
                    try:
                        host = urlsplit(url).hostname
                    except ValueError:
                        host = None
                    # UI prompts include scheme-only examples; they contain no destination.
                    if host and host not in ALLOWED_HOSTS:
                        issues.append('Non-public-service connection destination in binary')
            if item.filename.endswith('/Info.plist'):
                info = plistlib.loads(data)
                if info.get('CFBundleIdentifier') != 'org.example.multichatviewer.distribution':
                    issues.append('Unexpected distribution application identifier')
                if info.get('CFBundleDisplayName') != 'MultiChat':
                    issues.append('Unexpected display name')
        if 'Payload/MultiChatViewer.app/Info.plist' not in archive.namelist():
            issues.append('Missing application metadata')
    if issues:
        raise SystemExit('\n'.join(sorted(set(issues))))
    print(json.dumps({'result':'PASS', 'checks':['bundle contents', 'unsigned metadata',
          'credential patterns', 'embedded destinations'],
          'sha256':hashlib.sha256(Path(path).read_bytes()).hexdigest()}, indent=2))

if __name__ == '__main__':
    audit(sys.argv[1])
