#!/usr/bin/env python3
"""Headless Playwright reference fetcher for Qstar fact-checking.

Usage: web_fetch.py <topic-or-url>

Resolution order:
  1. If the argument looks like a URL, fetch it directly.
  2. Question-form queries (contain '?' or start with a question word):
     DuckDuckGo lite search -> first result page (natural-language queries
     don't resolve as Wikipedia titles).
  3. Try https://en.wikipedia.org/wiki/<slug> (redirects resolve natively).
  4. Fall back to DuckDuckGo lite -> first result page.

Content extraction prefers article body selectors (#mw-content-text,
article, main, [role=main]) over raw <body> so nav chrome is skipped.
Pages that are Wikipedia "no article"/search-result stubs are rejected.

Prints page text to stdout (truncated to ~200KB). Exit 0 on success,
nonzero on failure. Used by src/fact_check.zig via std.process.Child.

Browser resolution: $QSTAR_HEADLESS_SHELL, then the newest
~/.cache/ms-playwright/chromium_headless_shell-*/ install, then the
playwright-managed default.
"""

import sys
import urllib.parse

MIN_TEXT = 200
MAX_TEXT = 200_000

CONTENT_SELECTORS = ["#mw-content-text", "article", "main", "[role=main]", "body"]

BAD_MARKERS = (
    "does not have an article",
    "did not match any entries",
    "Search results",
)

QUESTION_WORDS = {
    "what", "why", "how", "who", "whom", "whose", "when", "where", "which",
    "is", "are", "was", "were", "does", "do", "did", "can", "could",
    "would", "should", "tell",
}


def page_text(page, url, timeout_ms=30_000):
    page.goto(url, timeout=timeout_ms, wait_until="domcontentloaded")
    page.wait_for_timeout(1200)  # let JS settle
    for sel in CONTENT_SELECTORS:
        try:
            el = page.query_selector(sel)
            if el:
                text = el.inner_text()
                if len(text) >= MIN_TEXT:
                    return text
        except Exception:
            continue
    return page.inner_text("body")


def is_question_query(query):
    if "?" in query:
        return True
    first = query.strip().split(" ", 1)[0].lower() if query.strip() else ""
    return first in QUESTION_WORDS


def search_url(query):
    """Wikipedia full-text search page — resolves natural-language queries
    headless where DDG lite gets bot-blocked."""
    q = urllib.parse.quote_plus(query)
    return (
        "search",
        f"https://en.wikipedia.org/w/index.php?search={q}&title=Special:Search&ns0=1",
    )


def wiki_slug_url(query):
    slug = urllib.parse.quote(query.replace(" ", "_"))
    return f"https://en.wikipedia.org/wiki/{slug}"


def find_headless_shell():
    """Locate a usable chromium headless shell: env override, then the
    playwright cache (any revision), then None for playwright default."""
    import glob
    import os

    env = os.environ.get("QSTAR_HEADLESS_SHELL")
    if env and os.path.exists(env):
        return env
    hits = sorted(
        glob.glob(
            os.path.expanduser(
                "~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell"
            )
        ),
        reverse=True,  # newest revision first
    )
    return hits[0] if hits else None


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: web_fetch.py <topic-or-url>", file=sys.stderr)
        return 2
    query = sys.argv[1]

    from playwright.sync_api import sync_playwright

    with sync_playwright() as pw:
        shell = find_headless_shell()
        launch_kwargs = {"headless": True}
        if shell:
            launch_kwargs["executable_path"] = shell
        browser = pw.chromium.launch(**launch_kwargs)
        try:
            page = browser.new_page(
                user_agent="Mozilla/5.0 (X11; Linux x86_64) QstarFactCheck/1.0"
            )

            candidates = []
            if query.startswith(("http://", "https://")):
                candidates.append(query)
            elif is_question_query(query):
                candidates.append(search_url(query))
                candidates.append(wiki_slug_url(query))
            else:
                candidates.append(wiki_slug_url(query))
                candidates.append(search_url(query))

            for cand in candidates:
                try:
                    if isinstance(cand, tuple) and cand[0] == "search":
                        # Follow the first result link from the search page
                        page.goto(cand[1], timeout=30_000, wait_until="domcontentloaded")
                        link = page.query_selector(".mw-search-result-heading a")
                        if not link:
                            continue
                        href = link.get_attribute("href")
                        if not href:
                            continue
                        if href.startswith("/"):
                            href = "https://en.wikipedia.org" + href
                        text = page_text(page, href)
                    else:
                        url = cand[1] if isinstance(cand, tuple) else cand
                        text = page_text(page, url)
                    head = text[:2000]
                    if any(m in head for m in BAD_MARKERS):
                        continue
                    if len(text) >= MIN_TEXT:
                        sys.stdout.write(text[:MAX_TEXT])
                        return 0
                except Exception:
                    continue
            return 1
        finally:
            browser.close()


if __name__ == "__main__":
    sys.exit(main())
