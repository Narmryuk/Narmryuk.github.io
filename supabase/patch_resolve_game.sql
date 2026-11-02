-- =============================================================
-- 패치: resolve_game 의 enum 캐스트 수정
--
-- 원인: games.status 는 game_status enum 인데, 종료 처리 UPDATE 에서
--       case 식이 text 를 반환해 타입 불일치로 실패.
--       (cron expire_games 매 실행 실패 -> 방치 게임 미정리.
--        submit_move 즉시 resolve 경로도 같은 버그.)
-- 수정: case 결과를 ::game_status 로 명시 캐스트.
--
-- 적용: SQL Editor 에 붙여넣고 Run (함수 교체).
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

  -- 수정 지점: enum 명시 캐스트
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
