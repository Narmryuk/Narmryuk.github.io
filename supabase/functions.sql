-- =============================================================
-- TMSI 실시간 가위바위보 — RPC 함수 (서버 권위 로직)
-- 모두 SECURITY DEFINER: RLS 를 우회해 서버 규칙으로만 상태를 바꾼다.
-- 클라이언트는 이 함수들만 호출할 수 있고, 테이블 직접 쓰기는 막혀 있다.
-- 적용: schema.sql 다음에 실행.
-- =============================================================

-- 공통: 게임 제한 시간(초)
-- 15초 요구사항. 서버가 deadline 을 소유한다.
-- -------------------------------------------------------------

-- =============================================================
-- 전적 보호 트리거:
-- 클라이언트가 profiles 를 직접 UPDATE 할 때 nickname 외 전적 컬럼
-- 변경을 거부한다. RPC(SECURITY DEFINER)는 아래 플래그로 통과시킨다.
-- =============================================================
create or replace function public.guard_profile_stats()
returns trigger
language plpgsql
as $$
begin
  -- RPC 가 설정하는 세션 플래그가 있으면 통과
  if current_setting('tmsi.allow_stats_write', true) = 'on' then
    return new;
  end if;
  -- 그 외(클라이언트 직접 UPDATE)에는 전적 컬럼 변경 금지
  if (new.total_games        is distinct from old.total_games)
  or (new.total_wins         is distinct from old.total_wins)
  or (new.total_losses       is distinct from old.total_losses)
  or (new.total_draws        is distinct from old.total_draws)
  or (new.current_win_streak is distinct from old.current_win_streak)
  or (new.max_win_streak     is distinct from old.max_win_streak)
  then
    raise exception 'stats columns are read-only for clients';
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_profile_stats on public.profiles;
create trigger trg_guard_profile_stats
  before update on public.profiles
  for each row execute function public.guard_profile_stats();

-- =============================================================
-- set_nickname : 닉네임 설정/변경 (중복 방지는 UNIQUE 로)
-- =============================================================
create or replace function public.set_nickname(p_nickname text)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 결정 2: 앞뒤 공백 제거(btrim) + 빈 문자열 방지(nullif). 2~20자, 대소문자 무시 UNIQUE.
  v_nick text := nullif(btrim(p_nickname), '');
  v_row  public.profiles;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if v_nick is null or char_length(v_nick) < 2 or char_length(v_nick) > 20 then
    raise exception 'nickname must be 2-20 chars';
  end if;

  insert into public.profiles (user_id, nickname)
  values (auth.uid(), v_nick)
  on conflict (user_id) do update set nickname = excluded.nickname
  returning * into v_row;

  return v_row;
exception when unique_violation then
  raise exception 'nickname already taken';
end $$;

-- =============================================================
-- enqueue_match : 매칭 대기열 등록
--  - 이미 활성 게임이 있으면 거부
--  - 큐에 이미 있으면 그대로 유지(멱등)
-- =============================================================
create or replace function public.enqueue_match()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  -- 활성 게임 보유 시 매칭 금지
  if exists (select 1 from public.game_participants
             where user_id = v_uid and active) then
    return 'in_game';
  end if;

  insert into public.matchmaking_queue (user_id)
  values (v_uid)
  on conflict (user_id) do nothing;

  -- 결정 1: enqueue 직후 즉시 매칭 시도 (대기 중 상대가 있으면 바로 매칭).
  -- find_match 는 FOR UPDATE SKIP LOCKED + 부분 UNIQUE 로 중복 매칭을 막으므로
  -- 즉시 호출해도 동시성 안전. 매칭이 성사되면 Realtime 'matched' 가 발송된다.
  perform public.find_match();

  return 'queued';
end $$;

-- =============================================================
-- cancel_match : 매칭 취소 (보완 4-a)
--  - 내 큐 행을 FOR UPDATE 로 잠그고 삭제
--  - 그 사이 find_match 가 나를 먼저 집었으면 큐에 행이 없으므로
--    'already_matched' 를 반환 -> 클라이언트는 게임 화면으로 전환
-- =============================================================
create or replace function public.cancel_match()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_locked uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  select user_id into v_locked
  from public.matchmaking_queue
  where user_id = v_uid
  for update;

  if not found then
    -- 큐에 없음: 이미 매칭됐거나 애초에 대기중이 아님
    if exists (select 1 from public.game_participants
               where user_id = v_uid and active) then
      return 'already_matched';
    end if;
    return 'not_queued';
  end if;

  delete from public.matchmaking_queue where user_id = v_uid;
  return 'cancelled';
end $$;

-- =============================================================
-- find_match : 원자적 매칭 (보완 2)
--  - FIFO + FOR UPDATE SKIP LOCKED 로 중복 배정 방지
--  - 활성 게임 유일성은 game_participants 부분 UNIQUE 가 최종 보증
--  - pg_cron 또는 enqueue 직후 호출 (설계: cron 5초 주기로 큐 소진)
--  반환: 새로 만든 game_id (없으면 null)
-- =============================================================
create or replace function public.find_match()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_a uuid;
  v_b uuid;
  v_game uuid;
begin
  -- 가장 오래 기다린 두 명을 잠금 획득 (자기 매칭은 서로 다른 행이라 불가)
  select user_id into v_a
  from public.matchmaking_queue
  order by enqueued_at
  for update skip locked
  limit 1;

  if v_a is null then return null; end if;

  select user_id into v_b
  from public.matchmaking_queue
  where user_id <> v_a
  order by enqueued_at
  for update skip locked
  limit 1;

  if v_b is null then return null; end if;  -- 상대가 아직 없음

  -- 두 사람 중 누구든 이미 활성 게임이면 그 사람을 큐에서 제거하고 종료
  if exists (select 1 from public.game_participants where user_id in (v_a, v_b) and active) then
    delete from public.matchmaking_queue where user_id in (v_a, v_b)
      and user_id in (select user_id from public.game_participants where active);
    return null;
  end if;

  -- 게임 생성 (서버가 deadline = now()+15s 확정)
  insert into public.games (player1, player2, status, started_at, deadline)
  values (v_a, v_b, 'active', now(), now() + interval '15 seconds')
  returning id into v_game;

  -- 활성 참가자 기록 (부분 UNIQUE 가 중복 활성 게임을 거부)
  insert into public.game_participants (game_id, user_id, active)
  values (v_game, v_a, true), (v_game, v_b, true);

  -- 큐에서 제거
  delete from public.matchmaking_queue where user_id in (v_a, v_b);

  -- Realtime: 두 참가자에게 '매칭 완료' 알림 (민감값 없음, private 채널)
  -- 4번째 인자 true = private topic. 구독 인가는 realtime.messages RLS(realtime.sql)로 통제.
  perform realtime.send(
    jsonb_build_object('type','matched','game_id',v_game,
                       'deadline', (now()+interval '15 seconds')),
    'matched',
    'user:' || v_a::text,
    true
  );
  perform realtime.send(
    jsonb_build_object('type','matched','game_id',v_game,
                       'deadline', (now()+interval '15 seconds')),
    'matched',
    'user:' || v_b::text,
    true
  );

  return v_game;
end $$;

-- =============================================================
-- submit_move : 선택 제출 (보완 1 / 3)
--  - now() <= deadline 서버 시각 검증 (마감 후 제출 거부)
--  - (game_id,user_id) PK 로 중복 제출 거부
--  - 상대 choice 는 반환/노출하지 않음
--  - 양쪽 제출 완료 시 즉시 resolve_game 호출
--  - Realtime 에는 '완료 여부'만 broadcast (choice 미포함)
-- =============================================================
create or replace function public.submit_move(p_game_id uuid, p_choice rps_choice)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_game public.games;
  v_count int;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  -- 게임 잠금 조회
  select * into v_game from public.games where id = p_game_id for update;
  if not found then raise exception 'game not found'; end if;

  if v_uid <> v_game.player1 and v_uid <> v_game.player2 then
    raise exception 'not a participant';
  end if;
  if v_game.status <> 'active' then
    return 'game_closed';
  end if;
  -- 마감시각 검증: 서버 기준. 지연 제출 거부.
  if now() > v_game.deadline then
    return 'too_late';
  end if;

  -- 중복 제출 방지 (PK 충돌 -> 거부)
  begin
    insert into public.game_moves (game_id, user_id, choice)
    values (p_game_id, v_uid, p_choice);
  exception when unique_violation then
    return 'already_submitted';
  end;

  -- 완료 개수 확인 (choice 는 노출하지 않음)
  select count(*) into v_count from public.game_moves where game_id = p_game_id;

  -- Realtime: 완료 여부만 알림 (상대 choice 없음, private 채널)
  perform realtime.send(
    jsonb_build_object('type','move_submitted','both', (v_count = 2)),
    'move_submitted',
    'game:' || p_game_id::text,
    true
  );

  -- 양쪽 다 냈으면 즉시 판정 (cron 대기 불필요)
  if v_count = 2 then
    perform public.resolve_game(p_game_id);
  end if;

  return 'ok';
end $$;

-- =============================================================
-- resolve_game : 승패 판정 + 전적 갱신 (멱등, 원자적) (보완 3 / 명세 6)
--  - 이미 finished/void 면 아무것도 하지 않음 (멱등성)
--  - 양쪽/한쪽/미선택을 deadline 기준으로 판정
--  - 전적 갱신까지 하나의 트랜잭션에서 수행
--  - 호출 경로: submit_move(양쪽 완료) 또는 expire_games(cron)
-- =============================================================
create or replace function public.resolve_game(p_game_id uuid)
returns game_result
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game   public.games;
  v_c1     rps_choice;
  v_c2     rps_choice;
  v_result game_result;
  v_winner uuid;
begin
  -- 게임 행 잠금 (동시 resolve 직렬화 -> 멱등성 보장)
  select * into v_game from public.games where id = p_game_id for update;
  if not found then raise exception 'game not found'; end if;

  -- 이미 종료된 게임이면 그대로 반환 (전적 2회 반영 방지)
  if v_game.status in ('finished','void') then
    return v_game.result;
  end if;

  -- 아직 마감 전이고 양쪽이 다 내지 않았다면 판정 보류
  select choice into v_c1 from public.game_moves where game_id = p_game_id and user_id = v_game.player1;
  select choice into v_c2 from public.game_moves where game_id = p_game_id and user_id = v_game.player2;

  if now() <= v_game.deadline and (v_c1 is null or v_c2 is null) then
    return null;  -- 아직 결과 확정 불가
  end if;

  -- 결과 판정
  if v_c1 is not null and v_c2 is not null then
    if v_c1 = v_c2 then
      v_result := 'draw';
    elsif (v_c1='rock' and v_c2='scissors')
       or (v_c1='scissors' and v_c2='paper')
       or (v_c1='paper' and v_c2='rock') then
      v_result := 'p1_win'; v_winner := v_game.player1;
    else
      v_result := 'p2_win'; v_winner := v_game.player2;
    end if;
  elsif v_c1 is not null then
    v_result := 'p1_win'; v_winner := v_game.player1;   -- 상대 미선택 -> 승
  elsif v_c2 is not null then
    v_result := 'p2_win'; v_winner := v_game.player2;
  else
    v_result := 'void';                                  -- 양쪽 미선택 -> 무효
  end if;

  -- 게임 종료 기록
  update public.games
     set status   = (case when v_result='void' then 'void' else 'finished' end)::game_status,
         result   = v_result,
         winner   = v_winner,
         ended_at = now()
   where id = p_game_id;

  -- 활성 참가자 해제 (부분 UNIQUE 풀림 -> 재매칭 가능)
  update public.game_participants set active = false where game_id = p_game_id;

  -- 전적 갱신 (void 는 전적 변경 없음)
  if v_result <> 'void' then
    perform set_config('tmsi.allow_stats_write','on', true);  -- 트리거 통과 플래그
    -- 승자/패자 또는 무승부 처리
    if v_result = 'draw' then
      update public.profiles
         set total_games = total_games + 1, total_draws = total_draws + 1
       where user_id in (v_game.player1, v_game.player2);
    else
      -- 승자
      update public.profiles
         set total_games = total_games + 1,
             total_wins  = total_wins + 1,
             current_win_streak = current_win_streak + 1,
             max_win_streak = greatest(max_win_streak, current_win_streak + 1)
       where user_id = v_winner;
      -- 패자
      update public.profiles
         set total_games = total_games + 1,
             total_losses = total_losses + 1,
             current_win_streak = 0
       where user_id = case when v_winner = v_game.player1 then v_game.player2 else v_game.player1 end;
    end if;
    perform set_config('tmsi.allow_stats_write','off', true);
  end if;

  -- Realtime: 결과 확정 알림 (클라이언트는 DB 재조회로 확정값 로드, private 채널)
  perform realtime.send(
    jsonb_build_object('type','resolved','result', v_result),
    'resolved',
    'game:' || p_game_id::text,
    true
  );

  return v_result;
end $$;

-- =============================================================
-- expire_games : cron 백스톱 (보완 3)
--  - now() > deadline 인 active 게임을 일괄 종료 처리
--  - 판정 기준은 deadline 이므로 cron 지연이 결과를 바꾸지 않는다
-- =============================================================
create or replace function public.expire_games()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select id from public.games
    where status = 'active' and now() > deadline
    for update skip locked
  loop
    perform public.resolve_game(r.id);
    n := n + 1;
  end loop;
  return n;
end $$;

-- =============================================================
-- 실행 권한: 로그인 사용자에게 RPC 실행만 허용
-- (테이블 직접 쓰기는 RLS 로 막혀 있다)
--
-- [중요] PostgreSQL 은 함수 생성 시 PUBLIC 에 EXECUTE 를 기본 부여한다.
-- 따라서 서버 전용 함수가 anon/authenticated 에게 노출되지 않도록
-- 먼저 PUBLIC 권한을 회수한 뒤, 필요한 함수만 authenticated 에 부여한다.
-- =============================================================
revoke execute on function public.find_match()                 from public;
revoke execute on function public.resolve_game(uuid)           from public;
revoke execute on function public.expire_games()               from public;
revoke execute on function public.enqueue_match()              from public;
revoke execute on function public.cancel_match()               from public;
revoke execute on function public.set_nickname(text)           from public;
revoke execute on function public.submit_move(uuid, rps_choice) from public;

-- 클라이언트가 호출해도 되는 함수만 선별 부여
grant execute on function public.set_nickname(text)            to authenticated;
grant execute on function public.enqueue_match()               to authenticated;
grant execute on function public.cancel_match()                to authenticated;
grant execute on function public.submit_move(uuid, rps_choice) to authenticated;
-- find_match / resolve_game / expire_games 는 cron(서버)만 호출 -> grant 하지 않음.
-- (단, enqueue_match 내부의 perform find_match() 는 SECURITY DEFINER 소유자 권한으로
--  실행되므로 클라이언트 grant 없이도 정상 동작한다.)
