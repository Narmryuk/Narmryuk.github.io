-- =============================================================
-- 패치: 테이블 레벨 GRANT 추가 (4단계 403 문제 해결)
--
-- 원인: 프로젝트 생성 시 "Automatically expose new tables" 를 꺼서
--       authenticated 롤에 테이블 접근(GRANT)이 없음 ->
--       "permission denied for table profiles" (403).
--       (RPC 는 SECURITY DEFINER 라 영향 없이 동작했음.)
--
-- 적용: SQL Editor 에 붙여넣고 Run. 재실행 안전.
-- =============================================================

grant usage on schema public to authenticated;

-- 클라이언트가 직접 SELECT 하는 테이블 (행 제한은 RLS 가 담당)
grant select on public.profiles          to authenticated;
grant select on public.games             to authenticated;
grant select on public.game_moves        to authenticated;
grant select on public.game_participants to authenticated;
grant select on public.matchmaking_queue to authenticated;

-- 닉네임 변경용 UPDATE (전적 컬럼은 guard_profile_stats 트리거가 차단)
grant update on public.profiles          to authenticated;

-- 확인용:
--   select grantee, privilege_type, table_name
--   from information_schema.role_table_grants
--   where table_schema='public' and grantee='authenticated'
--   order by table_name, privilege_type;
