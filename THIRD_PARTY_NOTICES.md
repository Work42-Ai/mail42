# Third-party notices

mail42 includes code adapted from the following open-source project. Its license requires that the copyright
notice and permission notice be kept with copies of the code.

## che-apple-mail-mcp

- Source: https://github.com/PsychQuant/che-apple-mail-mcp
- Used in: `Sources/Mail42AppleMail/Vendor/` (the Envelope Index reader, `.emlx` / MIME parsers and the Full
  Disk Access check, adapted for mail42). Each adapted file names its upstream path and commit in its header.
- License: MIT

```
MIT License

Copyright (c) 2025 Che Cheng

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Design references (no code copied)

- **himalaya** (https://github.com/pimalaya/himalaya, MIT / Apache-2.0): the `mailbox` / `envelope` /
  `message` / `attachment` command layout and `--json` convention.
- **notmuch** (https://notmuchmail.org, GPL-3.0): the search-term design (`from:`, `is:unread`,
  `date:2w..`). Only the syntax idea is used; no notmuch code is included.
- **sinkingsugar/mail-mcp** (https://github.com/sinkingsugar/mail-mcp, MIT): reference for the FTS5 indexing and
  HTML-to-text approach.
