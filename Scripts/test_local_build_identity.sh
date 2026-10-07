#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$TASK_ROOT/Scripts/package_app.sh" <<'PY'
import pathlib
import subprocess
import sys

script = pathlib.Path(sys.argv[1]).read_text()
start = script.index('BUNDLE_ID="com.steipete.codexbar"')
end = script.index('resolve_package_signing_identity', start)
fragment = script[start:end]

def check(configuration, signing, override, expected, success=True):
    setup = f'LOWER_CONF={configuration}; SIGNING_MODE={signing}; CODEXBAR_LOCAL_PRODUCTION_ID={override}\n'
    result = subprocess.run(['bash', '-c', setup + fragment + '\nprintf "%s\\n%s\\n%s" "$BUNDLE_ID" "$FEED_URL" "$AUTO_CHECKS"'],
                            capture_output=True, text=True)
    assert (result.returncode == 0) == success, result.stderr
    if success:
        assert result.stdout == expected, result.stdout

check('debug', 'adhoc', '0', 'com.steipete.codexbar.debug\n\nfalse')
check('debug', 'adhoc', '1', 'com.steipete.codexbar\n\nfalse')
check('release', 'identity', '0', 'com.steipete.codexbar\nhttps://raw.githubusercontent.com/steipete/CodexBar/main/appcast.xml\ntrue')
check('debug', 'identity', '1', '', success=False)
print('Local build identity tests passed without signing or Keychain access.')
PY
