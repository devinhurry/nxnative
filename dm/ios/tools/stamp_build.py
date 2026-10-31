"""Stamp the generated plist, including when tools/ is an external project's symlink."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
from build_info import main

if __name__ == '__main__':
    main()
