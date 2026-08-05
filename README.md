# portfolio

My developer portfolio, built in Flutter and compiled to WebAssembly.

**Live:** https://portfolio-flutter-7gk.pages.dev

Building the site in Flutter rather than in HTML is the point of it: the site is
itself the sample. It is web only — there is no iOS or Android target, and
"mobile" here means a phone browser.

## Running it

```sh
make dev-dtd   # development server on :8099
make check     # analyze + tests
make build     # release build (WebAssembly)
make size      # what a visitor actually downloads, gzipped
```

Tests run with `--platform chrome`, not on the Dart VM. Anything touching a
browser API fails to compile for the VM target, so a VM test would either fail
to load or test a build that never ships.

## Deployment

Pushing to `main` runs `.github/workflows/deploy.yml`: analyze, test, build for
WebAssembly, then publish to Cloudflare Pages. Pull requests get their own
preview URL.

Two things in that pipeline are deliberate and easy to undo by accident:

- **`web/_headers` sets `max-age=0, must-revalidate` on everything.** Flutter's
  web output is not content-hashed — `main.dart.wasm` and friends keep the same
  filenames forever while their contents change every build — so caching them as
  immutable makes deploys invisible.
- **No service worker.** Flutter's serves the cached build and updates in the
  background, which means "I deployed a fix" and "you can see the fix" become
  different events. `web/index.html` is hand-written to skip registering it.

## Dependencies

Deliberately few, since every one costs download size on a page whose job is to
load fast for a stranger.

- `go_router` — this is a website, so `/work/<project>` has to be a real URL that
  survives a refresh and can be pasted into a CV.
- `web` — browser APIs for the `?stats=1` overlay.
- `very_good_analysis` — stricter lints than the default set.

## Structure

```
lib/main.dart          app shell: routes, theme, page scaffold
lib/src/               everything else
web/_headers           cache and security headers (read the comments)
web/index.html         hand-written; no service worker, Open Graph tags
```

`?stats=1` shows frame rate, which build is running (JavaScript or WebAssembly),
and the viewport — the numbers only mean anything measured on a real device
against the real deployment.
