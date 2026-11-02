// =============================================================
// TMSI 홈페이지 — 공개 방명록 (Supabase 실시간, 익명 허용)
//  - 로드 시 최근 글 조회(최신순)
//  - 제출 시 insert (길이 검증은 서버 CHECK 가 최종 강제)
//  - Realtime: 다른 사람 INSERT 시 목록 맨 위에 자동 추가
//  - 렌더링은 textContent 로 XSS 방어
// =============================================================
import { supabase } from './rps/supabase-client.js';

const form  = document.getElementById('guestbookForm');
const list  = document.getElementById('guestbookList');
const count = document.getElementById('guestbookCount');
const nameInput = document.getElementById('guestbookName');
const msgInput  = document.getElementById('guestbookMessage');

const MAX_ROWS = 100;        // 화면에 유지할 최대 개수
let entries = [];            // 현재 표시 중인 글 (최신순)
const seenIds = new Set();   // 중복 방지 (Realtime + 직접 insert 겹침)

function fmtTime(iso) {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? ''
    : d.toLocaleString('ko-KR', { dateStyle: 'medium', timeStyle: 'short' });
}

function render() {
  list.replaceChildren();
  count.textContent = entries.length;
  if (!entries.length) {
    const empty = document.createElement('p');
    empty.className = 'guestbook-empty';
    empty.textContent = '아직 메시지가 없어요. 첫 번째 방명록을 남겨주세요!';
    list.append(empty);
    return;
  }
  for (const item of entries) {
    const article = document.createElement('article');
    article.className = 'guestbook-entry';
    const head = document.createElement('div');
    head.className = 'guestbook-entry-head';
    const name = document.createElement('strong');
    name.textContent = item.name;             // XSS 방어: textContent
    const time = document.createElement('time');
    time.textContent = fmtTime(item.created_at);
    head.append(name, time);
    const message = document.createElement('p');
    message.textContent = item.message;       // XSS 방어: textContent
    article.append(head, message);
    list.append(article);
  }
}

// 새 글을 목록 맨 위에 추가 (중복 제거)
function addEntry(row, toTop = true) {
  if (!row || seenIds.has(row.id)) return;
  seenIds.add(row.id);
  if (toTop) entries.unshift(row);
  else entries.push(row);
  if (entries.length > MAX_ROWS) entries = entries.slice(0, MAX_ROWS);
  render();
}

// 초기 로드
async function loadInitial() {
  const { data, error } = await supabase
    .from('guestbook')
    .select('id,name,message,created_at')
    .order('created_at', { ascending: false })
    .limit(MAX_ROWS);
  if (error) {
    list.replaceChildren();
    const p = document.createElement('p');
    p.className = 'guestbook-empty';
    p.textContent = '방명록을 불러오지 못했습니다. 잠시 후 새로고침 해주세요.';
    list.append(p);
    return;
  }
  entries = data || [];
  entries.forEach(r => seenIds.add(r.id));
  render();
}

// 실시간 구독 (INSERT)
function subscribeRealtime() {
  supabase
    .channel('guestbook-feed')
    .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'guestbook' },
        (payload) => addEntry(payload.new, true))
    .subscribe();
}

// 제출
form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const name = nameInput.value.trim().slice(0, 20);
  const message = msgInput.value.trim().slice(0, 200);
  if (!name || !message) return;

  const btn = form.querySelector('button[type="submit"]');
  if (btn) btn.disabled = true;

  const { data, error } = await supabase
    .from('guestbook')
    .insert({ name, message })
    .select('id,name,message,created_at')
    .single();

  if (btn) btn.disabled = false;

  if (error) {
    alert('메시지를 등록하지 못했습니다. 잠시 후 다시 시도해 주세요.');
    return;
  }
  // 내 글 즉시 반영 (Realtime 이벤트가 중복으로 와도 seenIds 로 무시)
  addEntry(data, true);
  form.reset();
});

// 시작
loadInitial();
subscribeRealtime();
