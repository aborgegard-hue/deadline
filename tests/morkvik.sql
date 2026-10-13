begin;
do $test$
declare
 ids uuid[] := array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
 n integer; i integer; s jsonb; r jsonb; gid uuid; code text; killers integer; names text[]; suspect integer;
begin
 for i in 1..7 loop insert into auth.users(id) values(ids[i]); end loop;
 for n in 3..6 loop
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',ids[1]::text,true);
  s:=public.deadline('create',jsonb_build_object('name','Host','capacity',n));
  if s ? 'error' then raise exception 'create %: %',n,s; end if;
  gid:=(s->>'id')::uuid;code:=s->>'code';
  if jsonb_array_length(s->'suspects')<>6 then raise exception 'six suspects missing'; end if;
  if s->'solution'<>'null'::jsonb then raise exception 'early solution'; end if;
  for i in 2..n loop
   perform set_config('request.jwt.claim.sub',ids[i]::text,true);
   r:=public.deadline('join',jsonb_build_object('code',code,'name','P'||i));
   if r ? 'error' then raise exception 'join failed %',r;end if;
  end loop;
  perform set_config('request.jwt.claim.sub',ids[7]::text,true);
  if not public.deadline('state',jsonb_build_object('game_id',gid)) ? 'error' then raise exception 'outsider read'; end if;
  perform set_config('request.jwt.claim.sub',ids[1]::text,true);
  s:=public.deadline('deal',jsonb_build_object('game_id',gid));
  if s->>'phase'<>'briefing' then raise exception 'deal failed %',s;end if;
  if not public.deadline('deal',jsonb_build_object('game_id',gid)) ? 'error' then raise exception 'reroll accepted';end if;
  killers:=0;names:='{}';
  for i in 1..n loop
   perform set_config('request.jwt.claim.sub',ids[i]::text,true);
   s:=public.deadline('state',jsonb_build_object('game_id',gid));
   if s#>>'{me,role,name}'=any(names) then raise exception 'duplicate role';end if;
   names:=array_append(names,s#>>'{me,role,name}');
   if (s#>>'{me,role,is_murderer}')::boolean then killers:=killers+1;end if;
   for r in select value from jsonb_array_elements(s->'players') loop
    if r ? 'role' or r ? 'secret' or r ? 'is_murderer' or r ? 'vote' or r ? 'vote_slot' then raise exception 'private information leaked';end if;
   end loop;
   begin perform 1 from deadline_private.roles;raise exception 'private roles readable';exception when insufficient_privilege then null;end;
   perform public.deadline('ready',jsonb_build_object('game_id',gid));
  end loop;
  if killers<>1 then raise exception 'expected exactly one murderer';end if;
  perform set_config('request.jwt.claim.sub',ids[1]::text,true);
  s:=public.deadline('start',jsonb_build_object('game_id',gid));
  if jsonb_array_length(s->'clues')<>6 then raise exception 'wrong first clue count';end if;
  if not public.deadline('vote',jsonb_build_object('game_id',gid,'suspect_slot',1)) ? 'error' then raise exception 'early vote accepted';end if;
  execute 'reset role';
  update deadline_private.games set started_at=now()-interval '15 minutes' where id=gid;
  execute 'set local role authenticated';
  s:=public.deadline('state',jsonb_build_object('game_id',gid));
  if jsonb_array_length(s->'clues')<>12 then raise exception 'second clues failed';end if;
  if (s->>'vote_open')::boolean then raise exception 'vote unlocked early';end if;
  execute 'reset role';
  update deadline_private.games set started_at=now()-interval '50 minutes' where id=gid;
  execute 'set local role authenticated';
  if n=3 then
   -- Slot 6 is passive with three players and must remain a valid choice.
   r:=public.deadline('vote',jsonb_build_object('game_id',gid,'suspect_slot',6));
   if not (r#>>'{me,voted}')::boolean then raise exception 'passive suspect vote failed %',r;end if;
   if not public.deadline('vote',jsonb_build_object('game_id',gid,'suspect_slot',1)) ? 'error' then raise exception 'vote changed';end if;
  end if;
  for i in 1..n loop
   perform set_config('request.jwt.claim.sub',ids[i]::text,true);
   if not (n=3 and i=1) then
    suspect:=case when n=4 and i>2 then 2 else 1 end;
    r:=public.deadline('vote',jsonb_build_object('game_id',gid,'suspect_slot',suspect));
    if not (r#>>'{me,voted}')::boolean then raise exception 'vote failed %',r;end if;
   end if;
  end loop;
  perform set_config('request.jwt.claim.sub',ids[1]::text,true);
  s:=public.deadline('finish',jsonb_build_object('game_id',gid));
  if s->>'phase'<>'finished' or s->'solution'='null'::jsonb then raise exception 'finish failed %',s;end if;
  if jsonb_array_length(s#>'{solution,votes}')<>6 then raise exception 'tally missing';end if;
  if s#>>'{solution,winner}'<>(case when n=4 then 'murderer' else 'innocents' end) then raise exception 'winner calculation failed %',s;end if;
  execute 'reset role';
 end loop;
 execute 'set local role authenticated';
 perform set_config('request.jwt.claim.sub',ids[1]::text,true);
 if not public.deadline('create','{"name":"Host","capacity":2}') ? 'error' then raise exception '2 players accepted';end if;
 if not public.deadline('create','{"name":"Host","capacity":7}') ? 'error' then raise exception '7 players accepted';end if;
 execute 'reset role';
end;
$test$;
select 'PASS 3 4 5 6 players one murderer private roles clues passive votes locked votes winners' as result;
rollback;
