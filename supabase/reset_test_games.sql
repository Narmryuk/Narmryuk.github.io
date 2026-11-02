-- =============================================================
-- 테스트 데이터 초기화 (매칭/게임 관련만)
--
-- 목적: 앞선 테스트로 남은 active 게임/대기열/참가자 기록을 비워
--       "이미 진행 중인 게임" 상태를 해제한다.
--
-- 범위: 게임 진행 데이터만 삭제. profiles(계정/전적)는 건드리지 않는다.
--       전적을 0으로 초기화하고 싶으면 맨 아래 선택 블록을 함께 실행.
--
-- 주의: 테스트 단계 전용. 운영 데이터가 있으면 실행하지 말 것.
-- =============================================================

-- 진행 데이터 비우기 (FK cascade 로 game_moves/game_participants 도 정리되지만 명시적으로)
delete from public.game_moves;
delete from public.game_participants;
delete from public.matchmaking_queue;
delete from public.games;

-- (선택) 전적도 0으로 초기화하려면 아래 주석을 해제해서 함께 실행:
-- update public.profiles
--    set total_games=0, total_wins=0, total_losses=0,
--        total_draws=0, current_win_streak=0, max_win_streak=0;

-- 확인:
--   select count(*) as games from public.games;
--   select count(*) as queue from public.matchmaking_queue;
