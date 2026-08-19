// Quick Search Setup — turn "nothing happened" into a choice.
//
// Quick Browser ships with NO default search provider, by design: a browser
// that quietly forwards everything you type to a search company is the thing
// this browser exists not to be. The cost of that decision was paid by the
// first person to use it — they typed a word in the address bar and got a
// dead error page, with nothing to say the silence was deliberate (owner
// field report, 2026-08-19).
//
// With no provider configured, Chromium treats a typed word as a hostname,
// tries to resolve it, and fails. That failure is the only reliable signal
// available to an extension, so it is what we listen for: a top-level
// navigation to a single-label host that could not resolve is, in practice,
// somebody searching. We send that tab to a page that explains and offers a
// provider, carrying the query so their search still happens.
//
// LIMIT, stated plainly: a multi-word phrase never becomes a navigation at
// all, so there is no event to catch. Those users reach the same page from
// the extension's options entry. Fixing that properly needs the omnibox
// itself, which is a browser-source change, not an extension.

// ANY failure counts, not a curated list of DNS errors. Measured in the VM:
// typing "hello" produces net::ERR_ABORTED, not ERR_NAME_NOT_RESOLVED —
// Chromium abandons the navigation rather than reporting a resolver error, so
// a listener that waited for DNS errors never fired and the user got the same
// dead page as before. The single-label host test below is what makes this
// safe: a real site has a dot, so "a bare word that failed" is a search.

function looksLikeSearch(rawUrl) {
  let u;
  try {
    u = new URL(rawUrl);
  } catch (e) {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  // A real address has a dot (example.com) or is explicitly local
  // (localhost, an IP, a host:port). A bare word has none of that.
  const host = u.hostname;
  if (!host || host.includes(".") || host === "localhost") return null;
  if (/^\d+$/.test(host)) return null;
  if (u.port) return null;
  // "chrome" -> chrome ; "chrome/downloads" -> chrome downloads
  const tail = decodeURIComponent(u.pathname || "").replace(/^\/+/, "");
  return (host + (tail ? " " + tail.replace(/\/+/g, " ") : "")).trim();
}

chrome.webNavigation.onErrorOccurred.addListener((details) => {
  if (details.frameId !== 0) return;              // main frame only
  const query = looksLikeSearch(details.url);
  if (!query) return;                             // a genuinely dead address
  const target = chrome.runtime.getURL(
    "search.html?q=" + encodeURIComponent(query));
  chrome.tabs.update(details.tabId, { url: target });
});
