// =============================================================
// TMSI 가위바위보 — 클라이언트 (3단계: 인증 / 닉네임 / 세션 / 전적)
// 이후 단계(매칭/게임/Realtime/결과)는 이 파일에 이어서 구현한다.
// =============================================================
import { supabase } from './supabase-client.js';

// ---- DOM 헬퍼 ----
const $ = (id) => document.getElementById(id);
const show = (el) => el.classList.remove('hidden');
const hide = (el) => el.classList.add('hidden');

// ---- 요소 ----
const authCard   = $('authCard');
const appCard    = $('appCard');
const statsCard  = $('statsCard');
const gameCard   = $('gameCard');

const tabLogin   = $('tabLogin');
const tabSignup  = $('tabSignup');
const authForm   = $('authForm');
const emailInput = $('email');
const pwInput    = $('password');
const nickField  = $('nicknameField');
const nickInput  = $('nickname');
const authSubmit = $('authSubmit');
const authMsg    = $('authMsg');

const userNick   = $('userNick');
const userEmail  = $('userEmail');
const editNickBtn= $('editNickBtn');
const logoutBtn  = $('logoutBtn');
const appMsg     = $('appMsg');

// ---- 상태 ----
let mode = 'login'; // 'login' | 'signup'

// ---- 메시지 ----
function setAuthMsg(text, kind = '') {
  authMsg.textContent = text;
  authMsg.className = 'msg' + (kind ? ' ' + kind : '');
}
function setAppMsg(text, kind = '') {
  appMsg.textContent = text;
  appMsg.className = 'msg' + (kind ? ' ' + kind : '');
}

// ---- 탭 전환 ----
function setMode(next) {
  mode = next;
  const isSignup = next === 'signup';
  tabSignup.classList.toggle('active', isSignup);
  tabLogin.classList.toggle('active', !isSignup);
  nickField.classList.toggle('hidden', !isSignup);
  nickInput.required = isSignup;
  authSubmit.textContent = isSignup ? '회원가입' : '로그인';
  pwInput.autocomplete = isSignup ? 'new-password' : 'current-password';
  setAuthMsg('');
}
tabLogin.addEventListener('click', () => setMode('login'));
tabSignup.addEventListener('click', () => setMode('signup'));

// ---- 닉네임 중복/형식 검사는 서버 RPC(set_nickname)가 최종 판정 ----
function validNickname(nick) {
  const v = (nick || '').trim();
  return v.length >= 2 && v.length <= 20;
}

// ---- 회원가입 / 로그인 제출 ----
authForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  authSubmit.disabled = true;
  setAuthMsg('처리 중...', '');

  const email = emailInput.value.trim();
  const password = pwInput.value;

  try {
    if (mode === 'signup') {
      const nick = nickInput.value.trim();
      if (!validNickname(nick)) {
        setAuthMsg('닉네임은 2~20자여야 합니다.', 'error');
        authSubmit.disabled = false;
        return;
      }
      // 1) 계정 생성
      const { data, error } = await supabase.auth.signUp({ email, password });
      if (error) throw error;

      // Confirm email 을 꺼둔 개발 설정에서는 즉시 세션이 생긴다.
      // 혹시 세션이 없으면(이메일 확인 필요 설정) 명시적으로 로그인 시도.
      if (!data.session) {
        const { error: signInErr } =
          await supabase.auth.signInWithPassword({ email, password });
        if (signInErr) {
          setAuthMsg('가입되었습니다. 이메일 확인 후 로그인해 주세요.', 'ok');
          authSubmit.disabled = false;
          return;
        }
      }
      // 2) 닉네임 설정 (서버가 중복/형식 최종 판정)
      const { error: nickErr } = await supabase.rpc('set_nickname', { p_nickname: nick });
      if (nickErr) {
        // 닉네임 중복 등: 계정은 만들어졌으나 닉네임 미설정 상태.
        setAuthMsg(mapError(nickErr), 'error');
        // 로그인 상태이므로 아래 onAuthStateChange 가 앱 화면으로 전환 후
        // 닉네임 변경을 유도한다.
      }
    } else {
      // 로그인
      const { error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) throw error;
    }
  } catch (err) {
    setAuthMsg(mapError(err), 'error');
  } finally {
    authSubmit.disabled = false;
  }
});

// ---- 에러 메시지 한국어 매핑 ----
function mapError(err) {
  const m = (err && (err.message || err.error_description || '')) + '';
  if (/already registered|already exists/i.test(m)) return '이미 가입된 이메일입니다. 로그인해 주세요.';
  if (/invalid login credentials/i.test(m)) return '이메일 또는 비밀번호가 올바르지 않습니다.';
  if (/nickname already taken/i.test(m)) return '이미 사용 중인 닉네임입니다. 다른 닉네임을 선택해 주세요.';
  if (/nickname must be 2-20/i.test(m)) return '닉네임은 2~20자여야 합니다.';
  if (/password should be at least/i.test(m)) return '비밀번호는 6자 이상이어야 합니다.';
  if (/email.*invalid|invalid.*email/i.test(m)) return '이메일 형식이 올바르지 않습니다.';
  return m || '알 수 없는 오류가 발생했습니다.';
}

// ---- 로그아웃 ----
logoutBtn.addEventListener('click', async () => {
  logoutBtn.disabled = true;
  await supabase.auth.signOut();
  logoutBtn.disabled = false;
});

// ---- 닉네임 변경 ----
editNickBtn.addEventListener('click', async () => {
  const next = prompt('새 닉네임을 입력하세요 (2~20자):');
  if (next === null) return;
  const v = next.trim();
  if (!validNickname(v)) {
    setAppMsg('닉네임은 2~20자여야 합니다.', 'error');
    return;
  }
  setAppMsg('변경 중...', '');
  const { error } = await supabase.rpc('set_nickname', { p_nickname: v });
  if (error) {
    setAppMsg(mapError(error), 'error');
    return;
  }
  setAppMsg('닉네임이 변경되었습니다.', 'ok');
  await loadProfile();
});

// ---- 프로필(닉네임 + 전적) 로드 ----
async function loadProfile() {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return;
  userEmail.textContent = user.email || '';

  const { data, error } = await supabase
    .from('profiles')
    .select('nickname,total_games,total_wins,total_losses,total_draws,current_win_streak,max_win_streak')
    .eq('user_id', user.id)
    .maybeSingle();

  if (error) {
    setAppMsg('전적을 불러오지 못했습니다: ' + mapError(error), 'error');
    return;
  }

  if (!data) {
    // 닉네임 미설정 상태 (가입 중 닉네임 RPC 실패 등)
    userNick.textContent = '(닉네임 미설정)';
    setAppMsg('닉네임을 설정해야 매칭에 참여할 수 있습니다. "닉네임 변경"을 눌러 설정하세요.', 'error');
    return;
  }

  userNick.textContent = data.nickname;
  $('stGames').textContent     = data.total_games;
  $('stWins').textContent      = data.total_wins;
  $('stLosses').textContent    = data.total_losses;
  $('stDraws').textContent     = data.total_draws;
  $('stStreak').textContent    = data.current_win_streak;
  $('stMaxStreak').textContent = data.max_win_streak;
}

// ---- 화면 전환 ----
function showAuthView() {
  show(authCard);
  hide(appCard); hide(statsCard); hide(gameCard);
}
function showAppView() {
  hide(authCard);
  show(appCard); show(statsCard); show(gameCard);
}

// =============================================================
// 4단계: 매칭 시스템
//  - enqueue_match / cancel_match RPC
//  - user:{uid} private 채널 구독으로 'matched' 수신
//  - idle / waiting / playing 뷰 전환
// =============================================================
const viewIdle    = $('viewIdle');
const viewWaiting = $('viewWaiting');
const viewPlaying = $('viewPlaying');
const viewResult  = $('viewResult');
const startMatchBtn  = $('startMatchBtn');
const cancelMatchBtn = $('cancelMatchBtn');
const matchMsg  = $('matchMsg');
const waitMsg   = $('waitMsg');
const waitTimer = $('waitTimer');

let userChannel = null;     // user:{uid} private 채널
let waitInterval = null;    // 대기 경과 타이머
let currentUid = null;      // 현재 로그인 사용자 id
let activeGameId = null;    // 매칭된 게임 id

function setMatchMsg(t, k='') { matchMsg.textContent = t; matchMsg.className = 'msg' + (k?' '+k:''); }
function setWaitMsg(t, k='')  { waitMsg.textContent = t;  waitMsg.className  = 'msg' + (k?' '+k:''); }

function showGameView(which) {
  viewIdle.classList.toggle('hidden', which !== 'idle');
  viewWaiting.classList.toggle('hidden', which !== 'waiting');
  viewPlaying.classList.toggle('hidden', which !== 'playing');
  viewResult.classList.toggle('hidden', which !== 'result');
}

function startWaitTimer() {
  let s = 0;
  waitTimer.textContent = '0초';
  stopWaitTimer();
  waitInterval = setInterval(() => { s += 1; waitTimer.textContent = s + '초'; }, 1000);
}
function stopWaitTimer() {
  if (waitInterval) { clearInterval(waitInterval); waitInterval = null; }
}

// 매칭 완료 처리 (user 채널의 'matched' 이벤트 또는 enqueue 즉시 응답)
function onMatched(gameId, deadline) {
  if (!gameId || activeGameId === gameId) return;
  activeGameId = gameId;
  stopWaitTimer();
  startGame(gameId);   // 5단계: 게임 시작
}

// user:{uid} private 채널 구독 (매칭 알림 수신)
async function subscribeUserChannel(uid) {
  if (userChannel) return;
  userChannel = supabase
    .channel('user:' + uid, { config: { private: true } })
    .on('broadcast', { event: 'matched' }, (msg) => {
      const p = msg.payload || {};
      onMatched(p.game_id, p.deadline);
    })
    .subscribe((status) => {
      if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
        setWaitMsg('실시간 연결에 문제가 발생했습니다. 다시 시도해 주세요.', 'error');
      }
    });
}
async function unsubscribeUserChannel() {
  if (userChannel) { await supabase.removeChannel(userChannel); userChannel = null; }
}

// 매칭 시작
startMatchBtn.addEventListener('click', async () => {
  setMatchMsg('');
  startMatchBtn.disabled = true;
  await subscribeUserChannel(currentUid);
  const { data, error } = await supabase.rpc('enqueue_match');
  startMatchBtn.disabled = false;

  if (error) { setMatchMsg(mapError(error), 'error'); return; }

  if (data === 'in_game') {
    setMatchMsg('이미 진행 중인 게임이 있습니다. 잠시 후 다시 시도해 주세요.', 'error');
    return;
  }
  // 'queued' — 대기 화면으로. 즉시 매칭됐다면 곧 user 채널로 'matched' 가 온다.
  showGameView('waiting');
  startWaitTimer();
  // 보강: enqueue 직후 서버가 바로 매칭했을 수 있으니, 내 활성 게임을 한 번 조회.
  await checkExistingGame();
});

// 매칭 취소 (보완 4-a)
cancelMatchBtn.addEventListener('click', async () => {
  cancelMatchBtn.disabled = true;
  setWaitMsg('취소 중...');
  const { data, error } = await supabase.rpc('cancel_match');
  cancelMatchBtn.disabled = false;

  if (error) { setWaitMsg(mapError(error), 'error'); return; }

  if (data === 'already_matched') {
    // 취소 직전에 매칭 확정됨 → 게임 화면으로
    setWaitMsg('');
    await checkExistingGame();
    return;
  }
  // cancelled / not_queued → idle 로
  stopWaitTimer();
  showGameView('idle');
  setMatchMsg(data === 'cancelled' ? '매칭을 취소했습니다.' : '');
});

// =============================================================
// 5단계: 게임 로직
//  - game:{id} private 채널 구독 (move_submitted / resolved)
//  - 서버 deadline 기준 15초 카운트다운 (로컬 시계 오프셋 보정)
//  - submit_move 호출, 상대 선택 완료 여부만 표시(choice 비공개)
//  - resolved 시 결과/전적 로드
// =============================================================
const CHOICE_EMOJI = { rock: '✊', scissors: '✌️', paper: '✋' };
const CHOICE_LABEL = { rock: '바위', scissors: '가위', paper: '보' };

const meName   = $('meName');
const oppName  = $('oppName');
const meStatus = $('meStatus');
const oppStatus= $('oppStatus');
const countdownEl = $('countdown');
const choicesWrap = $('choices');
const playMsg  = $('playMsg');
const rematchBtn = $('rematchBtn');

let gameChannel = null;     // game:{id} private 채널
let gameRow = null;         // 현재 게임 행 { id, player1, player2, deadline, ... }
let myChoice = null;        // 내가 낸 선택 (로컬)
let countdownTimer = null;  // 카운트다운 인터벌
let resolveFallback = null; // 마감 후 결과 폴백 재조회 타이머
let gameFinished = false;

function setPlayMsg(t, k='') { playMsg.textContent = t; playMsg.className = 'msg' + (k?' '+k:''); }

function clearGameTimers() {
  if (countdownTimer) { clearInterval(countdownTimer); countdownTimer = null; }
  if (resolveFallback){ clearTimeout(resolveFallback); resolveFallback = null; }
}

async function unsubscribeGameChannel() {
  if (gameChannel) { await supabase.removeChannel(gameChannel); gameChannel = null; }
}

// 게임 시작: 데이터 로드 + 채널 구독 + 카운트다운
async function startGame(gameId) {
  clearGameTimers();
  await unsubscribeGameChannel();
  myChoice = null;
  gameFinished = false;

  // 1) 게임 행 로드 (RLS: 참가자만 조회 가능)
  const { data: g, error } = await supabase
    .from('games')
    .select('id,player1,player2,status,deadline,result,winner')
    .eq('id', gameId)
    .maybeSingle();
  if (error || !g) { setMatchMsg('게임 정보를 불러오지 못했습니다.', 'error'); showGameView('idle'); return; }
  gameRow = g;

  // 이미 끝난 게임이면 바로 결과로 (새로고침 복구 케이스)
  if (g.status === 'finished' || g.status === 'void') {
    await showResult(g);
    return;
  }

  // 2) 상대/내 닉네임 표시
  const oppId = (g.player1 === currentUid) ? g.player2 : g.player1;
  const nicks = await fetchNicknames([g.player1, g.player2]);
  meName.textContent  = nicks[currentUid] || '나';
  oppName.textContent = nicks[oppId] || '상대';

  // 3) 내가 이미 제출했는지 확인 (새로고침 복구)
  const { data: myMove } = await supabase
    .from('game_moves')
    .select('choice')
    .eq('game_id', gameId).eq('user_id', currentUid)
    .maybeSingle();
  if (myMove && myMove.choice) {
    myChoice = myMove.choice;
    markMySelection(myMove.choice, true);
  } else {
    resetChoices();
  }
  oppStatus.textContent = '선택 대기';
  oppStatus.classList.remove('done');

  // 4) game 채널 구독
  gameChannel = supabase
    .channel('game:' + gameId, { config: { private: true } })
    .on('broadcast', { event: 'move_submitted' }, (msg) => {
      const both = !!(msg.payload && msg.payload.both);
      // 상대가 냈는지 여부 추론: both 이거나, 내가 안 냈는데 이벤트가 왔으면 상대가 낸 것
      if (both) { oppStatus.textContent = '선택 완료'; oppStatus.classList.add('done'); }
      else if (myChoice) { oppStatus.textContent = '상대 대기 중'; }
      else { oppStatus.textContent = '선택 완료'; oppStatus.classList.add('done'); }
    })
    .on('broadcast', { event: 'resolved' }, async () => {
      await finishAndShow();
    })
    .subscribe((status) => {
      if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
        setPlayMsg('실시간 연결 문제. 결과는 자동으로 다시 확인합니다.', 'error');
      }
    });

  // 5) 카운트다운 시작 (서버 시각 오프셋 보정 — 로컬 시계 오차 무시)
  showGameView('playing');
  setPlayMsg('');
  await refreshClockOffset();   // 서버-로컬 시계 차 계산
  startCountdown(new Date(g.deadline).getTime());
}

// 닉네임 일괄 조회
async function fetchNicknames(ids) {
  const map = {};
  const { data } = await supabase.from('profiles').select('user_id,nickname').in('user_id', ids);
  (data || []).forEach(r => { map[r.user_id] = r.nickname; });
  return map;
}

// 서버-로컬 시계 오프셋 (ms). serverNow = Date.now() + clockOffset.
let clockOffset = 0;
async function refreshClockOffset() {
  try {
    const t0 = Date.now();
    const { data, error } = await supabase.rpc('server_now');
    const t1 = Date.now();
    if (error || !data) return;              // 실패 시 offset 0 (로컬 시계 사용)
    const serverMs = new Date(data).getTime();
    const rtt = t1 - t0;                     // 왕복 지연
    // 서버 응답 시점의 로컬 시각을 (t0+rtt/2) 로 근사 -> 그 차이가 offset
    clockOffset = serverMs - (t0 + rtt / 2);
  } catch (_) { /* offset 0 유지 */ }
}
function serverNow() { return Date.now() + clockOffset; }

// 서버 deadline 기준 카운트다운 (serverNow 로 로컬 시계 오차 보정)
function startCountdown(deadlineMs) {
  clearInterval(countdownTimer);
  function tick() {
    const remain = Math.max(0, Math.ceil((deadlineMs - serverNow()) / 1000));
    countdownEl.textContent = remain;
    countdownEl.classList.toggle('urgent', remain <= 5 && remain > 0);
    if (remain <= 0) {
      clearInterval(countdownTimer); countdownTimer = null;
      countdownEl.classList.remove('urgent');
      disableChoices();
      setPlayMsg('시간 종료! 결과를 집계 중...', '');
      // cron 이 곧 void/승패 처리 → resolved 가 온다. 안전망으로 폴백 재조회.
      scheduleResolveFallback();
    }
  }
  tick();
  countdownTimer = setInterval(tick, 250);
}

// resolved 이벤트 누락 대비: 마감 후 DB 를 주기적으로 재조회
function scheduleResolveFallback() {
  if (resolveFallback) return;
  let tries = 0;
  const poll = async () => {
    tries += 1;
    const { data } = await supabase
      .from('games').select('status').eq('id', activeGameId).maybeSingle();
    if (data && (data.status === 'finished' || data.status === 'void')) {
      await finishAndShow();
      return;
    }
    if (tries < 15) resolveFallback = setTimeout(poll, 1500);
  };
  resolveFallback = setTimeout(poll, 1500);
}

// 선택 버튼
choicesWrap.querySelectorAll('.choice').forEach(btn => {
  btn.addEventListener('click', async () => {
    if (myChoice || gameFinished) return;
    const choice = btn.dataset.choice;
    disableChoices();
    markMySelection(choice, true);
    myChoice = choice;
    setPlayMsg('제출 중...');

    const { data, error } = await supabase.rpc('submit_move', {
      p_game_id: activeGameId, p_choice: choice,
    });
    if (error) {
      // 실패 시 되돌리기 (재시도 가능)
      myChoice = null; resetChoices(); setPlayMsg(mapError(error), 'error');
      return;
    }
    if (data === 'too_late')        { setPlayMsg('시간이 초과되었습니다.', 'error'); }
    else if (data === 'already_submitted') { setPlayMsg('이미 선택했습니다.'); }
    else if (data === 'game_closed'){ setPlayMsg('게임이 종료되었습니다.'); await finishAndShow(); }
    else { setPlayMsg('선택 완료! 상대를 기다리는 중...'); meStatus.textContent='선택 완료'; meStatus.classList.add('done'); }
  });
});

function markMySelection(choice, lock) {
  choicesWrap.querySelectorAll('.choice').forEach(b => {
    b.classList.toggle('selected', b.dataset.choice === choice);
  });
  meStatus.textContent = '선택 완료';
  meStatus.classList.add('done');
  if (lock) disableChoices();
}
function resetChoices() {
  choicesWrap.querySelectorAll('.choice').forEach(b => { b.disabled = false; b.classList.remove('selected'); });
  meStatus.textContent = '선택 대기';
  meStatus.classList.remove('done');
}
function disableChoices() {
  choicesWrap.querySelectorAll('.choice').forEach(b => { b.disabled = true; });
}

// 결과 확정 → 화면 표시
async function finishAndShow() {
  if (gameFinished) return;
  gameFinished = true;
  clearGameTimers();
  const { data: g } = await supabase
    .from('games')
    .select('id,player1,player2,status,result,winner,deadline')
    .eq('id', activeGameId).maybeSingle();
  if (g) await showResult(g);
  await loadProfile(); // 전적 갱신 반영
}

// 결과 화면 렌더 (종료 후엔 RLS 가 상대 move 도 공개)
async function showResult(g) {
  clearGameTimers();
  const oppId = (g.player1 === currentUid) ? g.player2 : g.player1;
  const nicks = await fetchNicknames([g.player1, g.player2]);
  $('rMeName').textContent  = nicks[currentUid] || '나';
  $('rOppName').textContent = nicks[oppId] || '상대';

  // 양쪽 move 조회 (종료 상태이므로 RLS 통과)
  const { data: moves } = await supabase
    .from('game_moves').select('user_id,choice').eq('game_id', g.id);
  const mv = {}; (moves || []).forEach(m => mv[m.user_id] = m.choice);
  $('rMePick').textContent  = mv[currentUid] ? CHOICE_EMOJI[mv[currentUid]] : '✕';
  $('rOppPick').textContent = mv[oppId]      ? CHOICE_EMOJI[mv[oppId]]      : '✕';

  const banner = $('resultBanner');
  banner.className = 'result-banner';
  if (g.status === 'void' || g.result === 'void') {
    banner.textContent = '무효 게임 (양쪽 미선택)';
    banner.classList.add('void');
    $('resultStreak').textContent = '전적에 반영되지 않습니다.';
  } else if (g.result === 'draw') {
    banner.textContent = '무승부';
    banner.classList.add('draw');
    $('resultStreak').innerHTML = streakText();
  } else if (g.winner === currentUid) {
    banner.textContent = '🎉 승리!';
    banner.classList.add('win');
    $('resultStreak').innerHTML = streakText();
  } else {
    banner.textContent = '패배';
    banner.classList.add('lose');
    $('resultStreak').innerHTML = streakText();
  }
  showGameView('result');
}

function streakText() {
  const cur = $('stStreak').textContent, mx = $('stMaxStreak').textContent;
  return `현재 연승 <b>${cur}</b> · 최대 연승 <b>${mx}</b>`;
}

// 다시 매칭
rematchBtn.addEventListener('click', async () => {
  await unsubscribeGameChannel();
  activeGameId = null; gameRow = null; myChoice = null; gameFinished = false;
  showGameView('idle');
  setMatchMsg('');
});

// 내 활성 게임 조회 → 있으면 playing 으로 복원 (새로고침/즉시매칭 대비)
async function checkExistingGame() {
  if (!currentUid) return;
  const { data, error } = await supabase
    .from('games')
    .select('id,deadline,status')
    .in('status', ['active'])
    .or(`player1.eq.${currentUid},player2.eq.${currentUid}`)
    .order('started_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) return;
  if (data && data.id) onMatched(data.id, data.deadline);
}

// 로그인 시 매칭 환경 초기화
async function initMatchForUser(uid) {
  currentUid = uid;
  activeGameId = null;
  showGameView('idle');
  setMatchMsg(''); setWaitMsg('');
  await subscribeUserChannel(uid);
  // 새로고침 복구: 진행 중 게임 있으면 playing 으로
  await checkExistingGame();
}

// 로그아웃/세션 종료 시 매칭/게임 정리
async function teardownMatch() {
  stopWaitTimer();
  clearGameTimers();
  await unsubscribeUserChannel();
  await unsubscribeGameChannel();
  currentUid = null;
  activeGameId = null;
  gameRow = null;
  myChoice = null;
  gameFinished = false;
}

// ---- 세션 상태 구독 (로그인 유지 / 전환) ----
supabase.auth.onAuthStateChange(async (_event, session) => {
  if (session) {
    showAppView();
    authForm.reset();
    setAuthMsg('');
    await loadProfile();
    await initMatchForUser(session.user.id);
  } else {
    await teardownMatch();
    showAuthView();
  }
});

// ---- 초기 세션 복원 ----
(async () => {
  const { data: { session } } = await supabase.auth.getSession();
  if (session) {
    showAppView();
    await loadProfile();
    await initMatchForUser(session.user.id);
  } else {
    showAuthView();
  }
})();
