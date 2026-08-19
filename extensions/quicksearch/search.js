// The enrolment page. Two things it must do, in this order of importance:
// give the person their search result now, and make the address bar work
// permanently if they want that. Everything here is local — the query is only
// ever sent to the provider the user clicks.

const PROVIDERS = [
  { name: "DuckDuckGo", url: "https://duckduckgo.com/?q=" },
  { name: "Google", url: "https://www.google.com/search?q=" },
  { name: "Bing", url: "https://www.bing.com/search?q=" },
  { name: "Startpage", url: "https://www.startpage.com/sp/search?query=" },
  { name: "Wikipedia", url: "https://en.wikipedia.org/w/index.php?search=" },
];

const params = new URLSearchParams(location.search);
const query = (params.get("q") || "").trim();

if (query) {
  document.getElementById("q").textContent = query;
  document.getElementById("qbox").hidden = false;
} else {
  // Opened from the extensions page rather than by a failed search.
  document.getElementById("pick-label").textContent = "Search with";
}

const row = document.getElementById("providers");
for (const p of PROVIDERS) {
  const b = document.createElement("button");
  b.textContent = p.name;
  b.addEventListener("click", () => {
    if (query) {
      location.href = p.url + encodeURIComponent(query);
    } else {
      location.href = p.url.replace(/[?&][^=]+=$/, "");
    }
  });
  row.appendChild(b);
}

// chrome://settings cannot be linked to from page content, but an extension
// page may open it in a new tab. If that is ever blocked, say where to go
// rather than leaving a button that does nothing.
document.getElementById("settings").addEventListener("click", () => {
  const url = "chrome://settings/searchEngines";
  try {
    chrome.tabs.create({ url });
  } catch (e) {
    const note = document.createElement("p");
    note.className = "note";
    note.textContent =
      "Open Settings → Search engine → Manage search engines, and set your " +
      "default there.";
    document.getElementById("settings").after(note);
  }
});
