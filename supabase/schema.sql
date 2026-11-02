-- =============================================================
-- TMSI 실시간 가위바위보 — 스키마 (테이블 / 제약 / 인덱스 / RLS)
-- 적용 순서: schema.sql -> functions.sql -> cron.sql
-- 이 파일은 "검토용 초안"이며, 승인 전 실제 DB에 적용하지 않는다.
-- =============================================================

-- 필요한 확장 (Supabase 기본 제공)
create extension if not exists pgcrypto;      -- gen_random_uuid()
-- pg_cron 은 cron.sql 에서 대시보드를 통해 활성화한다.

-- -------------------------------------------------------------
-- ENUM 타입
-- -------------------------------------------------------------
do $$ begin
  create type rps_choice as enum ('rock', 'paper', 'scissors');
exception when duplicate_object then null; end $$;

do $$ begin
  create type game_status as enum ('active', 'finished', 'void');
exception when duplicate_object then null; end $$;

do $$ begin
  create type game_result as enum ('p1_win', 'p2_win', 'draw', 'void');
exception when duplicate_object then null; end $$;

-- =============================================================
-- 1) profiles : 사용자 기본 정보 + 누적 전적
--    user_id 는 auth.users 와 1:1. 닉네임은 전역 UNIQUE.
-- =============================================================
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
  -- 불변식: 총 게임 수 = 승 + 패 + 무
  constraint profiles_totals_consistent
    check (total_games = total_wins + total_losses + total_draws)
);

-- 닉네임 중복 방지를 대소문자 무시로 강화 (선택)
create unique index if not exists profiles_nickname_ci_idx
  on public.profiles (lower(nickname));

-- =============================================================
-- 2) matchmaking_queue : 매칭 대기열
--    user_id UNIQUE -> 한 사용자는 큐에 1번만.
--    FIFO 를 위해 enqueued_at 인덱스.
-- =============================================================
create table if not exists public.matchmaking_queue (
  user_id     uuid primary key references public.profiles(user_id) on delete cascade,
  enqueued_at timestamptz not null default now()
);
create index if not exists mmq_fifo_idx
  on public.matchmaking_queue (enqueued_at);

-- =============================================================
-- 3) games : 한 판의 게임
--    서버가 소유하는 시작/마감 시각. 결과/승자는 서버가 기록.
-- =============================================================
create table if not exists public.games (
  id         uuid primary key default gen_random_uuid(),
  player1    uuid not null references public.profiles(user_id) on delete cascade,
  player2    uuid not null references public.profiles(user_id) on delete cascade,
  status     game_status not null default 'active',
  result     game_result,
  winner     uuid references public.profiles(user_id),
  started_at timestamptz not null default now(),
  deadline   timestamptz not null,               -- started_at + 15s (서버 확정)
  ended_at   timestamptz,
  -- 자기 자신과 매칭 금지
  constraint games_distinct_players check (player1 <> player2),
  -- 정규화된 짝 (중복 쌍 매칭 방지에 사용)
  pair_lo    uuid generated always as (least(player1, player2))    stored,
  pair_hi    uuid generated always as (greatest(player1, player2)) stored
);
create index if not exists games_player1_idx on public.games (player1);
create index if not exists games_player2_idx on public.games (player2);
create index if not exists games_status_idx  on public.games (status);
-- 만료 스캔 최적화: 아직 안 끝난 게임의 deadline
create index if not exists games_active_deadline_idx
  on public.games (deadline) where status = 'active';

-- -------------------------------------------------------------
-- 활성 게임 유일성 보증 테이블 (보완 2 의 "최후 방어선")
-- 각 참가자는 'active' 게임에 최대 1건만 존재할 수 있다.
-- find_match 트랜잭션에서 games INSERT 와 함께 2행을 INSERT 한다.
-- -------------------------------------------------------------
create table if not exists public.game_participants (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  active  boolean not null default true,
  primary key (game_id, user_id)
);
-- 사용자당 활성 게임 1개 (부분 UNIQUE) — DB 레벨 하드 제약
create unique index if not exists one_active_game_per_user
  on public.game_participants (user_id) where active;

-- =============================================================
-- 4) game_moves : 사용자별 선택
--    (game_id, user_id) 복합 PK -> 중복 제출 방지.
--    choice 는 종료 전까지 상대에게 절대 노출되지 않는다 (RLS).
-- =============================================================
create table if not exists public.game_moves (
  game_id      uuid not null references public.games(id) on delete cascade,
  user_id      uuid not null references public.profiles(user_id) on delete cascade,
  choice       rps_choice not null,
  submitted_at timestamptz not null default now(),
  primary key (game_id, user_id)
);
create index if not exists game_moves_game_idx on public.game_moves (game_id);

-- =============================================================
-- RLS (Row Level Security)
-- 원칙:
--  - 전적/게임 상태는 서버(RPC, SECURITY DEFINER)만 변경한다.
--  - 클라이언트의 직접 INSERT/UPDATE/DELETE 는 최대한 막는다.
--  - 상대 move 는 게임 종료(finished/void) 전까지 읽을 수 없다.
-- =============================================================
alter table public.profiles          enable row level security;
alter table public.matchmaking_queue enable row level security;
alter table public.games             enable row level security;
alter table public.game_participants enable row level security;
alter table public.game_moves        enable row level security;

-- ---- profiles ----
-- 읽기: 모든 로그인 사용자가 프로필(닉네임/전적) 조회 가능 (리더보드/상대 닉네임 표시)
create policy profiles_select_all on public.profiles
  for select to authenticated using (true);
-- 본인 프로필 생성은 닉네임 설정 RPC 로만 하도록 유도하되,
-- 최초 insert 는 본인 행만 허용 (닉네임 UNIQUE 가 중복 방지)
create policy profiles_insert_self on public.profiles
  for insert to authenticated with check (user_id = auth.uid());
-- 직접 UPDATE 는 닉네임만 허용하고 전적 컬럼은 RPC 에서만 변경.
-- (전적 보호는 아래 trigger 로 강제 — 클라이언트 UPDATE 시 전적 변경 차단)
create policy profiles_update_self on public.profiles
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
-- DELETE 금지 (정책 없음 = 거부)

-- ---- matchmaking_queue ----
-- 읽기: 본인 큐 상태만 조회 (대기 여부 확인)
create policy mmq_select_self on public.matchmaking_queue
  for select to authenticated using (user_id = auth.uid());
-- 클라이언트 직접 INSERT/UPDATE/DELETE 금지 -> enqueue/cancel 은 RPC 로만.
-- (정책을 만들지 않으므로 기본 거부)

-- ---- games ----
-- 읽기: 내가 참가자인 게임만 조회 가능
create policy games_select_participant on public.games
  for select to authenticated
  using (auth.uid() = player1 or auth.uid() = player2);
-- INSERT/UPDATE/DELETE 금지 -> 매칭/판정 RPC 로만.

-- ---- game_participants ----
create policy gp_select_self on public.game_participants
  for select to authenticated using (user_id = auth.uid());
-- 변경은 RPC 로만.

-- ---- game_moves ----
-- 핵심(보완 1): 내 move 는 언제든 읽을 수 있지만,
-- 상대 move 는 게임이 finished/void 가 된 뒤에만 읽을 수 있다.
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
-- INSERT/UPDATE/DELETE 금지 -> submit_move RPC 로만 접수.
-- (클라이언트가 직접 move 를 넣지 못하므로 마감시각 검증을 서버가 독점)
