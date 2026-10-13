-- Engine update only. Real case content is imported privately, never into this public repository.
begin;
alter table deadline_private.games drop constraint games_capacity_check;
alter table deadline_private.games add constraint games_capacity_check check (capacity between 3 and 8);
alter table deadline_private.players add column if not exists vote_slot integer check (vote_slot between 1 and 6);
create or replace function deadline_private.state(p_game uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  g deadline_private.games; me deadline_private.players; c deadline_private.cases;
  people jsonb; evidence jsonb; ending jsonb; suspects jsonb; tally jsonb; killer_slot integer; top_votes integer; winner text; vote_open boolean; n integer; nready integer; nvotes integer;
begin
  select * into g from deadline_private.games where id=p_game for share;
  select * into me from deadline_private.players where game_id=p_game and uid=auth.uid();
  if g.id is null or me.id is null or g.expires_at <= now() then
    return jsonb_build_object('error','Omgången finns inte, har gått ut eller tillhör inte dig.');
  end if;
  select * into c from deadline_private.cases where slug=g.case_slug;
  select count(*), count(*) filter(where ready), count(*) filter(where vote is not null or vote_slot is not null),
    jsonb_agg(jsonb_build_object('id',id,'name',name,'persona',role->>'name',
      'ready',ready,'voted',vote is not null or vote_slot is not null) order by joined_at,id)
    into n,nready,nvotes,people from deadline_private.players where game_id=g.id;
  select coalesce(jsonb_agg(jsonb_build_object('title',title,'body',body) order by sequence),'[]'::jsonb)
    into evidence from deadline_private.clues
    where case_slug=g.case_slug and g.phase in ('playing','finished')
      and (g.phase='finished' or unlock_seconds <= extract(epoch from now()-g.started_at));
  vote_open := g.case_slug<>'morkvik-v1' or (g.started_at is not null and now()>=g.started_at+interval '50 minutes');
  select coalesce(jsonb_agg(jsonb_build_object('id',slot::text,'name',content->>'name') order by slot),'[]'::jsonb)
    into suspects from deadline_private.roles where case_slug=g.case_slug;
  if g.phase='finished' then
    select jsonb_build_object('text',c.solution,'player',name,'persona',role->>'name')
      into ending from deadline_private.players
      where game_id=g.id and (role->>'is_murderer')::boolean is true;
    if g.case_slug='morkvik-v1' then
      select slot into killer_slot from deadline_private.roles where case_slug=g.case_slug and (content->>'is_murderer')::boolean;
      select coalesce(jsonb_agg(jsonb_build_object('name',r.content->>'name','votes',v.n) order by r.slot),'[]'::jsonb),max(v.n)
        into tally,top_votes from deadline_private.roles r
        cross join lateral (select count(*)::integer n from deadline_private.players p where p.game_id=g.id and p.vote_slot=r.slot) v
        where r.case_slug=g.case_slug;
      winner := case when top_votes>0
        and (select count(*) from deadline_private.players where game_id=g.id and vote_slot=killer_slot)=top_votes
        and (select count(*) from jsonb_array_elements(tally) x where (x->>'votes')::integer=top_votes)=1
        then 'innocents' else 'murderer' end;
      ending := ending || jsonb_build_object('slot',killer_slot::text,'votes',tally,'winner',winner);
    end if;
  end if;
  return jsonb_build_object(
    'id',g.id,'code',g.code,'phase',g.phase,'capacity',g.capacity,
    'title',c.title,'introduction',c.introduction,'server_now',clock_timestamp(),
    'started_at',g.started_at,'duration_seconds',c.duration_seconds,'expires_at',g.expires_at,
    'me',jsonb_build_object('id',me.id,'name',me.name,'is_host',g.host_uid=auth.uid(),
      'role',me.role,'ready',me.ready,'voted',me.vote is not null or me.vote_slot is not null,'vote',me.vote,'vote_slot',me.vote_slot),
    'players',people,'suspects',case when g.case_slug='morkvik-v1' then suspects else null end,'clues',evidence,'solution',ending,'vote_open',vote_open,
    'can_start',g.phase='briefing' and n=g.capacity and nready=n,
    'can_finish',g.phase='playing' and
      ((g.host_uid=auth.uid() and nvotes=n) or now()>=g.started_at+make_interval(secs=>c.duration_seconds))
  );
end;
$$;

create or replace function deadline_private.dispatch(action text, payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid(); g deadline_private.games; p deadline_private.players;
  gid uuid; target uuid; label text; lobby_code text; cap integer; attempt integer;
  bucket_time timestamptz; deck jsonb[]; participant record; i integer := 1;
  duration integer; n integer; is_host boolean; selected_case text; suspect_slot integer;
begin
  if u is null then return jsonb_build_object('error','Du behöver en spelarsession. Ladda om sidan.'); end if;
  if payload is null or jsonb_typeof(payload)<>'object' then
    return jsonb_build_object('error','Ogiltig begäran.');
  end if;
  if action not in ('create','join','state','deal','ready','start','vote','finish','kick','leave') or action is null then
    return jsonb_build_object('error','Okänt kommando.');
  end if;
  if action in ('create','join') then
    bucket_time := date_trunc(case when action='create' then 'hour' else 'minute' end,now());
    insert into deadline_private.rate_limits(uid,operation,bucket,count) values(u,action,bucket_time,1)
      on conflict (uid,operation,bucket) do update set count=deadline_private.rate_limits.count+1
      returning count into attempt;
    if attempt > (case when action='create' then 10 else 20 end) then
      return jsonb_build_object('error','För många försök. Vänta en stund.');
    end if;
    label := btrim(payload->>'name');
    if label is null or char_length(label) not between 1 and 24 or label ~ '[[:cntrl:]]' then
      return jsonb_build_object('error','Skriv ett namn eller smeknamn med 1–24 tecken.');
    end if;
  end if;
  if action='create' then
    selected_case := coalesce(payload->>'case_slug','morkvik-v1');
    if selected_case not in ('morkvik-v1','demo-v1') then return jsonb_build_object('error','Okänt fall.'); end if;
    if (selected_case='morkvik-v1' and coalesce(payload->>'capacity','') !~ '^[3-6]$') or
       (selected_case='demo-v1' and coalesce(payload->>'capacity','') !~ '^[4-8]$') then
      return jsonb_build_object('error','Välj ett giltigt spelarantal. Mörkvik spelas med 3–6 personer.');
    end if;
    if not exists(select 1 from deadline_private.cases where slug=selected_case) then
      return jsonb_build_object('error','Fallet saknas i databasen.');
    end if;
    cap := (payload->>'capacity')::integer;
    -- 40 random bits; collision retries and the insert are in one transaction.
    for i in 1..5 loop
      lobby_code := upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
      insert into deadline_private.games(code,host_uid,case_slug,capacity)
        values(lobby_code,u,selected_case,cap) on conflict(code) do nothing returning * into g;
      exit when g.id is not null;
    end loop;
    if g.id is null then return jsonb_build_object('error','Kunde inte skapa en kod. Försök igen.'); end if;
    insert into deadline_private.players(game_id,uid,name) values(g.id,u,label);
    return deadline_private.state(g.id);
  elsif action='join' then
    lobby_code := regexp_replace(upper(coalesce(payload->>'code','')),'[[:space:]-]','','g');
    if lobby_code !~ '^[A-F0-9]{10}$' then
      return jsonb_build_object('error','Spelkoden ska innehålla 10 tecken.');
    end if;
    -- Serialize joins and role assignment: the last two phones cannot overfill a lobby.
    select * into g from deadline_private.games where code=lobby_code for update;
    if g.id is null or g.expires_at<=now() then
      return jsonb_build_object('error','Ingen aktiv omgång hittades med den koden.');
    end if;
    if exists(select 1 from deadline_private.players where game_id=g.id and uid=u) then
      return deadline_private.state(g.id); -- Safe retry/reconnect; never creates a second player.
    end if;
    if g.phase<>'lobby' then return jsonb_build_object('error','Rollerna är redan utdelade. Nya spelare kan inte ansluta.'); end if;
    if (select count(*) from deadline_private.players where game_id=g.id)>=g.capacity then
      return jsonb_build_object('error','Omgången är full.');
    end if;
    if exists(select 1 from deadline_private.players where game_id=g.id and lower(name)=lower(label)) then
      return jsonb_build_object('error','Namnet används redan. Välj ett annat.');
    end if;
    insert into deadline_private.players(game_id,uid,name) values(g.id,u,label);
    return deadline_private.state(g.id);
  end if;
  if coalesce(payload->>'game_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('error','Ogiltig spelomgång.');
  end if;
  gid := (payload->>'game_id')::uuid;
  if action='state' then return deadline_private.state(gid); end if;
  select * into g from deadline_private.games where id=gid for update;
  select * into p from deadline_private.players where game_id=gid and uid=u;
  if g.id is null or p.id is null or g.expires_at<=now() then
    return jsonb_build_object('error','Omgången finns inte, har gått ut eller tillhör inte dig.');
  end if;
  is_host := g.host_uid=u;
  if action in ('deal','start','kick') and not is_host then
    return jsonb_build_object('error','Bara värden kan göra det.');
  end if;
  if action='deal' then
    if g.phase<>'lobby' then return jsonb_build_object('error','Rollerna är redan utdelade.'); end if;
    if (select count(*) from deadline_private.players where game_id=gid)<>g.capacity then
      return jsonb_build_object('error','Vänta tills alla spelare är med.');
    end if;
    select array_agg(content order by gen_random_uuid()) into deck
      from deadline_private.roles where case_slug=g.case_slug and slot<=g.capacity;
    if coalesce(array_length(deck,1),0)<>g.capacity or
      (select count(*) from unnest(deck) r where (r->>'is_murderer')::boolean is true)<>1 then
      return jsonb_build_object('error','Fallet saknar en giltig uppsättning roller.');
    end if;
    i := 1;
    for participant in select id from deadline_private.players where game_id=gid order by joined_at,id loop
      update deadline_private.players set role=deck[i] where id=participant.id;
      i := i+1;
    end loop;
    update deadline_private.games set phase='briefing' where id=gid;
  elsif action='ready' then
    if g.phase<>'briefing' then return jsonb_build_object('error','Det är inte läsfas nu.'); end if;
    update deadline_private.players set ready=true where id=p.id;
  elsif action='start' then
    if g.phase<>'briefing' or exists(select 1 from deadline_private.players where game_id=gid and not ready) then
      return jsonb_build_object('error','Alla måste läsa sin roll och trycka Redo först.');
    end if;
    update deadline_private.games set phase='playing',started_at=now() where id=gid;
  elsif action='vote' then
    if g.phase<>'playing' then return jsonb_build_object('error','Utredningen har inte startat eller är avslutad.'); end if;
    if p.vote is not null or p.vote_slot is not null then return jsonb_build_object('error','Din slutanklagelse är redan inlämnad.'); end if;
    if g.case_slug='morkvik-v1' then
      if now()<g.started_at+interval '50 minutes' then return jsonb_build_object('error','Slutanklagelser öppnas efter 50 minuter.'); end if;
      if coalesce(payload->>'suspect_slot','') !~ '^[1-6]$' then return jsonb_build_object('error','Välj en av de sex misstänkta.'); end if;
      suspect_slot := (payload->>'suspect_slot')::integer;
      if not exists(select 1 from deadline_private.roles where case_slug=g.case_slug and slot=suspect_slot) then return jsonb_build_object('error','Ogiltig misstänkt.'); end if;
      update deadline_private.players set vote_slot=suspect_slot where id=p.id;
    else
    if coalesce(payload->>'player_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      return jsonb_build_object('error','Välj en misstänkt.');
    end if;
    target := (payload->>'player_id')::uuid;
    if not exists(select 1 from deadline_private.players where game_id=gid and id=target) then
      return jsonb_build_object('error','Personen finns inte i den här omgången.');
    end if;
    if p.vote is not null then return jsonb_build_object('error','Din slutanklagelse är redan inlämnad.'); end if;
    update deadline_private.players set vote=target where id=p.id;
    end if;
  elsif action='finish' then
    if g.phase<>'playing' then return jsonb_build_object('error','Utredningen är inte igång.'); end if;
    select duration_seconds into duration from deadline_private.cases where slug=g.case_slug;
    -- Any member may finish after timeout, even if the host lost their phone.
    if now()<g.started_at+make_interval(secs=>duration) and
      (not is_host or exists(select 1 from deadline_private.players where game_id=gid and vote is null and vote_slot is null)) then
      return jsonb_build_object('error','Invänta alla slutanklagelser eller att tiden tar slut.');
    end if;
    update deadline_private.games set phase='finished' where id=gid;
  elsif action in ('kick','leave') then
    if g.phase<>'lobby' then return jsonb_build_object('error','Spelare kan bara tas bort innan rollerna delas ut.'); end if;
    if action='leave' then
      if is_host then return jsonb_build_object('error','Värden behöver stanna i lobbyn.'); end if;
      delete from deadline_private.players where id=p.id;
      return jsonb_build_object('left',true);
    end if;
    if coalesce(payload->>'player_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      return jsonb_build_object('error','Ogiltig spelare.');
    end if;
    delete from deadline_private.players where game_id=gid and id=(payload->>'player_id')::uuid and uid<>u;
  end if;
  return deadline_private.state(gid);
end;
$$;

notify pgrst, 'reload schema';
commit;
