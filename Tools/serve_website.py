#!/usr/bin/env python3
"""Serves website/ locally with HTTP range requests, which browsers need to
seek in videos (the scroll section scrubs one). Python's built-in http.server
doesn't support ranges.

    python3 Tools/serve_website.py [port]
"""

import os
import re
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class RangeHandler(SimpleHTTPRequestHandler):
    def send_head(self):
        self.range = None
        header = self.headers.get("Range")
        path = self.translate_path(self.path)
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", header or "")
        if not match or not os.path.isfile(path):
            return super().send_head()

        size = os.path.getsize(path)
        start, end = match.groups()
        if start == "":
            start, end = max(0, size - int(end)), size - 1
        else:
            start, end = int(start), int(end) if end else size - 1
        end = min(end, size - 1)
        if start > end:
            self.send_error(416, "Requested range not satisfiable")
            return None

        handle = open(path, "rb")
        handle.seek(start)
        self.range = end - start + 1
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(self.range))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        return handle

    def copyfile(self, source, outputfile):
        # Browsers cancel video downloads they no longer need; that's normal.
        try:
            if self.range is None:
                return super().copyfile(source, outputfile)
            remaining = self.range
            while remaining > 0:
                chunk = source.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                outputfile.write(chunk)
                remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def end_headers(self):
        # A local preview: always re-check files, so a re-recording shows at once.
        self.send_header("Cache-Control", "no-cache")
        if self.range is None:
            self.send_header("Accept-Ranges", "bytes")
        super().end_headers()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128   # the page preloads many clips at once


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "website")
    handler = partial(RangeHandler, directory=root)
    print(f"Serving {os.path.normpath(root)} on http://localhost:{port}")
    Server(("", port), handler).serve_forever()
