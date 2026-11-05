# Save archive reader fixtures

These small, synthetic RAR archives come from the libarchive v3.7.4 test suite:

- `test_read_format_rar.rar` tests refusal of an archive containing a symbolic link.
- `test_read_format_rar_windows.rar` tests ordinary RAR data import.
- `test_read_format_rar5_stored.rar` tests ordinary RAR5 data import.
- `test_read_format_rar5_compressed.rar` tests RAR5 decompression against its known payload hash.

Source: <https://github.com/libarchive/libarchive/tree/v3.7.4/libarchive/test>.
Each archive was decoded from the matching `.uu` file without modification.
The upstream distribution's license is included in [COPYING](COPYING).
No game data is included. ZIP and 7z inputs are generated during tests.
