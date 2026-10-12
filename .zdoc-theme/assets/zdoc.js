// zdoc default theme behaviour: sidebar highlighting and TOC scroll-spy.
// No framework, no dependencies.

(function () {
  "use strict";

  // Mark the link pointing at the current page in the sidebar.
  var here = location.pathname.replace(/\/index\.html$/, "/");
  here = here.replace(/\/+$/, "") || "/";

  var links = document.querySelectorAll(".sidebar__item");
  for (var i = 0; i < links.length; i++) {
    var href = links[i].getAttribute("href") || "";
    var norm = href.replace(/\/index\.html$/, "/").replace(/\/+$/, "") || "/";
    if (norm === here) {
      links[i].classList.add("is-active");
      break;
    }
  }

  // Scroll-spy for the table of contents. Uses the heading anchors the docs
  // theme generates, so it only wires up when they are present.
  var headings = document.querySelectorAll(".doc h1[id], .doc h2[id], .doc h3[id]");
  if (headings.length === 0) return;

  var tocLinks = {};
  var tocAnchors = document.querySelectorAll(".toc a[href^='#']");
  for (var j = 0; j < tocAnchors.length; j++) {
    tocLinks[tocAnchors[j].getAttribute("href").slice(1)] = tocAnchors[j];
  }

  var active = null;

  function setActive(id) {
    if (id === active) return;
    if (active && tocLinks[active]) tocLinks[active].classList.remove("is-active");
    active = id;
    if (tocLinks[id]) tocLinks[id].classList.add("is-active");
  }

  function onScroll() {
    // The last heading that has scrolled past the top of the viewport is the
    // one the reader is currently under.
    var offset = 100;
    var current = headings[0].id;
    for (var k = 0; k < headings.length; k++) {
      if (headings[k].getBoundingClientRect().top - offset <= 0) {
        current = headings[k].id;
      } else {
        break;
      }
    }
    setActive(current);
  }

  var ticking = false;
  window.addEventListener(
    "scroll",
    function () {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(function () {
        onScroll();
        ticking = false;
      });
    },
    { passive: true }
  );

  onScroll();
})();
// ------------------------------------------------------------------- search
//
// The index is fetched on the first keystroke rather than on load: a reader
// who never searches never downloads it, and on a large site that file is
// larger than every page put together.
(function search() {
  "use strict";

  var input = document.getElementById("search-input");
  var results = document.getElementById("search-results");
  var meta = document.querySelector('meta[name="zdoc-search-index"]');
  if (!input || !results || !meta) return;

  var index = null;
  var loading = null;

  function load() {
    if (index) return Promise.resolve(index);
    if (loading) return loading;
    loading = fetch(meta.getAttribute("content"))
      .then(function (r) {
        if (!r.ok) throw new Error("search index: " + r.status);
        return r.json();
      })
      .then(function (data) {
        index = data;
        return data;
      })
      .catch(function (err) {
        // A failed index must not break the page. Search simply stops
        // offering results, which is far better than an unhandled rejection
        // on every keystroke.
        console.warn(err);
        input.disabled = true;
        return null;
      });
    return loading;
  }

  // Byte bigrams, lowercased, packed into one number. This has to agree
  // exactly with `src/docs/Search.zig`: the index is written in Zig and read
  // here, and a disagreement shows up as a search that silently finds
  // nothing.
  function bigrams(text) {
    var bytes = new TextEncoder().encode(text.toLowerCase());
    var out = [];
    for (var i = 0; i + 1 < bytes.length; i++) {
      out.push((bytes[i] << 8) | bytes[i + 1]);
    }
    return out;
  }

  // Records that contain every bigram of the query, best first.
  //
  // Two rules, and both are load-bearing:
  //
  //   - A record must match ALL of the query's known bigrams. Scoring by how
  //     many it matched instead would let a query nobody has ever typed
  //     return results: "zzzqqq" shares a bigram or two with real prose and
  //     would come back with ten pages, which reads as "search is broken".
  //
  //   - At least half the query's bigrams must be in the index at all. A
  //     query that is mostly unknown is either a typo or nonsense, and
  //     answering it from the one common bigram it contains is worse than
  //     answering nothing.
  function rank(query) {
    var grams = bigrams(query);
    if (grams.length === 0) return [];

    var lists = [];
    for (var i = 0; i < grams.length; i++) {
      var list = index.k[grams[i].toString(16)];
      if (list) lists.push(list);
    }
    if (lists.length === 0) return [];
    if (lists.length * 2 < grams.length) return [];

    // Intersect smallest-first: the result can only shrink, so starting with
    // the shortest list does the least work.
    lists.sort(function (a, b) {
      return a.length - b.length;
    });

    var counts = new Map();
    var shortest = lists[0];
    for (var s = 0; s < shortest.length; s++) {
      var id = shortest[s];
      var inAll = true;
      for (var l = 1; l < lists.length; l++) {
        var other = lists[l];
        var found = false;
        for (var m = 0; m < other.length; m++) {
          if (other[m] === id) {
            found = true;
            break;
          }
        }
        if (!found) {
          inAll = false;
          break;
        }
      }
      if (inAll) counts.set(id, lists.length);
    }

    var hits = [];
    counts.forEach(function (_score, id) {
      hits.push(id);
    });
    // A record whose heading is close to the query is more likely to be what
    // the reader meant than one that only mentions it in passing.
    hits.sort(function (a, b) {
      return index.r[a].h.length - index.r[b].h.length;
    });
    return hits.slice(0, 20).map(function (id) {
      return index.r[id];
    });
  }

  var MAX_RESULTS = 20;

  function show(query) {
    results.innerHTML = "";
    if (!query) {
      results.hidden = true;
      return;
    }

    var rows = rank(query).slice(0, MAX_RESULTS);
    if (rows.length === 0) {
      var none = document.createElement("li");
      none.className = "search__empty";
      none.textContent = "No results";
      results.appendChild(none);
    }

    rows.forEach(function (row) {
      var li = document.createElement("li");
      var a = document.createElement("a");
      // `textContent`, never `innerHTML`: the indexed text is the author's
      // prose, and rendering it as markup would be an injection point.
      a.href = row.u + (row.a ? "#" + row.a : "");
      a.className = "search__result";

      var title = document.createElement("span");
      title.className = "search__result-title";
      title.textContent = row.h || row.t;
      a.appendChild(title);

      if (row.h) {
        var page = document.createElement("span");
        page.className = "search__result-page";
        page.textContent = row.t;
        a.appendChild(page);
      }

      li.appendChild(a);
      results.appendChild(li);
    });

    results.hidden = false;
  }

  var pending = null;
  input.addEventListener("input", function () {
    var query = input.value.trim();
    if (query.length < 2) {
      show("");
      return;
    }
    clearTimeout(pending);
    pending = setTimeout(function () {
      load().then(function (data) {
        if (data) show(query);
      });
    }, 120);
  });

  // Escape closes the results, which is what every other search box does.
  input.addEventListener("keydown", function (ev) {
    if (ev.key === "Escape") {
      input.value = "";
      show("");
      input.blur();
    } else if (ev.key === "Enter") {
      var first = results.querySelector("a");
      if (first) {
        ev.preventDefault();
        window.location.href = first.href;
      }
    }
  });

  document.addEventListener("click", function (ev) {
    if (!results.contains(ev.target) && ev.target !== input) {
      results.hidden = true;
    }
  });
})();
