-- =============================================================
-- TMSI 실시간 가위바위보 — pg_cron 스케줄 (서버 측 만료 백스톱)
-- 적용: schema.sql, functions.sql 다음에 실행.
--
-- [사전 준비 — 대시보드에서 1회]
--   Supabase Dashboard > Database > Extensions 에서 pg_cron 활성화.
--   무료 플랜에서 초 단위(1~59초) 스케줄 지원 (Postgres 15.1.1.61+).
--
-- 설계 의도 (보완 3):
--   - 판정의 "정답"은 games.deadline 이다. cron 은 '미선택 만료'의 안전망.
--   - 양쪽이 제때 다 내면 submit_move 가 즉시 resolve 하므로 cron 을 안 기다린다.
--   - cron 이 몇 초 늦게 돌아도 판정은 deadline 기준이라 결과가 불변.
-- =============================================================

-- 5초마다 만료 게임 정리 + 큐 매칭 시도
-- (권장: 동시 잡 8개 이내, 각 잡 10분 이내 — 본 잡은 수 ms 로 끝남)

-- 1) 만료 게임 종료 처리 (5초 주기)
select cron.schedule(
  'tmsi-expire-games',
  '5 seconds',
  $$ select public.expire_games(); $$
);

-- 2) 매칭 큐 소진 (5초 주기)
--    enqueue 직후 즉시 1회 호출 + cron 주기 호출을 병행해 대기시간 단축.
select cron.schedule(
  'tmsi-find-match',
  '5 seconds',
  $$ select public.find_match(); $$
);

-- -------------------------------------------------------------
-- 참고: 스케줄 해제가 필요하면
--   select cron.unschedule('tmsi-expire-games');
--   select cron.unschedule('tmsi-find-match');
-- 등록 확인:
--   select * from cron.job;
-- -------------------------------------------------------------
