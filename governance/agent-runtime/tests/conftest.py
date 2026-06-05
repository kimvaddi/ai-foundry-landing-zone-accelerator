"""Pytest configuration — put the package root on sys.path."""
from __future__ import annotations

import sys
from pathlib import Path

# governance/agent-runtime/ on sys.path so `import loader` works.
_HERE = Path(__file__).parent
_PACKAGE_ROOT = _HERE.parent
if str(_PACKAGE_ROOT) not in sys.path:
    sys.path.insert(0, str(_PACKAGE_ROOT))

# tests/ on sys.path so `import _engine` works.
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
