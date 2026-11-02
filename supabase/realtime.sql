-- =============================================================
-- TMSI 실시간 가위바위보 — Realtime private 채널 구독 인가 (결정 3)
-- 적용: schema.sql, functions.sql 다음에 실행 (cron.sql 과는 순서 무관).
--
-- 설계:
--  - 모든 게임 Realtime 은 private 채널(realtime.send(..., private => true))로만 전송.
--  - 클라이언트는 "구독(수신)"만 하고, 메시지 전송(INSERT)은 서버 RPC 만 한다.
--  - 구독 인가는 realtime.messages 테이블의 SELECT RLS 로 통제한다.
--  - 토픽 규칙:  user:{uid}  (매칭 알림, 본인만)
--               game:{game_id} (게임 이벤트, 해당 게임 참가자만)
--
-- realtime.topic() : 현재 접속하려는 채널의 토픽 문자열을 반환하는 헬퍼.
-- =============================================================

-- realtime.messages 는 Supabase 가 관리하는 테이블이며 RLS 가 기본 활성.
-- (ALTER 로 owner 를 바꾸려 하면 실패하므로 정책만 추가한다.)

-- -------------------------------------------------------------
-- 1) 구독(수신) 인가 — SELECT
--    user:{uid} 는 본인만, game:{id} 는 해당 게임 참가자만 구독 가능.
--    그 외 토픽은 모두 거부(정책 USING 이 false).
-- -------------------------------------------------------------
drop policy if exists "tmsi realtime subscribe" on realtime.messages;
create policy "tmsi realtime subscribe"
on realtime.messages
for select
to authenticated
using (
  -- (a) 본인 전용 매칭 채널
  realtime.topic() = 'user:' || auth.uid()::text
  or
  -- (b) 참가 중인 게임 채널
  (
    realtime.topic() like 'game:%'
    and exists (
      select 1 from public.games g
      where g.id = (substring(realtime.topic() from 6))::uuid
        and (g.player1 = auth.uid() or g.player2 = auth.uid())
    )
  )
);

-- -------------------------------------------------------------
-- 2) 전송(INSERT) 인가 — 클라이언트 전송 전면 금지
--    모든 메시지는 서버 RPC(realtime.send, SECURITY DEFINER)만 보낸다.
--    authenticated 롤에 INSERT 정책을 만들지 않으므로 클라이언트 전송은 기본 거부.
--    (명시적으로 거부 정책을 두어 의도를 분명히 한다.)
-- -------------------------------------------------------------
drop policy if exists "tmsi realtime no client send" on realtime.messages;
create policy "tmsi realtime no client send"
on realtime.messages
for insert
to authenticated
with check (false);

-- -------------------------------------------------------------
-- 참고:
--  - RLS 정책에 쓰이는 games(player1/player2) 인덱스는 schema.sql 에 이미 있음.
--  - 토픽 파싱: 'game:' 는 5글자이므로 substring(... from 6) 이 UUID 부분.
--  - 잘못된 UUID 형식 토픽은 캐스팅 실패로 접근 거부된다.
-- -------------------------------------------------------------
