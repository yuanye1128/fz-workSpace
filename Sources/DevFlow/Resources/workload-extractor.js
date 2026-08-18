(() => {
  const TARGET_STATUSES = ["待测试", "已完成"];
  const ISSUE_REF_IN_TEXT = /(?:#|＃)\d{3,}/;

  function text(node) {
    return node?.textContent?.trim() || "";
  }

  function unique(values) {
    return Array.from(new Set(values.filter(Boolean)));
  }

  function uniqueNodes(nodes) {
    return Array.from(new Set(Array.from(nodes)));
  }

  function normalizeWhitespace(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  function escapeRegExp(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  function extractIssueIdFromPath(pathname) {
    const match = String(pathname || "").match(/\/issues\/(\d+)(?:\/|$)/);
    return match?.[1] || "";
  }

  function extractIssueIdFromText(rawText) {
    const match = normalizeWhitespace(rawText).match(/(?:#|＃)(\d{3,})/);
    return match?.[1] || "";
  }

  function normalizeIssueUrl(href, baseUrl, fallbackText) {
    try {
      const url = new URL(href, baseUrl);
      const issueId =
        extractIssueIdFromPath(url.pathname) || extractIssueIdFromText(fallbackText || "");
      if (!issueId) return "";
      return `${url.origin}/issues/${issueId}`;
    } catch (_) {
      return "";
    }
  }

  function extractStatusesFromText(rawText) {
    if (!rawText) return [];
    return TARGET_STATUSES.filter((status) => {
      if (status === "待测试" && (/\bto\s*be\s*tested\b/i.test(rawText) || /\bfor\s*testing\b/i.test(rawText))) {
        return true;
      }
      if (status === "已完成" && /\bcompleted\b/i.test(rawText) && !/\b(incomplete|uncompleted)\b/i.test(rawText)) {
        return true;
      }
      return new RegExp(
        `(?:状态|status)[^\\n]{0,30}(?:改为|变更为|changed to|to|=>|->|→)?[^\\n]{0,12}${escapeRegExp(status)}`,
        "i"
      ).test(rawText) || new RegExp(
        `(?:改为|变更为|changed to|to)\\s*["“']?${escapeRegExp(status)}["”']?`,
        "i"
      ).test(rawText) || new RegExp(
        `[（(]\\s*${escapeRegExp(status)}\\s*([/／]|[)）])`,
        "i"
      ).test(rawText);
    });
  }

  function shiftDate(dayOffset) {
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() + dayOffset);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  }

  function normalizeDate(value) {
    const [year, month, day] = value.replace(/\//g, "-").split("-");
    return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  }

  function parseDateFromText(rawText) {
    const raw = String(rawText || "");
    const iso = raw.match(/\d{4}[-/]\d{1,2}[-/]\d{1,2}/);
    if (iso) return normalizeDate(iso[0]);
    const zh = raw.match(/(\d{4})年(\d{1,2})月(\d{1,2})日/);
    if (zh) return `${zh[1]}-${zh[2].padStart(2, "0")}-${zh[3].padStart(2, "0")}`;
    const t = raw.trim();
    if (/^今天(?:\s|$)/.test(t)) return shiftDate(0);
    if (/^昨天(?:\s|$)/.test(t)) return shiftDate(-1);
    if (/^前天(?:\s|$)/.test(t)) return shiftDate(-2);
    return "";
  }

  function parseDate(element) {
    if (!element) return "";
    const nodes = uniqueNodes([
      element,
      ...Array.from(element.querySelectorAll?.("time[datetime], [datetime], [title], [data-date]") || [])
    ]);
    for (const node of nodes) {
      for (const value of [
        node.getAttribute?.("datetime"),
        node.getAttribute?.("title"),
        node.getAttribute?.("data-date")
      ].filter(Boolean)) {
        const parsed = parseDateFromText(value);
        if (parsed) return parsed;
      }
    }
    return parseDateFromText(text(element));
  }

  function parseDateInActivityTree(el) {
    if (!el) return "";
    const tag = (el.tagName || "").toLowerCase();
    if (["dl", "ul", "ol", "table", "tbody", "thead", "tr", "tfoot"].includes(tag)) return "";
    if (tag === "dd" || tag === "dt" || tag === "li") {
      const t = el.querySelector("time[datetime]");
      return t?.getAttribute("datetime")?.slice(0, 10) || "";
    }
    if (/^(\d{4}-\d{2}-\d{2})/.test(el.getAttribute?.("data-date") || "")) {
      return el.getAttribute("data-date").slice(0, 10);
    }
    if (el.matches?.("h1, h2, h3, h4, h5, h6")) return parseDate(el);
    const firstHeading = el.querySelector?.(
      ":scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > h5, :scope > h6, :scope > time[datetime]"
    );
    if (firstHeading?.matches?.("time[datetime]")) {
      return (firstHeading.getAttribute("datetime") || "").slice(0, 10);
    }
    if (firstHeading) return parseDate(firstHeading);
    return "";
  }

  function findActivityDate(node) {
    let current = node.closest("dt, dd, li, article, tr, h4, .event, .activity-item, .journal, [class*='event']")
      || node.parentElement
      || node;
    while (current) {
      let sibling = current.previousElementSibling;
      while (sibling) {
        const fromSibling = parseDateInActivityTree(sibling);
        if (fromSibling) return fromSibling;
        const innerHead = sibling.querySelector?.("h1, h2, h3, h4, h5, h6, time[datetime], .date, .group-date, .day-title");
        if (innerHead) {
          const d = innerHead.matches("time[datetime]")
            ? (innerHead.getAttribute("datetime") || "").slice(0, 10)
            : parseDate(innerHead);
          if (d) return d;
        }
        sibling = sibling.previousElementSibling;
      }
      const own = parseDateInActivityTree(current);
      if (own) return own;
      current = current.parentElement;
    }
    return "";
  }

  function detectCurrentUserName(doc) {
    const heading = Array.from(doc.querySelectorAll("h1, h2, h3"))
      .map((node) => text(node).match(/^(.+?)\s*的活动$/))
      .find(Boolean);
    if (heading?.[1]) return heading[1];
    const selectors = ["#loggedas a.user", ".loggedas a.user", "#top-menu a.user", ".current-user"];
    for (const selector of selectors) {
      const value = text(doc.querySelector(selector));
      if (value) return value;
    }
    const loggedAs = text(doc.querySelector("#loggedas, .loggedas, #top-menu, #account"));
    const alias = loggedAs.match(/登录为\s*([A-Za-z0-9_.@-]+)/i);
    return alias?.[1] || "";
  }

  function hasActivityStreamContent(node) {
    if (!node) return false;
    if (node.querySelector('a[href*="/issues/"]')) return true;
    const raw = normalizeWhitespace(text(node));
    return ISSUE_REF_IN_TEXT.test(raw) || /\/issues\/\d{3,}/i.test(node.innerHTML || "");
  }

  function findActivityStreamRoot(doc) {
    const directRoot = doc.querySelector("#activity, .activity");
    if (directRoot && hasActivityStreamContent(directRoot)) return directRoot;
    const ownerHeading = Array.from(doc.querySelectorAll("h1, h2, h3, h4"))
      .find((node) => /的活动$/.test(text(node)));
    if (ownerHeading) {
      let sibling = ownerHeading.nextElementSibling;
      while (sibling) {
        if (hasActivityStreamContent(sibling)) return sibling;
        sibling = sibling.nextElementSibling;
      }
      return ownerHeading.parentElement || doc.body;
    }
    return doc.querySelector("#content") || doc.body;
  }

  function collectActivityEntryNodes(root) {
    const fromSelectors = uniqueNodes(
      ["dl > dd", "dd", ".activity-item", ".journal", "li"]
        .flatMap((selector) => Array.from(root.querySelectorAll(selector)))
    );
    const fromLinks = [];
    root.querySelectorAll('a[href*="/issues/"]').forEach((a) => {
      if (a.closest("#top-menu, #header, #account, #sidebar, .sidebar")) return;
      const row = a.closest("dd, li, tr, article, p, [class*='event'], [class*='activity'], .issue, .journal")
        || a.parentElement;
      if (row) fromLinks.push(row);
    });
    return uniqueNodes([...fromSelectors, ...fromLinks]).filter((node) => {
      const rawText = normalizeWhitespace(text(node));
      return rawText && (ISSUE_REF_IN_TEXT.test(rawText) || node.querySelector('a[href*="/issues/"]'));
    });
  }

  function buildActivityTitle(rawText, issueId) {
    const cleaned = normalizeWhitespace(rawText)
      .replace(new RegExp(`^.*?(?:#|＃)${escapeRegExp(issueId)}\\s*[:：-]?\\s*`), "")
      .replace(/\s*(状态|status).*$/i, "")
      .trim();
    return cleaned.slice(0, 120);
  }

  function extractTrackerFromActivityText(rawText, issueId) {
    const match = rawText.match(
      new RegExp(
        `(BUG|Support|Bug|Feature|Task|需求|支持|建议|缺陷|任务)[\\s]*[#＃]${escapeRegExp(issueId)}\\b`,
        "i"
      )
    );
    return match?.[1] || "";
  }

  function extractActivityPageDates(doc) {
    const root = findActivityStreamRoot(doc);
    return unique(
      Array.from(root.querySelectorAll("h1, h2, h3, h4, h5, h6, .date, time[datetime]"))
        .map((node) => node.matches?.("time[datetime]")
          ? (node.getAttribute("datetime") || "").slice(0, 10)
          : parseDate(node))
        .filter(Boolean)
    ).sort();
  }

  function isDisabledPaginationLink(a) {
    if (!a) return true;
    const href = a.getAttribute("href");
    if (!href || href === "#" || /^javascript:/i.test(href)) return true;
    return a.getAttribute("aria-disabled") === "true" || a.classList.contains("disabled");
  }

  function resolveNextPageUrl(a, baseUrl) {
    if (isDisabledPaginationLink(a)) return "";
    try {
      return new URL(a.getAttribute("href"), baseUrl).href;
    } catch (_) {
      return "";
    }
  }

  function collectPrevPageURL(doc, baseUrl) {
    const rel = doc.querySelector("a[rel='prev'], a[rel='previous']");
    const fromRel = resolveNextPageUrl(rel, baseUrl);
    if (fromRel) return fromRel;
    const links = Array.from(doc.querySelectorAll(".pagination a, p.pagination a, nav.pagination a, a[href*='page=']"));
    const byLabel = links.find((link) => {
      const t = text(link);
      return /上一(页|頁)|^上页$|‹|«/.test(t);
    });
    return resolveNextPageUrl(byLabel, baseUrl);
  }

  function parseOperator(element) {
    const userLink =
      element.querySelector("a.user") ||
      element.querySelector("a[href*='/users/']");
    if (userLink) return text(userLink);
    const raw = text(element);
    return raw.split(/\d{4}[-/年]\d{1,2}[-/月]\d{1,2}/)[0]
      .replace(/更新于|发表于|由|added by|updated by/gi, "")
      .trim();
  }

  function extractTargetStatusesFromText(rawText) {
    if (!rawText) return [];
    return TARGET_STATUSES.filter((status) =>
      new RegExp(
        `(?:状态|status)[^\\n]{0,40}(?:改为|变更为|changed to|to|=>|->|→)[^\\n]{0,20}${escapeRegExp(status)}`,
        "i"
      ).test(rawText) || new RegExp(
        `(?:改为|变更为|changed to|to|=>|->|→)\\s*["“']?${escapeRegExp(status)}["”']?`,
        "i"
      ).test(rawText)
    );
  }

  function extractTargetStatusesFromDetailNode(node) {
    const raw = normalizeWhitespace(text(node));
    if (!raw || !/(状态|status)/i.test(raw)) return [];
    const emphasized = Array.from(node.querySelectorAll("i, em, strong, span"))
      .map((child) => normalizeWhitespace(text(child)))
      .filter(Boolean);
    if (emphasized.length > 0) {
      const last = emphasized[emphasized.length - 1];
      if (TARGET_STATUSES.includes(last)) return [last];
      if (emphasized.length >= 2) return [];
    }
    return extractTargetStatusesFromText(raw);
  }

  function extractStatusTimeline(doc) {
    const journals = uniqueNodes(doc.querySelectorAll("#history .journal, .journal, div[id^='change-']"));
    return journals.flatMap((journal, orderIndex) => {
      const heading = journal.querySelector("h4, .journal-details, .note-header") || journal;
      const operator = parseOperator(heading);
      const changedAt = parseDate(heading) || parseDate(journal);
      if (!operator || !changedAt) return [];
      const detailNodes = uniqueNodes(
        journal.querySelectorAll("ul.details li, .details li, table.details tr, .journal-details li")
      );
      const structured = unique(detailNodes.flatMap((node) => extractTargetStatusesFromDetailNode(node)));
      const statuses = structured.length > 0
        ? structured
        : extractTargetStatusesFromText(normalizeWhitespace(text(journal)));
      return statuses.map((status) => ({ operator, changedAt, status, orderIndex }));
    }).sort((left, right) => {
      if (left.changedAt !== right.changedAt) return left.changedAt.localeCompare(right.changedAt);
      return left.orderIndex - right.orderIndex;
    });
  }

  async function fetchDocument(url) {
    const response = await fetch(url, { credentials: "include" });
    if (!response.ok) throw new Error(`请求失败 ${response.status}`);
    const html = await response.text();
    return new DOMParser().parseFromString(html, "text/html");
  }

  function isLoginDocument(doc) {
    return Boolean(doc.querySelector('#login-form, form[action*="/login"]')) ||
      (doc.location && String(doc.location.pathname || "").includes("/login"));
  }

  async function extractActivityPage(pageURL) {
    const doc = await fetchDocument(pageURL);
    if (isLoginDocument(doc)) {
      return { loginRequired: true, candidates: [], prevURL: "", pageDates: [], username: "" };
    }
    const root = findActivityStreamRoot(doc);
    const username = detectCurrentUserName(doc);
    const candidates = [];
    collectActivityEntryNodes(root).forEach((node, index) => {
      const rawText = normalizeWhitespace(text(node));
      const date = findActivityDate(node);
      const issueLink = node.matches?.("a[href]") ? node : node.querySelector('a[href*="/issues/"]');
      const url = normalizeIssueUrl(issueLink?.getAttribute("href"), pageURL, rawText);
      const issueId = extractIssueIdFromText(rawText) || extractIssueIdFromPath(url);
      if (!issueId) return;
      candidates.push({
        issueID: issueId,
        url: url || `${new URL(pageURL).origin}/issues/${issueId}`,
        date,
        statuses: extractStatusesFromText(rawText),
        title: buildActivityTitle(rawText, issueId) || `#${issueId}`,
        tracker: extractTrackerFromActivityText(rawText, issueId),
        operatorName: username,
        orderIndex: index
      });
    });
    return {
      loginRequired: false,
      username,
      candidates,
      pageDates: extractActivityPageDates(doc),
      prevURL: collectPrevPageURL(doc, pageURL)
    };
  }

  async function extractIssueTimelines(urls, concurrency) {
    const results = new Array(urls.length);
    let cursor = 0;
    const workerCount = Math.min(Math.max(1, Number(concurrency) || 12), urls.length);
    window.__devflowWorkloadAbort = false;

    function postItem(item) {
      try {
        window.webkit?.messageHandlers?.devflowWorkload?.postMessage(item);
      } catch (_) {}
    }

    async function worker() {
      while (cursor < urls.length) {
        if (window.__devflowWorkloadAbort) return;
        const index = cursor;
        cursor += 1;
        const url = urls[index];
        try {
          const doc = await fetchDocument(url);
          if (window.__devflowWorkloadAbort) return;
          const path = new URL(url).pathname;
          const issueID = extractIssueIdFromPath(path);
          const title =
            text(doc.querySelector("h2")) ||
            text(doc.querySelector(".subject h3")) ||
            `#${issueID}`;
          const tracker = text(doc.querySelector(".tracker, td.tracker")) || "";
          results[index] = {
            url,
            issueID,
            title,
            tracker,
            timeline: extractStatusTimeline(doc)
          };
        } catch (error) {
          results[index] = { url, error: String(error && error.message ? error.message : error) };
        }
        postItem(results[index]);
      }
    }
    await Promise.all(Array.from({ length: workerCount }, () => worker()));
    return results.filter(Boolean);
  }

  window.__devflowWorkload = { extractActivityPage, extractIssueTimelines };
})();
