#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Offline regression: content SSH trust must not follow the Argo CD code source.
set -eu
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
export PYTHONDONTWRITEBYTECODE=1
python3 - "$R" <<'PY'
import base64
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import yaml

root = Path(sys.argv[1])
role = root / 'ansible/roles/notes_sites'
site_tasks = yaml.safe_load((role / 'tasks/site.yml').read_text())
role_text = '\n'.join(p.read_text() for p in role.rglob('*.yml'))
assert 'argocd_repo_known_hosts' not in role_text, 'notes must not inherit code-source host keys'
print('OK   notes role has no code-source host-key dependency')
block = next(t['block'] for t in site_tasks if 'block' in t)
secret = block[0]['kubernetes.core.k8s']['definition']
expression = secret['data']['known_hosts']
assert 'notes_sites_known_hosts' in expression
assert block[0]['no_log'] and block[0]['diff'] is False
assert site_tasks[0]['ansible.builtin.include_tasks'] == 'content-host.yml'
print('OK   secret uses validated content keys and retains log protection')
sites = yaml.safe_load((root / 'gitops/sites.yaml').read_text()) or []
for site in sites:
    url = urlsplit(site['repo'])
    token = url.hostname if (url.port or 22) == 22 else f'[{url.hostname}]:{url.port}'
    keys = site.get('repo_known_hosts', [])
    assert isinstance(keys, list) and keys, 'content host pins missing'
    assert all(key.split()[0] == token for key in keys), 'wrong content host'
    lab = yaml.safe_load((root / 'infra/envs/local/lab.yaml').read_text())
    code_url = urlsplit(lab['repo_url'])
    if (url.hostname, url.port or 22) == (code_url.hostname, code_url.port or 22):
        assert keys == lab['repo_known_hosts'], 'shared SSH endpoint pins drifted'
print('OK   every configured site pins its content SSH endpoint')

if not shutil.which('ansible-playbook'):
    print('SKIP ansible-playbook missing: runtime content-trust regression')
    sys.exit(0)

# Render the real secret expression without reading or generating any private key.
key = 'ssh-ed25519 ' + base64.b64encode(b'offline-test-public-key').decode()
cases = [
    ('nondefault port with unrelated code keys', 'ssh://git@content.example.org:2200/a/b.git', [f'[content.example.org]:2200 {key}'], True),
    ('default port', 'ssh://git@other.example.org/a/b.git', [f'other.example.org {key}'], True),
    ('explicit default port', 'ssh://git@other.example.org:22/a/b.git', [f'other.example.org {key}'], True),
    ('empty content pins', 'ssh://git@content.example.org:2200/a/b.git', [], False),
    ('missing content pins', 'ssh://git@content.example.org:2200/a/b.git', None, False),
    ('wrong host', 'ssh://git@content.example.org:2200/a/b.git', [f'github.com {key}'], False),
    ('wrong port', 'ssh://git@content.example.org:2200/a/b.git', [f'content.example.org {key}'], False),
    ('string instead of list', 'ssh://git@content.example.org:2200/a/b.git', f'[content.example.org]:2200 {key}', False),
]
with tempfile.TemporaryDirectory(prefix='notes-host-test-') as tmp:
    for name, repo, keys, valid in cases:
        site = {'name': 'fixture', 'repo': repo}
        if keys is not None:
            site['repo_known_hosts'] = keys
        tasks = [
            {'name': 'Validate actual content trust tasks', 'ansible.builtin.include_tasks': str(role / 'tasks/content-host.yml')},
            {'name': 'Render actual repo secret host keys', 'ansible.builtin.set_fact': {'rendered': expression}},
            {'name': 'Compare exact content keys', 'ansible.builtin.assert': {'that': "rendered == expected"}},
        ]
        expected = base64.b64encode(('\n'.join(keys or []) + '\n').encode()).decode() if isinstance(keys, list) else ''
        play = [{'name': 'Content trust regression', 'hosts': 'localhost', 'gather_facts': False,
                 'vars': {'notes_site': site, 'argocd_repo_known_hosts': [f'github.com {key}'], 'expected': expected}, 'tasks': tasks}]
        path = Path(tmp) / 'play.yml'
        path.write_text(yaml.safe_dump(play, sort_keys=False))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', '-c', 'local', str(path)], capture_output=True, text=True)
        assert (result.returncode == 0) == valid, f'{name}: {result.stdout}\n{result.stderr}'
        print(f'OK   {name}: {"accepted" if valid else "rejected"}')
print('OK   runtime secret rendering remains independent of code-source keys')
PY
