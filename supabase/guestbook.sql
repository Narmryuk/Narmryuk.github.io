-- =============================================================
-- TMSI 홈페이지 — 공개 방명록 (익명 허용, 실시간)
--
-- 설계:
--  - RPS 로그인과 무관. 비로그인(anon)도 작성 가능(수업용, 스팸 無).
--  - 누구나 읽기/쓰기. 수정/삭제는 불가(익명이라 본인 글 구분 불가).
--  - 길이 검증은 테이블 CHECK 로 서버에서 강제.
--  - 실시간: Postgres Changes(INSERT) 구독 -> supabase_realtime publication 에 추가.
--  - XSS 는 클라이언트에서 textContent 렌더로 방어(기존 방식 유지).
--
-- 적용: SQL Editor 에 붙여넣고 Run. 재실행 안전.
-- =============================================================

create table if not exists public.guestbook (
  id         bigint generated always as identity primary key,
  name       text not null,
  message    text not null,
  created_at timestamptz not null default now(),
  constraint guestbook_name_len    check (char_length(btrim(name))    between 1 and 20),
  constraint guestbook_message_len check (char_length(btrim(message)) between 1 and 200)
);

create index if not exists guestbook_created_idx
  on public.guestbook (created_at desc);

alter table public.guestbook enable row level security;

-- 누구나 읽기 (anon + authenticated)
drop policy if exists guestbook_read on public.guestbook;
create policy guestbook_read on public.guestbook
  for select to anon, authenticated using (true);

-- 누구나 쓰기 (길이는 테이블 CHECK 가 강제)
drop policy if exists guestbook_insert on public.guestbook;
create policy guestbook_insert on public.guestbook
  for insert to anon, authenticated with check (true);

-- 수정/삭제 정책은 만들지 않음 -> 기본 거부.

-- 테이블 접근 GRANT (Automatically expose new tables 를 꺼놨으므로 필요)
grant usage on schema public to anon, authenticated;
grant select, insert on public.guestbook to anon, authenticated;

-- -------------------------------------------------------------
-- 실시간: guestbook 을 Realtime publication 에 추가
-- (이미 추가돼 있으면 에러가 날 수 있어 do 블록으로 안전 처리)
-- -------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.guestbook;
exception
  when duplicate_object then null;  -- 이미 추가됨
  when others then null;            -- publication 미존재 등은 무시(대시보드 토글로 대체 가능)
end $$;

-- 확인용:
--   select * from pg_publication_tables where pubname='supabase_realtime' and tablename='guestbook';
