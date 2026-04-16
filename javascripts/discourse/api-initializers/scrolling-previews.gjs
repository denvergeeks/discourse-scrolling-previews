import { apiInitializer } from "discourse/lib/api";

const PREVIEW_ID = "topic-list-scroll-preview";
const RAIL_ID = "topic-list-fast-rail";
const THUMB_ID = "topic-list-fast-thumb";
const MOBILE_TOGGLE_ID = "topic-preview-mobile-toggle";

const EDGE_ZONE_PX = 72;
const MIN_THUMB_HEIGHT = 48;
const MOBILE_MAX_WIDTH = 767;
const BOOT_MAX_TRIES = 40;
const BOOT_RETRY_MS = 120;
const EXCERPT_LENGTH = 300;
const FETCH_DEBOUNCE_MS = 120;
const PREFETCH_RANGE = 2;

/* UI-only settings: edit these directly in the JS tab */
const MOBILE_PREVIEW_ENABLED_DEFAULT = false;
const MOBILE_PREVIEW_CARD_CLICKABLE = true;
const MOBILE_PREVIEW_SOUND_ENABLED = true;

const PREVIEW_DENSITY = "default"; // compact | default | cozy
const PREVIEW_TITLE_LINES = 2;
const PREVIEW_EXCERPT_LINES = 5;
const PREVIEW_HEIGHT_MODE = "fixed"; // fixed | max
/* const PREVIEW_CARD_HEIGHT = "clamp(168px, 26vh, 240px)"; */
const PREVIEW_CARD_HEIGHT = "clamp(168px, 32vh, 280px)";
const PREVIEW_CARD_MAX_HEIGHT = "clamp(168px, 32vh, 280px)";

const excerptCache = new Map();
const excerptInflight = new Map();

function clamp(n, min, max) {
  return Math.min(Math.max(n, min), max);
}

function debounce(fn, delay) {
  let timer = null;
  return (...args) => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => fn(...args), delay);
  };
}

function rafThrottle(fn) {
  let queued = false;
  let lastArgs = null;

  return (...args) => {
    lastArgs = args;
    if (queued) return;

    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      fn(...lastArgs);
    });
  };
}

function isDiscoveryRoute() {
  const path = window.location.pathname;
  return (
    path === "/" ||
    path.startsWith("/latest") ||
    path.startsWith("/new") ||
    path.startsWith("/top") ||
    path.startsWith("/categories") ||
    path.startsWith("/c/") ||
    path.startsWith("/tag/") ||
    path.startsWith("/tags")
  );
}

function isMobileViewport() {
  return window.innerWidth <= MOBILE_MAX_WIDTH;
}

function prefersReducedMotion() {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

function destroyExistingInstance() {
  if (window.__topicListPreviewCleanup) {
    window.__topicListPreviewCleanup();
    window.__topicListPreviewCleanup = null;
  }

  document.getElementById(PREVIEW_ID)?.remove();
  document.getElementById(RAIL_ID)?.remove();
  document.getElementById(MOBILE_TOGGLE_ID)?.remove();
  document.body.classList.remove("topic-preview--dragging");
  document.documentElement.classList.remove("topic-preview--enabled");
  document.documentElement.classList.remove("topic-preview-mobile-active");
  delete document.documentElement.dataset.topicPreviewDensity;
}

function getTopicRows(listEl) {
  return Array.from(listEl.querySelectorAll("tr.topic-list-item"));
}

function stripHtml(html) {
  const div = document.createElement("div");
  div.innerHTML = html || "";
  return (div.textContent || div.innerText || "").replace(/\s+/g, " ").trim();
}

function topicJsonUrl(topicUrl) {
  if (!topicUrl) return null;

  let url = topicUrl;
  if (url.startsWith("/")) {
    url = `${window.location.origin}${url}`;
  }

  return url.replace(/\/\d+$/, "").replace(/\/$/, "") + ".json";
}

async function fetchTopicExcerpt(topicUrl) {
  const jsonUrl = topicJsonUrl(topicUrl);
  if (!jsonUrl) return "";

  if (excerptCache.has(jsonUrl)) {
    return excerptCache.get(jsonUrl);
  }

  if (excerptInflight.has(jsonUrl)) {
    return excerptInflight.get(jsonUrl);
  }

  const request = fetch(jsonUrl, {
    credentials: "same-origin",
    headers: {
      "X-Requested-With": "XMLHttpRequest"
    }
  })
    .then((response) => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json();
    })
    .then((topic) => {
      const cooked = topic?.post_stream?.posts?.[0]?.cooked || "";
      const excerpt = stripHtml(cooked).slice(0, EXCERPT_LENGTH);
      excerptCache.set(jsonUrl, excerpt);
      excerptInflight.delete(jsonUrl);
      return excerpt;
    })
    .catch(() => {
      excerptCache.set(jsonUrl, "");
      excerptInflight.delete(jsonUrl);
      return "";
    });

  excerptInflight.set(jsonUrl, request);
  return request;
}

function extractTopicData(row) {
  if (!row) {
    return {
      title: "",
      category: "",
      excerpt: "",
      url: "",
      replies: "",
      views: "",
      activity: "",
      postersHtml: "",
      tags: []
    };
  }

  const mainLinkCell = row.querySelector("td.main-link");
  const titleEl =
    mainLinkCell?.querySelector("a.title") ||
    mainLinkCell?.querySelector(".link-top-line a") ||
    row.querySelector("a.title");

  const categoryEl =
    mainLinkCell?.querySelector(".badge-category") ||
    mainLinkCell?.querySelector("a[href*='/c/']") ||
    row.querySelector("a[href*='/c/']");

  const tagEls = Array.from(
    mainLinkCell?.querySelectorAll(".discourse-tag, a.discourse-tag, a[href*='/tag/']") || []
  );

  const postersCell = row.querySelector("td.posters") || row.querySelector(".posters");
  const repliesCell =
    row.querySelector("td.num.posts-map") ||
    row.querySelector("td.posts") ||
    row.querySelector("td.num:nth-of-type(1)");
  const repliesEl = repliesCell?.querySelector("a") || repliesCell;

  const viewsCell =
    row.querySelector("td.num.views") ||
    row.querySelector("td.views") ||
    row.querySelector("td.num:nth-of-type(2)");

  const activityCell =
    row.querySelector("td.activity") ||
    row.querySelector("td.age") ||
    row.querySelector("td:last-child");
  const activityEl = activityCell?.querySelector("a") || activityCell;

  let postersHtml = "";

  if (postersCell) {
    const posterLinks = Array.from(postersCell.querySelectorAll("a")).slice(0, 5);
    postersHtml = posterLinks
      .map((link) => {
        const img = link.querySelector("img");
        const avatarSrc =
          img?.getAttribute("src") ||
          img?.getAttribute("srcset")?.split(" ")[0] ||
          "";
        const alt = img?.getAttribute("alt") || link.getAttribute("title") || "user";

        if (!avatarSrc) return "";
        return `<img class="topic-preview__avatar" src="${avatarSrc}" alt="${alt}">`;
      })
      .join("");
  }

  const title = titleEl?.textContent?.trim() || "";
  const category = categoryEl?.textContent?.trim() || "";
  const tags = tagEls.map((el) => el.textContent.trim()).filter(Boolean);
  const url = titleEl?.getAttribute("href") || "";

  let excerpt = "";
  if (tags.length) {
    excerpt = `Filed in ${category}${tags.length ? ` · Tagged ${tags.slice(0, 3).join(", ")}` : ""}`;
  } else if (category) {
    excerpt = `Filed in ${category}`;
  }

  return {
    title,
    category,
    excerpt,
    url,
    tags,
    replies: repliesEl?.textContent?.trim() || "0",
    views: viewsCell?.textContent?.trim() || "0",
    activity: activityEl?.textContent?.trim() || "",
    postersHtml
  };
}

function getScrollMetrics() {
  const doc = document.documentElement;
  const viewport = window.innerHeight;
  const scrollHeight = doc.scrollHeight;
  const maxScroll = Math.max(1, scrollHeight - viewport);
  return { viewport, scrollHeight, maxScroll };
}

function getThumbMetrics() {
  const { viewport, scrollHeight } = getScrollMetrics();
  const thumbHeight = clamp(
    (viewport / scrollHeight) * viewport,
    MIN_THUMB_HEIGHT,
    viewport * 0.35
  );
  const maxThumbTop = Math.max(1, viewport - thumbHeight - 16);
  return { thumbHeight, maxThumbTop };
}

function syncThumbPosition(thumb) {
  const { maxScroll } = getScrollMetrics();
  const { thumbHeight, maxThumbTop } = getThumbMetrics();
  const ratio = maxScroll > 0 ? window.scrollY / maxScroll : 0;
  const top = 8 + ratio * maxThumbTop;

  thumb.style.height = `${thumbHeight}px`;
  thumb.style.transform = `translateY(${top}px)`;
  thumb.dataset.top = String(top);
  thumb.dataset.height = String(thumbHeight);

  return { top, thumbHeight, maxThumbTop, ratio };
}

function findTopicIndexFromRatio(listEl, ratio) {
  const rows = getTopicRows(listEl);
  if (!rows.length) return -1;
  return clamp(Math.round(ratio * (rows.length - 1)), 0, rows.length - 1);
}

function findTopicIndexNearViewport(listEl) {
  const rows = getTopicRows(listEl);
  if (!rows.length) return -1;

  const probeY = window.innerHeight * 0.35;
  let bestIndex = -1;
  let bestDistance = Infinity;

  rows.forEach((row, index) => {
    const rect = row.getBoundingClientRect();
    if (rect.bottom <= 0 || rect.top >= window.innerHeight) return;

    const mid = rect.top + rect.height / 2;
    const distance = Math.abs(mid - probeY);

    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = index;
    }
  });

  return bestIndex;
}

function positionPreviewDesktop(preview, thumbTop, thumbHeight) {
  const previewHeight = preview.offsetHeight || 190;
  const y = clamp(
    thumbTop + thumbHeight / 2 - previewHeight / 2,
    8,
    window.innerHeight - previewHeight - 8
  );
  preview.style.top = `${y}px`;
  preview.style.bottom = "auto";
}

function positionPreviewMobile(preview) {
  preview.style.top = "auto";
  preview.style.bottom = "calc(env(safe-area-inset-bottom, 0px) + 12px)";
}

function renderPreview(preview, data) {
  if (!data.title) {
    preview.classList.remove("show");
    return;
  }

  preview.querySelector(".topic-preview__category").textContent = data.category || "";
  preview.querySelector(".topic-preview__title").textContent = data.title;
  preview.querySelector(".topic-preview__excerpt").textContent = data.excerpt || "";
  preview.querySelector(".topic-preview__posters").innerHTML = data.postersHtml || "";
  preview.querySelector(".topic-preview__replies").textContent = data.replies || "0";
  preview.querySelector(".topic-preview__views").textContent = data.views || "0";
  preview.querySelector(".topic-preview__activity").textContent = data.activity || "";

  preview.classList.toggle("has-category", !!data.category);
  preview.classList.toggle("has-posters", !!data.postersHtml);
  preview.classList.toggle("has-excerpt", !!data.excerpt);
  preview.classList.add("show");
}

function createUi(mobileMode) {
  const rail = document.createElement("div");
  rail.id = RAIL_ID;
  rail.className = "topic-fast-scroll";
  rail.setAttribute("aria-hidden", "true");

  rail.innerHTML = `
    <div class="topic-fast-scroll__track"></div>
    <div id="${THUMB_ID}" class="topic-fast-scroll__thumb"></div>
  `;

  const preview = document.createElement("div");
  preview.id = PREVIEW_ID;
  preview.className = "topic-preview";
  preview.setAttribute("aria-hidden", "true");

  if (mobileMode) {
    preview.classList.add("topic-preview--mobile");
  }

  preview.innerHTML = `
    <div class="topic-preview__category"></div>
    <div class="topic-preview__title"></div>
    <div class="topic-preview__excerpt"></div>
    <div class="topic-preview__posters"></div>
    <div class="topic-preview__meta">
      <div class="topic-preview__stat">
        <span class="topic-preview__label">Replies</span>
        <span class="topic-preview__replies"></span>
      </div>
      <div class="topic-preview__stat">
        <span class="topic-preview__label">Views</span>
        <span class="topic-preview__views"></span>
      </div>
      <div class="topic-preview__stat">
        <span class="topic-preview__label">Activity</span>
        <span class="topic-preview__activity"></span>
      </div>
    </div>
  `;

  document.body.appendChild(rail);
  document.body.appendChild(preview);
  document.documentElement.classList.add("topic-preview--enabled");

  return {
    rail,
    thumb: rail.querySelector(`#${THUMB_ID}`),
    preview
  };
}

function applyPreviewCssSettings(preview) {
  const root = document.documentElement;

  root.dataset.topicPreviewDensity = PREVIEW_DENSITY;

  preview.style.setProperty("--topic-preview-title-lines", String(PREVIEW_TITLE_LINES));
  preview.style.setProperty("--topic-preview-excerpt-lines", String(PREVIEW_EXCERPT_LINES));
  preview.style.setProperty("--topic-preview-card-height", PREVIEW_CARD_HEIGHT);
  preview.style.setProperty("--topic-preview-card-max-height", PREVIEW_CARD_MAX_HEIGHT);

  preview.dataset.heightMode = PREVIEW_HEIGHT_MODE;
}

function ensureMobileHeaderButton(onToggle) {
  const header =
    document.querySelector(".d-header .header-buttons") ||
    document.querySelector(".d-header-icons") ||
    document.querySelector(".d-header .panel");

  if (!header) return null;

  let button = document.getElementById(MOBILE_TOGGLE_ID);
  if (button) return button;

  button = document.createElement("button");
  button.id = MOBILE_TOGGLE_ID;
  button.className = "btn btn-flat topic-preview-mobile-toggle";
  button.type = "button";
  button.setAttribute("aria-pressed", "false");
  button.setAttribute("title", "Toggle topic preview");
  button.innerHTML = `
    <span class="topic-preview-mobile-toggle__icon" aria-hidden="true">👁️</span>
    <span class="topic-preview-mobile-toggle__label">Preview</span>
  `;

  button.addEventListener("click", onToggle);
  header.prepend(button);

  return button;
}

function updateMobileHeaderButton(button, active) {
  if (!button) return;
  button.setAttribute("aria-pressed", active ? "true" : "false");
  button.classList.toggle("is-active", active);
}

function createClickSynth() {
  const AudioCtx = window.AudioContext || window.webkitAudioContext;
  if (!AudioCtx) return null;

  const ctx = new AudioCtx();

  return {
    ctx,
    unlocked: false,
    async unlock() {
      if (ctx.state === "suspended") {
        await ctx.resume();
      }
      this.unlocked = true;
    },
    play() {
      if (!this.unlocked) return;
      if (!MOBILE_PREVIEW_SOUND_ENABLED) return;
      if (prefersReducedMotion()) return;

      const now = ctx.currentTime;
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();

      osc.type = "square";
      osc.frequency.setValueAtTime(1100, now);
      osc.frequency.exponentialRampToValueAtTime(780, now + 0.03);

      gain.gain.setValueAtTime(0.0001, now);
      gain.gain.exponentialRampToValueAtTime(0.03, now + 0.003);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.04);

      osc.connect(gain);
      gain.connect(ctx.destination);

      osc.start(now);
      osc.stop(now + 0.045);
    }
  };
}

function isNearRightEdge(clientX) {
  return window.innerWidth - clientX <= EDGE_ZONE_PX;
}

function setScrollFromThumbTop(thumbTop) {
  const { maxScroll } = getScrollMetrics();
  const { maxThumbTop } = getThumbMetrics();
  const ratio = clamp((thumbTop - 8) / maxThumbTop, 0, 1);
  window.scrollTo({ top: ratio * maxScroll, behavior: "auto" });
  return ratio;
}

function shouldEnableFeature() {
  return isDiscoveryRoute();
}

function bootPreviewInstance(listEl) {
  const mobileMode = isMobileViewport();
  const { rail, thumb, preview } = createUi(mobileMode);
  applyPreviewCssSettings(preview);

  const rows = getTopicRows(listEl);

  let dragging = false;
  let dragOffsetY = 0;
  let hideTimer = null;
  let activeTopicUrl = "";
  let mobilePreviewActivated = MOBILE_PREVIEW_ENABLED_DEFAULT;
  let mobileCurrentIndex = -1;

  const clickSynth = createClickSynth();

  const reducedMotion = prefersReducedMotion();
  preview.classList.toggle("reduced-motion", reducedMotion);
  rail.classList.toggle("reduced-motion", reducedMotion);

  const debouncedHydrateExcerpt = debounce((data) => {
    if (!data.url) return;

    const topicUrl = data.url;
    fetchTopicExcerpt(topicUrl).then((excerpt) => {
      if (!excerpt) return;
      if (activeTopicUrl !== topicUrl) return;

      preview.querySelector(".topic-preview__excerpt").textContent = excerpt;
      preview.classList.add("has-excerpt");
    });
  }, FETCH_DEBOUNCE_MS);

  function prefetchNearby(index) {
    if (index < 0) return;

    for (let offset = 1; offset <= PREFETCH_RANGE; offset++) {
      [index - offset, index + offset].forEach((i) => {
        const row = rows[i];
        if (!row) return;
        const data = extractTopicData(row);
        if (data.url) {
          fetchTopicExcerpt(data.url);
        }
      });
    }
  }

  function hydrateAndPrefetch(data, index) {
    activeTopicUrl = data.url || "";
    debouncedHydrateExcerpt(data);
    prefetchNearby(index);
  }

  function applyClickableState() {
    preview.dataset.clickable =
      mobileMode && mobilePreviewActivated && MOBILE_PREVIEW_CARD_CLICKABLE
        ? "true"
        : "false";
  }

  function showUi() {
    preview.classList.add("show");

    if (!mobileMode) {
      rail.classList.add("show");
    }

    if (hideTimer) clearTimeout(hideTimer);
  }

  function hideUiSoon() {
    if (hideTimer) clearTimeout(hideTimer);

    hideTimer = setTimeout(() => {
      if (!dragging) {
        preview.classList.remove("show");
        if (!mobileMode) {
          rail.classList.remove("show");
        }
      }
    }, reducedMotion ? 0 : 180);
  }

  function updateMobileRootState() {
    document.documentElement.classList.toggle(
      "topic-preview-mobile-active",
      mobileMode && mobilePreviewActivated
    );
    applyClickableState();
  }

  function updateDesktopFromRatio(ratio) {
    const index = findTopicIndexFromRatio(listEl, ratio);
    const row = index >= 0 ? rows[index] : null;
    const data = extractTopicData(row);

    renderPreview(preview, data);

    const { top, thumbHeight } = syncThumbPosition(thumb);
    positionPreviewDesktop(preview, top, thumbHeight);

    hydrateAndPrefetch(data, index);
  }

  const throttledUpdateDesktopFromRatio = rafThrottle(updateDesktopFromRatio);

  function updateDesktopFromCurrentScroll() {
    const { ratio } = syncThumbPosition(thumb);
    throttledUpdateDesktopFromRatio(ratio);
  }

  function updateMobileFromViewport(force = false) {
    if (!mobileMode || !mobilePreviewActivated) return;

    const index = findTopicIndexNearViewport(listEl);
    if (index < 0) return;
    if (!force && index === mobileCurrentIndex) return;

    mobileCurrentIndex = index;

    const row = rows[index];
    const data = extractTopicData(row);

    renderPreview(preview, data);
    positionPreviewMobile(preview);
    hydrateAndPrefetch(data, index);
    showUi();

    if (!force) {
      clickSynth?.play();
    }
  }

  const throttledUpdateMobileFromViewport = rafThrottle(() => {
    updateMobileFromViewport(false);
  });

  async function toggleMobilePreview() {
    if (!mobileMode) return;

    mobilePreviewActivated = !mobilePreviewActivated;
    updateMobileRootState();
    updateMobileHeaderButton(headerButton, mobilePreviewActivated);

    if (mobilePreviewActivated) {
      if (clickSynth && !clickSynth.unlocked) {
        try {
          await clickSynth.unlock();
        } catch {
          // no-op
        }
      }

      updateMobileFromViewport(true);
    } else {
      preview.classList.remove("show");
    }
  }

  function onPointerMove(e) {
    if (mobileMode) return;

    if (dragging) {
      const { thumbHeight, maxThumbTop } = getThumbMetrics();
      const nextTop = clamp(e.clientY - dragOffsetY, 8, 8 + maxThumbTop);

      thumb.style.height = `${thumbHeight}px`;
      thumb.style.transform = `translateY(${nextTop}px)`;

      const ratio = setScrollFromThumbTop(nextTop);
      throttledUpdateDesktopFromRatio(ratio);
      showUi();
      return;
    }

    if (isNearRightEdge(e.clientX)) {
      showUi();
      updateDesktopFromCurrentScroll();
    } else {
      hideUiSoon();
    }
  }

  function onPointerDown(e) {
    if (mobileMode) return;
    if (!isNearRightEdge(e.clientX)) return;

    const thumbRect = thumb.getBoundingClientRect();
    const clickedThumb =
      e.clientX >= thumbRect.left &&
      e.clientX <= thumbRect.right &&
      e.clientY >= thumbRect.top &&
      e.clientY <= thumbRect.bottom;

    if (clickedThumb) {
      dragging = true;
      dragOffsetY = e.clientY - thumbRect.top;
    } else {
      const { thumbHeight } = getThumbMetrics();
      dragging = true;
      dragOffsetY = thumbHeight / 2;
    }

    document.body.classList.add("topic-preview--dragging");
    rail.classList.add("dragging");
    showUi();

    const { maxThumbTop } = getThumbMetrics();
    const nextTop = clamp(e.clientY - dragOffsetY, 8, 8 + maxThumbTop);
    const ratio = setScrollFromThumbTop(nextTop);
    throttledUpdateDesktopFromRatio(ratio);
  }

  function onPointerUp() {
    if (mobileMode) return;

    dragging = false;
    dragOffsetY = 0;
    document.body.classList.remove("topic-preview--dragging");
    rail.classList.remove("dragging");
    hideUiSoon();
  }

  function onScroll() {
    if (mobileMode) {
      if (mobilePreviewActivated) {
        throttledUpdateMobileFromViewport();
      }
      return;
    }

    if (!dragging) {
      updateDesktopFromCurrentScroll();
    }
  }

  function onResize() {
    if (!shouldEnableFeature()) {
      destroyExistingInstance();
      return;
    }

    const nowMobile = isMobileViewport();
    if (nowMobile !== mobileMode) {
      bootWhenReady();
      return;
    }

    if (mobileMode) {
      if (mobilePreviewActivated) {
        positionPreviewMobile(preview);
        updateMobileFromViewport(true);
      }
    } else {
      updateDesktopFromCurrentScroll();
    }
  }

  function onPreviewClick() {
    if (!mobileMode) return;
    if (!mobilePreviewActivated) return;
    if (!MOBILE_PREVIEW_CARD_CLICKABLE) return;
    if (!activeTopicUrl) return;

    window.location.href = activeTopicUrl;
  }

  const headerButton = mobileMode ? ensureMobileHeaderButton(toggleMobilePreview) : null;

  updateMobileRootState();
  updateMobileHeaderButton(headerButton, mobilePreviewActivated);
  applyClickableState();

  preview.addEventListener("click", onPreviewClick);

  if (!mobileMode) {
    syncThumbPosition(thumb);
    window.addEventListener("pointermove", onPointerMove, { passive: true });
    window.addEventListener("pointerdown", onPointerDown, { passive: true });
    window.addEventListener("pointerup", onPointerUp, { passive: true });
    window.addEventListener("scroll", onScroll, { passive: true });
  } else {
    rail.classList.remove("show");
    rail.style.display = "none";
    window.addEventListener("scroll", onScroll, { passive: true });

    if (mobilePreviewActivated) {
      updateMobileFromViewport(true);
    }
  }

  window.addEventListener("resize", onResize, { passive: true });

  const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  const onMotionChange = () => {
    preview.classList.toggle("reduced-motion", motionQuery.matches);
    rail.classList.toggle("reduced-motion", motionQuery.matches);
  };
  motionQuery.addEventListener("change", onMotionChange);

  window.__topicListPreviewCleanup = () => {
    preview.removeEventListener("click", onPreviewClick);

    if (!mobileMode) {
      window.removeEventListener("pointermove", onPointerMove);
      window.removeEventListener("pointerdown", onPointerDown);
      window.removeEventListener("pointerup", onPointerUp);
      window.removeEventListener("scroll", onScroll);
    } else {
      window.removeEventListener("scroll", onScroll);
    }

    window.removeEventListener("resize", onResize);
    motionQuery.removeEventListener("change", onMotionChange);

    if (headerButton) {
      headerButton.remove();
    }

    if (hideTimer) clearTimeout(hideTimer);

    rail.remove();
    preview.remove();
    document.body.classList.remove("topic-preview--dragging");
    document.documentElement.classList.remove("topic-preview--enabled");
    document.documentElement.classList.remove("topic-preview-mobile-active");
    delete document.documentElement.dataset.topicPreviewDensity;
  };
}

function bootWhenReady(tries = 0) {
  destroyExistingInstance();

  if (!shouldEnableFeature()) return;

  const listEl = document.querySelector("table.topic-list");
  const rows = listEl ? getTopicRows(listEl) : [];

  if (!listEl || !rows.length) {
    if (tries >= BOOT_MAX_TRIES) return;

    window.setTimeout(() => {
      bootWhenReady(tries + 1);
    }, BOOT_RETRY_MS);

    return;
  }

  bootPreviewInstance(listEl);
}

export default apiInitializer((api) => {
  api.onPageChange(() => {
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        bootWhenReady();
      });
    });
  });

  bootWhenReady();
});
