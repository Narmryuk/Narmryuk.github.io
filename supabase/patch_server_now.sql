-- =============================================================
-- 패치: 서버 시각 반환 RPC (카운트다운 로컬 시계 오프셋 보정)
--
-- 원인: 클라이언트 카운트다운이 (deadline - Date.now()) 로 계산되어
--       브라우저 시계가 서버보다 빠르면 시작하자마자 0 이 되어
--       선택도 못 하고 '시간 종료'로 넘어감.
-- 해결: 서버 now() 를 받아 offset(서버-로컬)을 구하고
--       remain = deadline - (Date.now()+offset) 로 보정.
--
-- 적용: SQL Editor 에 붙여넣고 Run.
-- =============================================================

create or replace function public.server_now()
returns timestamptz
language sql
stable
as $$ select now(); $$;

revoke execute on function public.server_now() from public;
grant execute on function public.server_now() to anon, authenticated;
