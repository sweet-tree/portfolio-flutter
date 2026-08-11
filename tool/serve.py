"""Dev server for `build/web` that never lets the browser cache anything.

`python3 -m http.server` answers repeat requests with `304 Not Modified`, so a
rebuilt `main.dart.wasm` or `scene.frag` keeps serving the OLD bytes until the
browser decides otherwise. During shader work that reads as "my change did
nothing", and we lost time to it twice — once concluding a uniform was not
arriving when the build simply had not reached the page.

This sends `no-store` on everything and refuses to answer conditional
requests, so a refresh always fetches the current build.

Not used in production: Cloudflare serves the real thing with the headers in
`web/_headers`.
"""

from __future__ import annotations

import http.server
import os
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
ROOT = sys.argv[2] if len(sys.argv) > 2 else "build/web"


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    """Serves files with caching disabled in every way a browser respects."""

    def end_headers(self) -> None:
        # Match the production headers in web/_headers: without these the dev
        # server is NOT cross-origin isolated, Flutter falls back to the
        # single-threaded renderer, and local frame rates lie about the deploy.
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def send_head(self):
        # Strip the conditional headers before the base class can honour them
        # and reply 304. Without this, no-store alone is not enough — the
        # browser still asks "has it changed?" and gets told no.
        for header in ("If-Modified-Since", "If-None-Match"):
            while header in self.headers:
                del self.headers[header]

        # ⚠️ FALL BACK TO index.html FOR ANYTHING THAT IS NOT A FILE, or real
        # URLs are only testable in production. The site uses path URLs —
        # /work, not /#/work — so every deep link is a path this server has no
        # file for, and it answered 404 while Cloudflare served the app: a bug
        # that works where you cannot debug it and fails where you can.
        #
        # The test is whether the path names something on disk, which is the
        # actual question. It was "does the last segment contain a dot", which
        # is a guess about what a filename looks like — it would have served the
        # app for a missing image and 404'd a section called /v1.2.
        target = self.translate_path(self.path)
        if not os.path.isfile(target) and not os.path.isdir(target):
            self.path = "/index.html"
        return super().send_head()

    def log_message(self, fmt: str, *args: object) -> None:
        pass  # quiet; the build output is what matters


def main() -> None:
    os.chdir(ROOT)
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", PORT), NoCacheHandler) as httpd:
        print(f"serving {ROOT} on http://localhost:{PORT} (no cache)")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
