const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const catalog = {
  Anthropic: [['Claude Sonnet', 'Баланс глубины и скорости'], ['Claude Opus', 'Сложные задачи'], ['Claude Haiku', 'Быстрые ответы']],
  OpenAI: [['GPT', 'Универсальная модель'], ['GPT mini', 'Лёгкие задачи'], ['Reasoning', 'Вдумчивый разбор'], ['Reasoning mini', 'Компактное рассуждение']],
  DeepSeek: [['DeepSeek Chat', 'Диалог'], ['DeepSeek Reasoner', 'Рассуждение']],
  'Локальная модель': [],
};
const connected = ['Anthropic', 'OpenAI'];
let selectedModel = 'Claude Sonnet';
let modelProvider = 'Anthropic';
let selectedButton = $('[data-chat]');
let selectedProject = selectedButton.closest('.project');
let lastFocus, toastTimer, activePopover, popoverAnchor, generation;
let chatNumber = 0;
const sampleTimeline = $('.timeline').innerHTML;
const histories = new Map();
const drafts = new Map();
const systemTheme = window.matchMedia('(prefers-color-scheme: dark)');
function applyTheme() {
  const value = $('#theme').value;
  document.documentElement.dataset.theme = value === 'system' ? (systemTheme.matches ? 'dark' : 'light') : value;
}
$('#theme').addEventListener('change', applyTheme);
systemTheme.addEventListener('change', applyTheme);
applyTheme();
function toast(text) {
  $('#toast').textContent = text;
  $('#toast').hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 4500);
}
function closePopover(restore = false) {
  if (!activePopover) return;
  activePopover.hidden = true;
  popoverAnchor.setAttribute('aria-expanded', 'false');
  if (restore) popoverAnchor.focus();
  activePopover = null;
}
function positionPopover() {
  if (!activePopover) return;
  const anchor = popoverAnchor.getBoundingClientRect();
  const top = activePopover.id === 'folder-popover' ? anchor.bottom + 9 : anchor.top - 8;
  activePopover.style.maxHeight = `${Math.max(100, activePopover.id === 'folder-popover' ? innerHeight - top - 12 : top - 12)}px`;
  activePopover.style.left = `${Math.max(12, Math.min(activePopover.id === 'context-popover' ? anchor.right - activePopover.offsetWidth : anchor.left, innerWidth - activePopover.offsetWidth - 12))}px`;
  activePopover.style.top = `${activePopover.id === 'folder-popover' ? top : Math.max(12, top - activePopover.offsetHeight)}px`;
}
function togglePopover(id, anchor) {
  const element = $(id);
  const wasOpen = activePopover === element;
  closePopover();
  if (wasOpen) return;
  activePopover = element; popoverAnchor = anchor;
  element.hidden = false; anchor.setAttribute('aria-expanded', 'true');
  positionPopover();
  (element.querySelector('input,button') || element).focus();
}
window.addEventListener('resize', positionPopover);
document.addEventListener('click', event => {
  if (activePopover && !activePopover.contains(event.target) && !popoverAnchor.contains(event.target)) closePopover();
});
document.addEventListener('focusin', event => {
  if (activePopover && !activePopover.contains(event.target) && !popoverAnchor.contains(event.target)) closePopover();
});
function openDialog(id) { closePopover(); lastFocus = document.activeElement; $(id).showModal(); }
$$('dialog').forEach(dialog => {
  dialog.addEventListener('click', event => {
    if (event.target !== dialog) return;
    const r = dialog.getBoundingClientRect();
    if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close();
  });
  dialog.addEventListener('close', () => lastFocus?.focus());
});
function updateHeader() {
  $$('[data-chat]').forEach(item => {
    if (item === selectedButton) item.setAttribute('aria-current', 'page');
    else item.removeAttribute('aria-current');
  });
  $('#crumb').textContent = selectedButton?.dataset.chat || selectedProject?.dataset.name || 'Без проекта';
  $('#folder-name').textContent = selectedProject?.dataset.name || 'Без проекта';
  $('#folder-path').textContent = selectedProject?.dataset.root || 'Корневая папка не выбрана';
  $$('[data-action="new-chat"]').forEach(button => button.setAttribute('aria-label', `Новый чат: ${selectedProject?.dataset.name || 'Без проекта'}`));
}
function view(name) {
  closePopover();
  $$('.view').forEach(section => { section.hidden = section.id !== `${name}-view`; });
  updateHeader();
  $$('.sidebar-bottom [data-view]').forEach(item => item.classList.toggle('active', item.dataset.view === name));
  if (name !== 'chat') $('#crumb').textContent = name === 'usage' ? 'Использование' : 'Провайдеры';
  $('#folder-button').hidden = name !== 'chat';
  $('#sidebar').classList.remove('open');
}
function saveChat() {
  if (selectedButton) {
    histories.set(selectedButton, $('.timeline').innerHTML);
    drafts.set(selectedButton, $('.composer textarea').value);
  }
}
function selectChat(button) {
  if (generation) finishGeneration();
  saveChat();
  selectedButton = button;
  selectedProject = button.closest('.project');
  $$('[data-chat]').forEach(item => item.classList.toggle('selected', item === button));
  $('.timeline').innerHTML = histories.get(button) ?? sampleTimeline;
  $('.composer textarea').value = drafts.get(button) || '';
  view('chat');
  $('.timeline').scrollTop = 0;
}
function createChat(project = selectedProject) {
  if (generation) finishGeneration();
  const button = document.createElement('button');
  button.dataset.chat = `Новый чат ${++chatNumber}`;
  button.textContent = button.dataset.chat;
  if (!project) button.className = 'loose-chat';
  (project?.querySelector('.chat-list') || $('#loose-chats')).append(button);
  histories.set(button, '<div class="empty-chat"><h1>С чего начнём?</h1><p>Напишите первую мысль или задачу.</p></div>');
  if (project) {
    project.querySelector('.chat-list').hidden = false;
    project.querySelector('.project-title').setAttribute('aria-expanded', 'true');
    project.querySelector('.count').textContent = project.querySelectorAll('[data-chat]').length;
  }
  selectChat(button); $('.composer textarea').focus();
}
function decorateProject(project) {
  const title = project.querySelector('.project-title');
  const name = document.createElement('span'); name.className = 'project-name'; name.textContent = project.dataset.name;
  const count = title.querySelector('.count');
  title.replaceChildren();
  title.insertAdjacentHTML('afterbegin', '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="M3 7V5a1 1 0 0 1 1-1h5l2 3h9a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1Z"/></svg>');
  title.append(name); if (count) title.append(count);
  const row = document.createElement('div'); row.className = 'project-heading';
  title.before(row); row.append(title);
  const add = document.createElement('button'); add.textContent = '＋'; add.dataset.action = 'project-chat';
  add.setAttribute('aria-label', `Новый чат в проекте ${project.dataset.name}`); row.append(add);
}
$$('.project').forEach(decorateProject);
function renderModels() {
  const query = ''; 
  const providers = Object.keys(catalog).filter(name => `${name} ${catalog[name].flat().join(' ')}`.toLocaleLowerCase('ru').includes(query));
  if (!providers.includes(modelProvider)) modelProvider = providers[0];
  const nav = $('#model-providers'); nav.replaceChildren();
  providers.forEach(name => {
    const button = document.createElement('button'); button.textContent = `${name}  ›`;
    button.classList.toggle('selected', name === modelProvider);
    button.setAttribute('aria-pressed', String(name === modelProvider));
    const activate = () => {
      modelProvider = name;
      [...nav.children].forEach(item => { item.classList.toggle('selected', item === button); item.setAttribute('aria-pressed', String(item === button)); });
      renderModelList(query); positionPopover();
    };
    button.addEventListener('pointerenter', event => { if (event.pointerType === 'mouse') activate(); });
    button.addEventListener('click', activate);
    button.addEventListener('focus', activate);
    nav.append(button);
  });
  renderModelList(query); positionPopover();
}
function renderModelList(query) {
  const root = $('#model-results'); root.replaceChildren();
  const heading = document.createElement('h3'); heading.textContent = modelProvider || 'Ничего не найдено'; root.append(heading);
  if (!modelProvider || !connected.includes(modelProvider)) {
    const p = document.createElement('p'); p.className = 'help';
    p.textContent = modelProvider ? 'Нет подключения. Настройте провайдера в разделе «Провайдеры».' : 'Попробуйте другое название.'; root.append(p); return;
  }
  catalog[modelProvider].filter(([name, description]) => `${modelProvider} ${name} ${description}`.toLocaleLowerCase('ru').includes(query)).forEach(([name, description]) => {
    const button = document.createElement('button'); button.className = name === selectedModel ? 'selected' : '';
    button.setAttribute('aria-pressed', String(name === selectedModel));
    const label = document.createElement('span'); label.textContent = name;
    const sub = document.createElement('small'); sub.textContent = description; label.append(sub);
    button.append(label);
    button.addEventListener('click', () => { selectedModel = name; $('#model-button').textContent = `${name} ⌃`; closePopover(true); }); root.append(button);
  });
}

function provider(name) {
  $('#provider-name').textContent = name; $('#provider-initial').textContent = name[0];
  $('#provider-status').textContent = connected.includes(name) ? 'Настроен · пример' : 'Не подключён · пример';
  $$('[data-provider]').forEach(button => button.classList.toggle('active', button.dataset.provider === name));
  const root = $('#provider-models'); root.replaceChildren();
  catalog[name].forEach(([model]) => { const row = document.createElement('div'); const label = document.createElement('span'); label.textContent = model; const status = document.createElement('small'); status.textContent = 'Пример'; row.append(label, status); root.append(row); });
  if (!catalog[name].length) root.textContent = 'Каталог ещё не загружен';
}
provider('Anthropic');
function elapsedLabel(seconds) { return seconds < 60 ? `${seconds} с` : `${Math.floor(seconds / 60)} мин ${seconds % 60} с`; }
function finishGeneration() {
  if (!generation) return;
  clearInterval(generation.timer);
  const seconds = Math.floor((performance.now() - generation.start) / 1000);
  generation.byline.textContent = `Работал ${elapsedLabel(seconds)}`;
  generation.byline.classList.remove('working');
  generation.text.textContent = 'Начнём с одной комнаты и небольшого списка изменений. Это заранее подготовленный ответ для проверки макета.';
  generation = null;
  $('.send').textContent = '↑'; $('.send').setAttribute('aria-label', 'Отправить демо-сообщение');
}
function sendDemo() {
  if (generation) { finishGeneration(); return; }
  const input = $('.composer textarea'); const value = input.value.trim();
  if (!value) { input.focus(); return; }
  if (!selectedButton) createChat();
  $('.empty-chat')?.remove();
  const message = document.createElement('div'); message.className = 'user-message'; message.textContent = value;
  const article = document.createElement('article'); article.className = 'assistant-message';
  const byline = document.createElement('div'); byline.className = 'assistant-byline working'; byline.textContent = 'Работал 0 с';
  const text = document.createElement('p'); text.textContent = 'Собираю пример ответа…';
  const note = document.createElement('div'); note.className = 'response-footer'; note.textContent = 'Демонстрация генерации · без запроса к модели';
  article.append(byline, text, note); $('.timeline').append(message, article); input.value = '';
  generation = {byline, text, start: performance.now()};
  generation.timer = setInterval(() => {
    const seconds = Math.floor((performance.now() - generation.start) / 1000);
    byline.textContent = `Работал ${elapsedLabel(seconds)}`;
    if (seconds >= 6) finishGeneration();
  }, 250);
  $('.send').textContent = '■'; $('.send').setAttribute('aria-label', 'Остановить демо-генерацию');
  $('.timeline').scrollTop = $('.timeline').scrollHeight;
}
document.addEventListener('click', event => {
  const button = event.target.closest('button,a.brand');
  if (!button) return;
  if (button.matches('[data-close]')) { button.closest('dialog').close(); return; }
  if (button.matches('.brand')) { event.preventDefault(); view('chat'); return; }
  if (button.dataset.view) { view(button.dataset.view); return; }
  if (button.dataset.chat) { selectChat(button); return; }
  if (button.dataset.provider) { provider(button.dataset.provider); return; }
  if (button.dataset.reasoning) {
    $('#reasoning-button').textContent = `${button.dataset.reasoning} ⌃`;
    $('#reasoning-button').setAttribute('aria-label', `Уровень рассуждения: ${button.dataset.reasoning}`);
    $$('[data-reasoning]').forEach(item => item.classList.toggle('selected', item === button)); closePopover(true); return;
  }
  if (button.matches('.project-title')) {
    const project = button.closest('.project'), list = project.querySelector('.chat-list');
    list.hidden = !list.hidden; button.setAttribute('aria-expanded', String(!list.hidden));
    if (selectedProject !== project) {
      if (generation) finishGeneration(); saveChat(); selectedProject = project; selectedButton = null;
      $$('[data-chat]').forEach(item => item.classList.remove('selected'));
      $('.timeline').innerHTML = '<div class="empty-chat"><h1>Чаты проекта</h1><p>Выберите чат или создайте новый через +.</p></div>';
      $('.composer textarea').value = ''; view('chat');
    }
    return;
  }
  switch (button.dataset.action) {
    case 'models': renderModels(); togglePopover('#models-popover', button); break;
    case 'reasoning': togglePopover('#reasoning-popover', button); break;
    case 'folder': updateHeader(); togglePopover('#folder-popover', button); break;
    case 'context': togglePopover('#context-popover', button); break;
    case 'project': openDialog('#project-dialog'); break;
    case 'menu': $('#sidebar').classList.toggle('open'); break;
    case 'root': $('#root-path').textContent = '~/Projects/new-project'; break;
    case 'grant': {
      if ($('#grants').children.length > 1) break;
      const row = document.createElement('div'); row.className = 'grant-row';
      row.innerHTML = '<span>~/Documents/Notes</span><span class="tag">Только чтение</span>'; $('#grants').append(row); break;
    }
    case 'send': sendDemo(); break;
    case 'connection': toast('Макет: проверка подключения не выполнялась.'); break;
    case 'copy': toast('Макет: копирование не выполняется.'); break;
    case 'new-chat': createChat(); break;
    case 'project-chat': createChat(button.closest('.project')); break;
  }
});
$('#project-form').addEventListener('submit', event => {
  event.preventDefault();
  if ($('#root-path').textContent === 'Выбрать пример папки') { toast('Сначала выберите пример корневой папки.'); return; }
  const name = $('#project-name').value.trim(); if (!name) { $('#project-name').focus(); return; }
  if (generation) finishGeneration(); saveChat();
  const project = document.createElement('div'); project.className = 'project'; project.dataset.name = name; project.dataset.root = $('#root-path').textContent;
  const title = document.createElement('button'); title.className = 'project-title'; title.setAttribute('aria-expanded', 'true');
  const label = document.createElement('span'); label.textContent = `▱ ${name}`;
  const count = document.createElement('span'); count.className = 'count'; count.textContent = '0'; title.append(label, count);
  const list = document.createElement('div'); list.className = 'chat-list'; project.append(title, list); decorateProject(project); $('.unassigned').before(project);
  selectedProject = project; selectedButton = null;
  $$('[data-chat]').forEach(item => item.classList.remove('selected'));
  $('.timeline').innerHTML = '<div class="empty-chat"><h1>Проект создан</h1><p>Добавьте первый чат через + рядом с проектом или разделом «Чаты».</p></div>';
  $('.composer textarea').value = '';
  $('#project-dialog').close(); view('chat');
  toast('Демо-проект добавлен. Доступ к папкам не выдан.');
  $('#project-form').reset(); $('#root-path').textContent = 'Выбрать пример папки';
});
$('.composer textarea').addEventListener('keydown', event => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) { event.preventDefault(); sendDemo(); }
});
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    closePopover(true); $('#sidebar').classList.remove('open');
    const dialog = $('dialog[open]'); if (dialog) { event.preventDefault(); dialog.close(); }
  }
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'n' && !$('dialog[open]')) { event.preventDefault(); createChat(); }
});
updateHeader();
