// ES2015+ – safe to paste into the theme‑component JS tab
export default {
  name: "topic-list-preview",
  initialize() {
    // Run once the main outlet has rendered the topic list
    const waitForList = () => {
      const list = document.querySelector('.topic-list');
      if (!list) {
        return requestAnimationFrame(waitForList);
      }
      initPreview(list);
    };
    waitForList();
  }
};

function initPreview(listEl) {
  const preview = document.createElement('div');
  preview.className = 'topic-preview';
  preview.innerHTML = `
    <div class="topic-title"></div>
    <div class="topic-excerpt"></div>
  `;
  document.body.appendChild(preview);

  // Helper: find the topic element closest to a given scroll offset
  function getTopicAtOffset(offset) {
    const topics = Array.from(listEl.querySelectorAll('.topic-list-item'));
    // each topic’s top relative to the list
    for (const t of topics) {
      const rect = t.getBoundingClientRect();
      const listRect = listEl.getBoundingClientRect();
      const top = rect.top - listRect.top + listEl.scrollTop;
      if (top > offset) return t.previousElementSibling || t;
    }
    return topics[topics.length - 1];
  }

  // Update preview contents from a topic element
  function updatePreview(topicEl) {
    if (!topicEl) { preview.classList.remove('show'); return; }
    const titleEl = topicEl.querySelector('.topic-title');
    const excerptEl = topicEl.querySelector('.topic-excerpt, .post');
    const title = titleEl ? titleEl.textContent.trim() : '';
    const excerpt = excerptEl ? excerptEl.textContent.slice(0, 120).trim() + '…' : '';
    preview.querySelector('.topic-title').textContent = title;
    preview.querySelector('.topic-excerpt').textContent = excerpt;

    // Position preview opposite the scrollbar thumb
    const scrollTop = listEl.scrollTop;
    const clientHeight = listEl.clientHeight;
    const scrollHeight = listEl.scrollHeight;
    const ratio = scrollTop / (scrollHeight - clientHeight);
    const previewTop = ratio * (window.innerHeight - preview.offsetHeight);
    preview.style.top = `${previewTop}px`;
    preview.classList.add('show');
  }

  // Throttle to avoid excessive work while dragging
  let ticking = false;
  function onScroll() {
    if (!ticking) {
      requestAnimationFrame(() => {
        const offset = listEl.scrollTop;
        const topic = getTopicAtOffset(offset);
        updatePreview(topic);
        ticking = false;
      });
      ticking = true;
    }
  }

  listEl.addEventListener('scroll', onScroll);
  // Hide when not scrolling
  listEl.addEventListener('mouseleave', () => preview.classList.remove('show'));
}
