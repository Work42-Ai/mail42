# Third-party notices

mail42 includes code adapted from the following open-source project. Its license requires that the copyright
notice and permission notice be kept with copies of the code.

## che-apple-mail-mcp

- Source: https://github.com/PsychQuant/che-apple-mail-mcp
- Used in: `Sources/Mail42AppleMail/Vendor/` (the `.emlx` container and RFC 822 / MIME parsers, mailbox URL
  decoding, account mapping and the Full Disk Access probe, adapted for mail42). Each file names its upstream
  path and commit in its header. `Sources/Mail42AppleMail/EmlxLocator.swift` re-implements upstream's
  hash-directory rule for locating `.emlx` files. Upstream's `EnvelopeIndexReader` is not used: mail42 reads a
  private snapshot copy of the index with its own code.
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
- **sinkingsugar/mail-mcp** (https://github.com/sinkingsugar/mail-mcp, MIT): reference for the HTML-to-text
  approach. (mail42 keeps no search index: it reads the text of the matching messages' files.)
- **che-apple-mail-mcp** (see above): also the reference for acting on mail through Mail.app itself: AppleScript
  for read state, flags, moves and junk, and Mail's own compose window for replies and drafts. The scripts in
  `Sources/Mail42Actions/` are written for mail42 and share no code with it.
- **meet42** (https://github.com/Work42-Ai/meet42, same authors): `Sources/…/MailAvatar.swift` in the Mail42 widget
  copies meet42's avatar palette, colour hash and initials rule so a person looks the same in both.
