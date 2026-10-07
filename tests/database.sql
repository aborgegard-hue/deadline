\set ON_ERROR_STOP on
begin;
insert into auth.users(id) select md5('deadline-test-'||i)::uuid from generate_series(1,10) i;
set local role anon;
do $$ begin
  begin perform public.deadline('create','{}'); raise exception 'Unauthenticated execution allowed';
  exception when insufficient_privilege then null; end;
end $$;
set local role authenticated;
do $$
declare s jsonb; r jsonb; gid uuid; code text; n integer; i integer; killers integer;
        names text[]; private_role jsonb; target uuid;
begin
  perform set_config('request.jwt.claim.sub','',true);
  if not public.deadline('create','{}') ? 'error' then raise exception 'Null identity accepted'; end if;
  for n in 4..8 loop
    perform set_config('request.jwt.claim.sub',md5('deadline-test-1')::uuid::text,true);
    s := public.deadline('create',jsonb_build_object('name','Host','capacity',n));
    if s ? 'error' then raise exception 'Create failed: %',s; end if;
    gid := (s->>'id')::uuid; code := s->>'code';
    if s#>'{me,role}' <> 'null'::jsonb or s->'solution'<>'null'::jsonb then raise exception 'Secrets before dealing'; end if;
    if not public.deadline('deal',jsonb_build_object('game_id',gid)) ? 'error' then raise exception 'Deal accepted before full'; end if;
    for i in 2..n loop
      perform set_config('request.jwt.claim.sub',md5('deadline-test-'||i)::uuid::text,true);
      r := public.deadline('join',jsonb_build_object('code',code,'name','P'||i));
      if r ? 'error' then raise exception 'Join failed: %',r; end if;
      r := public.deadline('join',jsonb_build_object('code',code,'name','changed'));
      if jsonb_array_length(r->'players')<>i then raise exception 'Duplicate member on retry'; end if;
    end loop;
    perform set_config('request.jwt.claim.sub',md5('deadline-test-10')::uuid::text,true);
    if not public.deadline('join',jsonb_build_object('code',code,'name','Extra')) ? 'error' then raise exception 'Over capacity'; end if;
    if not public.deadline('state',jsonb_build_object('game_id',gid)) ? 'error' then raise exception 'Outsider read'; end if;
    perform set_config('request.jwt.claim.sub',md5('deadline-test-2')::uuid::text,true);
    if not public.deadline('deal',jsonb_build_object('game_id',gid,'uid',md5('deadline-test-1')::uuid)) ? 'error' then raise exception 'Host spoofing'; end if;
    begin perform deadline_private.state(gid); raise exception 'Internal function accessible';
      exception when insufficient_privilege then null; end;
    begin perform 1 from deadline_private.players; raise exception 'Private table readable';
      exception when insufficient_privilege then null; end;
    begin update deadline_private.games set host_uid=auth.uid(); raise exception 'Direct writes allowed';
      exception when insufficient_privilege then null; end;
    perform set_config('request.jwt.claim.sub',md5('deadline-test-1')::uuid::text,true);
    s := public.deadline('deal',jsonb_build_object('game_id',gid));
    if s->>'phase'<>'briefing' then raise exception 'Deal failed: %',s; end if;
    if not public.deadline('deal',jsonb_build_object('game_id',gid)) ? 'error' then raise exception 'Roles can be rerolled'; end if;
    if not public.deadline('start',jsonb_build_object('game_id',gid)) ? 'error' then raise exception 'Start accepted without ready'; end if;
    killers:=0; names:='{}';
    for i in 1..n loop
      perform set_config('request.jwt.claim.sub',md5('deadline-test-'||i)::uuid::text,true);
      s := public.deadline('state',jsonb_build_object('game_id',gid));
      private_role := s#>'{me,role}';
      if private_role->>'name'=any(names) then raise exception 'Duplicate role'; end if;
      names:=array_append(names,private_role->>'name');
      if (private_role->>'is_murderer')::boolean then killers:=killers+1; end if;
      if s->'solution'<>'null'::jsonb or jsonb_array_length(s->'clues')<>0 then raise exception 'Early clues/solution'; end if;
      for r in select value from jsonb_array_elements(s->'players') loop
        if r ? 'role' or r ? 'secret' or r ? 'is_murderer' or r ? 'uid' or r ? 'vote' then raise exception 'Other player secrets leaked'; end if;
      end loop;
      r := public.deadline('state',jsonb_build_object('game_id',gid,'uid',md5('deadline-test-1')::uuid));
      if r#>'{me,role}'<>private_role then raise exception 'Spoofed identity or unstable role'; end if;
      r := public.deadline('ready',jsonb_build_object('game_id',gid));
      if not (r#>>'{me,ready}')::boolean then raise exception 'Ready failed'; end if;
    end loop;
    if killers<>1 then raise exception 'Expected one murderer, got %',killers; end if;
    perform set_config('request.jwt.claim.sub',md5('deadline-test-1')::uuid::text,true);
    s := public.deadline('start',jsonb_build_object('game_id',gid));
    if s->>'phase'<>'playing' or jsonb_array_length(s->'clues')<>1 then raise exception 'Start/initial clue failure: %',s; end if;
    if not public.deadline('finish',jsonb_build_object('game_id',gid)) ? 'error' then raise exception 'Early reveal allowed'; end if;
    if not public.deadline('kick',jsonb_build_object('game_id',gid,'player_id',s#>>'{me,id}')) ? 'error' then raise exception 'Kick after dealing'; end if;
    if n<8 then
      target := (s#>>'{players,0,id}')::uuid;
      for i in 1..n loop
        perform set_config('request.jwt.claim.sub',md5('deadline-test-'||i)::uuid::text,true);
        r := public.deadline('vote',jsonb_build_object('game_id',gid,'player_id',gen_random_uuid()));
        if not r ? 'error' then raise exception 'Foreign vote target'; end if;
        r := public.deadline('vote',jsonb_build_object('game_id',gid,'player_id',target));
        if not (r#>>'{me,voted}')::boolean then raise exception 'Vote failed'; end if;
        if not public.deadline('vote',jsonb_build_object('game_id',gid,'player_id',target)) ? 'error' then raise exception 'Vote not locked'; end if;
      end loop;
      perform set_config('request.jwt.claim.sub',md5('deadline-test-1')::uuid::text,true);
      s := public.deadline('finish',jsonb_build_object('game_id',gid));
      if s->>'phase'<>'finished' or s->'solution'='null'::jsonb then raise exception 'Finish failed: %',s; end if;
    end if;
    perform set_config('deadline.test_game',gid::text,true);
    raise notice 'PASS: % players; authorization, private roles, capacity, phases, clues, votes',n;
  end loop;
end $$;
reset role;
update deadline_private.games set started_at=now()-interval '21 minutes' where id=current_setting('deadline.test_game')::uuid;
set local role authenticated;
do $$ declare s jsonb; begin
  perform set_config('request.jwt.claim.sub',md5('deadline-test-2')::uuid::text,true);
  s:=public.deadline('state',jsonb_build_object('game_id',current_setting('deadline.test_game')));
  if jsonb_array_length(s->'clues')<>3 or not (s->>'can_finish')::boolean then raise exception 'Server timeout failed'; end if;
  s:=public.deadline('finish',jsonb_build_object('game_id',current_setting('deadline.test_game')));
  if s->>'phase'<>'finished' then raise exception 'Nonhost cannot finish after timeout'; end if;
  raise notice 'PASS: server-authoritative clue unlocks and timeout without host';
end $$;
reset role;
update deadline_private.games set expires_at=now()-interval '1 minute' where id=current_setting('deadline.test_game')::uuid;
set local role authenticated;
do $$ begin
  if not public.deadline('state',jsonb_build_object('game_id',current_setting('deadline.test_game'))) ? 'error' then raise exception 'Expired game readable'; end if;
  raise notice 'PASS: expired game denied';
end $$;
rollback;
