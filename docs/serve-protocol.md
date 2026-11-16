# `mail42 serve`: the protocol

`mail42 serve` is one per-user daemon that answers every client that wants mail: the Mail widget, the Work42 Mac
app (for the iPad), and the `mail42` command line. It keeps Apple Mail's Envelope Index open (read-only, in place),
runs the same verbs the command line runs, sends Apple Events to Mail one at a time, and tells subscribers when
Mail changed. This file is the contract the three clients are written against.

## Where it lives

| What | Where |
|------|-------|
| Folder | `~/.work42/mail42/` (mode 0700), or `$MAIL42_SERVE_DIR` |
| Socket | `serve.sock` (mode 0600), a Unix stream socket |
| Single-instance lock | `serve.lock` (`flock`): only one daemon holds it |
| Log | `serve.log` (start, stop, version hand-over), truncated when it passes 1 MB |

Only the owner of the folder can connect, and the daemon also checks the connecting process's user id.

## Starting it

Clients never start the daemon by running it in the foreground. They run

```
~/.work42/bin/mail42 serve --detach
```

which starts the real daemon in the background (as mail42's own permission principal, the one that holds Full Disk
Access) and returns at once with status 0. Then they retry the connect every 100 ms for up to 2 s. Running it when a
daemon already exists is harmless: the new process finds the lock taken and exits.

The command line never starts the daemon itself; it uses one that is running and otherwise works alone.

The daemon exits by itself after 10 minutes with no client connected and no request in flight
(`$MAIL42_SERVE_IDLE_SECONDS` changes the 10 minutes), and removes its socket.

## Framing

One JSON object per line, UTF-8, `\n` between objects. A line is at most 1 MiB from a client; replies may be larger.
A client that sends anything else gets its connection closed.

## hello

First thing on every connection.

```json
{"hello": {"version": "0.3.0"}}
```

The daemon answers with its own version and whether it will serve this client:

```json
{"hello": {"version": "0.3.0", "ok": true}}
```

* Same version: `ok: true`.
* The client is **newer** than the daemon: `ok: false`. The daemon stops accepting new connections, finishes the
  requests already in flight, and exits (removing its socket). The client waits for the socket to go away (up to
  2 s) and starts a daemon of its own version with `serve --detach`.
* The client is **older** than the daemon: `ok: false`, and the daemon carries on. An older client must not take a
  newer daemon down. The command line then runs the verb itself; the widget reports that mail42 needs updating.

A client that gets `ok: false` sends nothing else on that connection.

## Requests

```json
{"id": 7, "verb": "message", "args": ["read", "123", "--html", "--out", "/path/m.html", "--json"]}
```

`verb` and `args` are exactly the words of the command line after `mail42` (`mail42 message read 123 --html …`).
`id` is any integer the client picks, unique among its requests in flight on the connection.

The reply:

```json
{"id": 7, "stdout": "<base64>", "stderr": "", "status": 0}
```

`stdout` is what the verb printed, base64 (it may be megabytes of HTML, and it is exactly the bytes the command line
prints); `stderr` is what it wrote to stderr; `status` is the exit status the command line would exit with (0 ok,
1 failed or not granted, 2 usage or not found). With `--json` an error is in `stdout` as
`{"error":{"code","message"}}`, exactly as on the command line. An unknown verb answers like the command line does
(usage text, status 2). Replies to different requests can arrive in any order.

### What runs where

* **Reads** (`mailbox`, `envelope`, `message`, `attachment`, `permissions` without `automation`) run at the same
  time, up to 4 at once, on one shared read connection.
* **Actions** (`mark`, `move`, `archive`, `delete`, `junk`, `draft`, `open`, `permissions automation`) ask Mail
  through Apple Events. They run strictly one at a time, in the order they arrived. A busy Mail, or the first
  Automation prompt, delays other actions but never a read.
* **Coalescing.** A `mark` that is still waiting for its turn is replaced by a later `mark` of the same message and
  the same attribute (`read`/`unread` are one attribute, `flagged`/`unflagged` another). The replaced request is
  answered with the later request's result when that one finishes, so every request gets an answer.

## cancel

```json
{"cancel": 7}
```

* A **read** that has not started is dropped. It gets **no reply**.
* A read that has started is answered at once with `{"id": 7, "stdout": "", "stderr": "", "status": 130}`; the
  verb finishes in the background and its output is discarded.
* An **action** is answered at once with status 130 whether it has started or not, but it still runs: it may be
  shared with other requests (see coalescing), and Mail may already have it. Cancel only stops waiting for its
  answer. Clients cancel reads (the message you stopped looking at), not actions.
* An unknown or finished `id` is ignored.
* When a connection closes, its reads that have not started are dropped; everything else finishes unheard.

## subscribe

```json
{"subscribe": "changes"}
```

The daemon answers with the current counters:

```json
{"subscribed": "changes", "signature": "12:830:4,13:40:0"}
```

and from then on sends, whenever they move:

```json
{"event": "changed", "signature": "12:830:4,13:40:0"}
```

The signature is every mailbox's `<id>:<total>:<unread>`, comma-separated, in id order: Apple Mail's own counters. It
moves when mail arrives, is read, flagged, moved or deleted, and only then (a write that leaves every counter as it
was sends nothing). The daemon watches Mail's index files and waits 300 ms for a burst of writes to settle, so an
event arrives within about a second of the change. A client reacts by asking again for what it shows (the list at
the depth it has, the mailbox list); the event carries no mail.

A connection can subscribe and still send requests.

## Versioning

The version is mail42's (`mail42 --version`). The protocol has no version of its own: a change that old clients
can't follow is a new mail42 version, and `hello` keeps old and new from talking to each other.
