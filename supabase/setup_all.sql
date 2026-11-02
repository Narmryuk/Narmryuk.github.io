-- =============================================================
-- TMSI 실시간 가위바위보 — 통합 설치 스크립트 (한 번에 실행)
-- 순서: schema -> functions -> realtime -> cron
--
-- [사용법]
--   1) 대시보드에서 pg_cron 확장을 먼저 활성화한다. (완료)
--   2) SQL Editor > New query 에 이 파일 전체를 붙여넣고 Run.
--   3) 에러가 나면 메시지를 그대로 공유. (이 스크립트는 재실행에 안전하도록 작성)
--
-- 개별 원본: schema.sql / functions.sql / realtime.sql / cron.sql
-- =============================================================


-- #############################################################
-- # SECTION 1 / SCHEMA : 테이블 / 제약 / 인덱스 / RLS
-- #############################################################

create extension if not exists pgcrypto;      -- gen_random_uuid()

-- ENUM 타입 (중복 생성 방지)
do $$ begin
  create type rps_choice as enum ('rock', 'paper', 'scissors');
exception when duplicate_object then null; end $$;

do $$ begin
  create type game_status as enum ('active', 'finished', 'void');
exception when duplicate_object then null; end $$;

do $$ begin
  create type game_result as enum ('p1_win', 'p2_win', 'draw', 'void');
exception when duplicate_object then null; end $$;

-- 1) profiles
create table if not exists public.profiles (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  nickname           text not null unique,
  total_games        integer not null default 0 check (total_games  >= 0),
  total_wins         integer not null default 0 check (total_wins    >= 0),
  total_losses       integer not null default 0 check (total_losses  >= 0),
  total_draws        integer not null default 0 check (total_draws   >= 0),
  current_win_streak integer not null default 0 check (current_win_streak >= 0),
  max_win_streak     integer not null default 0 check (max_win_streak     >= 0),
  created_at         timestamptz not null default now(),
  constraint profiles_totals_consistent
    check (total_games = total_wins + total_losses + total_draws)
);
create unique index if not exists profiles_nickname_ci_idx
  on public.profiles (lower(nickname));

-- 2) matchmaking_queue
create table if not exists public.matchmaking_queue (
  user_id     uuid primary key references public.profiles(user_id) on delete cascade,
  enqueued_at timestamptz not null default now()
);
create index if not exists mmq_fifo_idx
  on public.matchmaking_queue (enqueued_at);

-- 3) games
create table if not exists public.games (
  id         uuid primary key default gen_random_uuid(),
  player1    uuid not null references public.profiles(user_id) on delete cascade,
  player2    uuid not null references public.profiles(user_id) on delete cascade,
  status     game_status not null default 'active',
  result     game_result,
  winner     uuid references public.profiles(user_id),
  started_at timestamptz not null default now(),
  deadline   timestamptz not null,
  ended_at   timestamptz,
  constraint games_distinct_players check (player1 <> player2),
  pair_lo    uuid generated always as (least(player1, player2))    stored,
  pair_hi    uuid generated always as (greatest(player1, player2)) stored
);
create index if not exists games_player1_idx on public.games (player1);
create index if not exists games_player2_idx on public.games (player2);
create index if not exists games_status_idx  on public.games (status);
create index if not exists games_active_deadline_idx
  on public.games (deadline) where status = 'active';

-- 활성 게임 유일성 보증 테이블 (보완 2)
create table if not exists public.game_participants (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  active  boolean not null default true,
  primary key (game_id, user_id)
);
create unique index if not exists one_active_game_per_user
  on public.game_participants (user_id) where active;

-- 4) game_moves
create table if not exists public.game_moves (
  game_id      uuid not null references public.games(id) on delete cascade,
  user_id      uuid not null references public.profiles(user_id) on delete cascade,
  choice       rps_choice not null,
  submitted_at timestamptz not null default now(),
  primary key (game_id, user_id)
);
create index if not exists game_moves_game_idx on public.game_moves (game_id);

-- RLS 활성화
alter table public.profiles          enable row level security;
alter table public.matchmaking_queue enable row level security;
alter table public.games             enable row level security;
alter table public.game_participants enable row level security;
alter table public.game_moves        enable row level security;

-- profiles 정책
drop policy if exists profiles_select_all  on public.profiles;
create policy profiles_select_all on public.profiles
  for select to authenticated using (true);
drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- matchmaking_queue 정책
drop policy if exists mmq_select_self on public.matchmaking_queue;
create policy mmq_select_self on public.matchmaking_queue
  for select to authenticated using (user_id = auth.uid());

-- games 정책
drop policy if exists games_select_participant on public.games;
create policy games_select_participant on public.games
  for select to authenticated
  using (auth.uid() = player1 or auth.uid() = player2);

-- game_participants 정책
drop policy if exists gp_select_self on public.game_participants;
create policy gp_select_self on public.game_participants
  for select to authenticated using (user_id = auth.uid());

-- game_moves 정책 (보완 1: 상대 move 는 종료 후에만)
drop policy if exists moves_select_own_or_finished on public.game_moves;
create policy moves_select_own_or_finished on public.game_moves
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.games g
      where g.id = game_moves.game_id
        and (g.player1 = auth.uid() or g.player2 = auth.uid())
        and g.status in ('finished', 'void')
    )
  );

-- -------------------------------------------------------------
-- 테이블 레벨 GRANT (중요)
-- 프로젝트 생성 시 "Automatically expose new tables" 를 껐으므로
-- 클라이언트 롤(authenticated)에 테이블 접근 권한이 없다.
-- 클라이언트가 "직접 SELECT" 하는 테이블에만 SELECT 를 부여한다.
-- 행 수준 제한은 위 RLS 정책이 담당(GRANT 는 테이블 접근, RLS 는 행 필터).
-- 쓰기(INSERT/UPDATE/DELETE)는 부여하지 않음 -> RPC(SECURITY DEFINER)로만.
-- -------------------------------------------------------------
grant usage on schema public to authenticated;
grant select on public.profiles          to authenticated;  -- 전적/닉네임 표시
grant select on public.games             to authenticated;  -- 활성 게임 복원
grant select on public.game_moves        to authenticated;  -- 종료 후 선택 공개(RLS 제한)
grant select on public.game_participants to authenticated;  -- 본인 참가 상태(RLS 제한)
grant select on public.matchmaking_queue to authenticated;  -- 본인 대기 상태(RLS 제한)
-- profiles 는 닉네임 UPDATE 정책이 있으므로 UPDATE 도 필요(전적 컬럼은 트리거가 차단).
grant update on public.profiles          to authenticated;


-- #############################################################
-- # SECTION 2 / FUNCTIONS : RPC (서버 권위 로직) + 전적 보호 트리거
-- #############################################################

-- 전적 보호 트리거
create or replace function public.guard_profile_stats()
returns trigger
language plpgsql
as $$
begin
  if current_setting('tmsi.allow_stats_write', true) = 'on' then
    return new;
  end if;
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

-- set_nickname (결정 2: btrim + nullif)
create or replace function public.set_nickname(p_nickname text)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
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

-- find_match (먼저 정의: enqueue_match 가 참조) (보완 2)
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
  if v_b is null then return null; end if;

  if exists (select 1 from public.game_participants where user_id in (v_a, v_b) and active) then
    delete from public.matchmaking_queue where user_id in (v_a, v_b)
      and user_id in (select user_id from public.game_participants where active);
    return null;
  end if;

  insert into public.games (player1, player2, status, started_at, deadline)
  values (v_a, v_b, 'active', now(), now() + interval '15 seconds')
  returning id into v_game;

  insert into public.game_participants (game_id, user_id, active)
  values (v_game, v_a, true), (v_game, v_b, true);

  delete from public.matchmaking_queue where user_id in (v_a, v_b);

  perform realtime.send(
    jsonb_build_object('type','matched','game_id',v_game,
                       'deadline', (now()+interval '15 seconds')),
    'matched', 'user:' || v_a::text, true);
  perform realtime.send(
    jsonb_build_object('type','matched','game_id',v_game,
                       'deadline', (now()+interval '15 seconds')),
    'matched', 'user:' || v_b::text, true);

  return v_game;
end $$;

-- enqueue_match (결정 1: 즉시 find_match 호출)
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
  if exists (select 1 from public.game_participants where user_id = v_uid and active) then
    return 'in_game';
  end if;
  insert into public.matchmaking_queue (user_id)
  values (v_uid)
  on conflict (user_id) do nothing;
  perform public.find_match();
  return 'queued';
end $$;

-- cancel_match (보완 4-a)
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
    if exists (select 1 from public.game_participants where user_id = v_uid and active) then
      return 'already_matched';
    end if;
    return 'not_queued';
  end if;
  delete from public.matchmaking_queue where user_id = v_uid;
  return 'cancelled';
end $$;

-- resolve_game (먼저 정의: submit_move 가 참조) (보완 3 / 명세 6)
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
  select * into v_game from public.games where id = p_game_id for update;
  if not found then raise exception 'game not found'; end if;

  if v_game.status in ('finished','void') then
    return v_game.result;
  end if;

  select choice into v_c1 from public.game_moves where game_id = p_game_id and user_id = v_game.player1;
  select choice into v_c2 from public.game_moves where game_id = p_game_id and user_id = v_game.player2;

  if now() <= v_game.deadline and (v_c1 is null or v_c2 is null) then
    return null;
  end if;

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
    v_result := 'p1_win'; v_winner := v_game.player1;
  elsif v_c2 is not null then
    v_result := 'p2_win'; v_winner := v_game.player2;
  else
    v_result := 'void';
  end if;

  update public.games
     set status   = (case when v_result='void' then 'void' else 'finished' end)::game_status,
         result   = v_result,
         winner   = v_winner,
         ended_at = now()
   where id = p_game_id;

  update public.game_participants set active = false where game_id = p_game_id;

  if v_result <> 'void' then
    perform set_config('tmsi.allow_stats_write','on', true);
    if v_result = 'draw' then
      update public.profiles
         set total_games = total_games + 1, total_draws = total_draws + 1
       where user_id in (v_game.player1, v_game.player2);
    else
      update public.profiles
         set total_games = total_games + 1,
             total_wins  = total_wins + 1,
             current_win_streak = current_win_streak + 1,
             max_win_streak = greatest(max_win_streak, current_win_streak + 1)
       where user_id = v_winner;
      update public.profiles
         set total_games = total_games + 1,
             total_losses = total_losses + 1,
             current_win_streak = 0
       where user_id = case when v_winner = v_game.player1 then v_game.player2 else v_game.player1 end;
    end if;
    perform set_config('tmsi.allow_stats_write','off', true);
  end if;

  perform realtime.send(
    jsonb_build_object('type','resolved','result', v_result),
    'resolved', 'game:' || p_game_id::text, true);

  return v_result;
end $$;

-- submit_move (보완 1 / 3)
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
  select * into v_game from public.games where id = p_game_id for update;
  if not found then raise exception 'game not found'; end if;
  if v_uid <> v_game.player1 and v_uid <> v_game.player2 then
    raise exception 'not a participant';
  end if;
  if v_game.status <> 'active' then
    return 'game_closed';
  end if;
  if now() > v_game.deadline then
    return 'too_late';
  end if;

  begin
    insert into public.game_moves (game_id, user_id, choice)
    values (p_game_id, v_uid, p_choice);
  exception when unique_violation then
    return 'already_submitted';
  end;

  select count(*) into v_count from public.game_moves where game_id = p_game_id;

  perform realtime.send(
    jsonb_build_object('type','move_submitted','both', (v_count = 2)),
    'move_submitted', 'game:' || p_game_id::text, true);

  if v_count = 2 then
    perform public.resolve_game(p_game_id);
  end if;

  return 'ok';
end $$;

-- expire_games (cron 백스톱) (보완 3)
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

-- 실행 권한: PUBLIC revoke 후 선별 grant
revoke execute on function public.find_match()                 from public;
revoke execute on function public.resolve_game(uuid)           from public;
revoke execute on function public.expire_games()               from public;
revoke execute on function public.enqueue_match()              from public;
revoke execute on function public.cancel_match()               from public;
revoke execute on function public.set_nickname(text)           from public;
revoke execute on function public.submit_move(uuid, rps_choice) from public;

grant execute on function public.set_nickname(text)            to authenticated;
grant execute on function public.enqueue_match()               to authenticated;
grant execute on function public.cancel_match()                to authenticated;
grant execute on function public.submit_move(uuid, rps_choice) to authenticated;


-- #############################################################
-- # SECTION 3 / REALTIME : private 채널 구독 인가 (결정 3)
-- #############################################################

drop policy if exists "tmsi realtime subscribe" on realtime.messages;
create policy "tmsi realtime subscribe"
on realtime.messages
for select
to authenticated
using (
  realtime.topic() = 'user:' || auth.uid()::text
  or (
    realtime.topic() like 'game:%'
    and exists (
      select 1 from public.games g
      where g.id = (substring(realtime.topic() from 6))::uuid
        and (g.player1 = auth.uid() or g.player2 = auth.uid())
    )
  )
);

drop policy if exists "tmsi realtime no client send" on realtime.messages;
create policy "tmsi realtime no client send"
on realtime.messages
for insert
to authenticated
with check (false);


-- #############################################################
-- # SECTION 4 / CRON : pg_cron 5초 주기 (만료 + 매칭 백스톱)
-- #############################################################
-- 재실행 안전: 같은 이름의 잡이 있으면 먼저 해제 후 재등록.

do $$ begin
  perform cron.unschedule('tmsi-expire-games');
exception when others then null; end $$;
do $$ begin
  perform cron.unschedule('tmsi-find-match');
exception when others then null; end $$;

select cron.schedule('tmsi-expire-games', '5 seconds', $$ select public.expire_games(); $$);
select cron.schedule('tmsi-find-match',   '5 seconds', $$ select public.find_match(); $$);

-- 설치 확인용 (선택):
--   select * from cron.job;
--   select * from pg_policies where schemaname in ('public','realtime');
