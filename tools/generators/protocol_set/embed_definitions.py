"""Embed versioned protocol definitions into the CI-compiled tool snapshot."""
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parent
text = (root / 'definitions.yaml').read_text(encoding='utf-8')
literal = json.dumps(text, ensure_ascii=False).replace('$', r'\$')
expected = '// Generated from definitions.yaml by embed_definitions.py.\nconst protocolDefinitions = ' + literal + ';\n'
target = root / 'definitions.dart'
if sys.argv[1:] == ['--check']:
    if not target.is_file() or target.read_text(encoding='utf-8') != expected:
        raise SystemExit('Protocol definitions differ: regenerate before committing')
elif not sys.argv[1:]:
    target.write_text(expected, encoding='utf-8', newline='\n')
else:
    raise SystemExit('usage: embed_definitions.py [--check]')
