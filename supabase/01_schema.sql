-- Deadline UF: first-install migration for a dedicated Supabase project.
-- Run as postgres in SQL Editor. No elevated key belongs in the website.
-- Tables have RLS with no client policies. The API exposes only a checked RPC.
begin;
create schema if not exists deadline_private;
revoke all on schema deadline_private from public, anon, authenticated;
grant usage on schema deadline_private to authenticated;

create table if not exists deadline_private.cases (
  slug text primary key,
  title text not null,
  introduction text not null,
  solution text not null,
  duration_seconds integer not null check (duration_seconds between 60 and 7200)
);
create table if not exists deadline_private.roles (
  case_slug text not null references deadline_private.cases(slug) on delete cascade,
  slot integer not null check (slot between 1 and 8),
  content jsonb not null,
  primary key (case_slug, slot)
);
create table if not exists deadline_private.clues (
  case_slug text not null references deadline_private.cases(slug) on delete cascade,
  sequence integer not null,
  unlock_seconds integer not null check (unlock_seconds >= 0),
  title text not null,
  body text not null,
  primary key (case_slug, sequence)
);
create table if not exists deadline_private.games (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  host_uid uuid not null references auth.users(id) on delete cascade,
  case_slug text not null references deadline_private.cases(slug),
  capacity integer not null check (capacity between 4 and 8),
  phase text not null default 'lobby' check (phase in ('lobby','briefing','playing','finished')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',
  started_at timestamptz
);
create index if not exists deadline_games_host on deadline_private.games(host_uid, created_at);
create table if not exists deadline_private.players (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references deadline_private.games(id) on delete cascade,
  uid uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 24),
  joined_at timestamptz not null default clock_timestamp(),
  role jsonb,
  ready boolean not null default false,
  vote uuid,
  unique (game_id, uid)
);
create unique index if not exists deadline_player_names on deadline_private.players(game_id, lower(name));
create index if not exists deadline_players_uid on deadline_private.players(uid);
create table if not exists deadline_private.rate_limits (
  uid uuid not null references auth.users(id) on delete cascade,
  operation text not null,
  bucket timestamptz not null,
  count integer not null,
  primary key (uid, operation, bucket)
);
alter table deadline_private.cases enable row level security;
alter table deadline_private.roles enable row level security;
alter table deadline_private.clues enable row level security;
alter table deadline_private.games enable row level security;
alter table deadline_private.players enable row level security;
alter table deadline_private.rate_limits enable row level security;
revoke all on all tables in schema deadline_private from public, anon, authenticated;
alter default privileges in schema deadline_private revoke all on tables from public, anon, authenticated;
alter default privileges in schema deadline_private revoke execute on functions from public, anon, authenticated;

-- Called only by the dispatcher as its owner. Never granted to API users.
create or replace function deadline_private.state(p_game uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  g deadline_private.games; me deadline_private.players; c deadline_private.cases;
  people jsonb; evidence jsonb; ending jsonb; n integer; nready integer; nvotes integer;
begin
  select * into g from deadline_private.games where id=p_game for share;
  select * into me from deadline_private.players where game_id=p_game and uid=auth.uid();
  if g.id is null or me.id is null or g.expires_at <= now() then
    return jsonb_build_object('error','Omgången finns inte, har gått ut eller tillhör inte dig.');
  end if;
  select * into c from deadline_private.cases where slug=g.case_slug;
  select count(*), count(*) filter(where ready), count(vote),
    jsonb_agg(jsonb_build_object('id',id,'name',name,'persona',role->>'name',
      'ready',ready,'voted',vote is not null) order by joined_at,id)
    into n,nready,nvotes,people from deadline_private.players where game_id=g.id;
  select coalesce(jsonb_agg(jsonb_build_object('title',title,'body',body) order by sequence),'[]'::jsonb)
    into evidence from deadline_private.clues
    where case_slug=g.case_slug and g.phase in ('playing','finished')
      and (g.phase='finished' or unlock_seconds <= extract(epoch from now()-g.started_at));
  if g.phase='finished' then
    select jsonb_build_object('text',c.solution,'player',name,'persona',role->>'name')
      into ending from deadline_private.players
      where game_id=g.id and (role->>'is_murderer')::boolean is true;
  end if;
  return jsonb_build_object(
    'id',g.id,'code',g.code,'phase',g.phase,'capacity',g.capacity,
    'title',c.title,'introduction',c.introduction,'server_now',clock_timestamp(),
    'started_at',g.started_at,'duration_seconds',c.duration_seconds,'expires_at',g.expires_at,
    'me',jsonb_build_object('id',me.id,'name',me.name,'is_host',g.host_uid=auth.uid(),
      'role',me.role,'ready',me.ready,'voted',me.vote is not null,'vote',me.vote),
    'players',people,'clues',evidence,'solution',ending,
    'can_start',g.phase='briefing' and n=g.capacity and nready=n,
    'can_finish',g.phase='playing' and
      ((g.host_uid=auth.uid() and nvotes=n) or now()>=g.started_at+make_interval(secs=>c.duration_seconds))
  );
end;
$$;

-- All authorization uses the signed Supabase identity, never a submitted UID.
-- Expected failures return JSON (not RAISE), so rate-limit counters commit.
create or replace function deadline_private.dispatch(action text, payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid(); g deadline_private.games; p deadline_private.players;
  gid uuid; target uuid; label text; lobby_code text; cap integer; attempt integer;
  bucket_time timestamptz; deck jsonb[]; participant record; i integer := 1;
  duration integer; n integer; is_host boolean;
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
    if attempt > case when action='create' then 10 else 20 end then
      return jsonb_build_object('error','För många försök. Vänta en stund.');
    end if;
    label := btrim(payload->>'name');
    if label is null or char_length(label) not between 1 and 24 or label ~ '[[:cntrl:]]' then
      return jsonb_build_object('error','Skriv ett namn eller smeknamn med 1–24 tecken.');
    end if;
  end if;
  if action='create' then
    if coalesce(payload->>'capacity','') !~ '^[4-8]$' then
      return jsonb_build_object('error','Välj 4–8 spelare, inklusive dig själv.');
    end if;
    if not exists(select 1 from deadline_private.cases where slug='demo-v1') then
      return jsonb_build_object('error','Testfallet saknas. Administratören behöver köra 02_demo.sql.');
    end if;
    cap := (payload->>'capacity')::integer;
    -- 40 random bits; collision retries and the insert are in one transaction.
    for i in 1..5 loop
      lobby_code := upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
      insert into deadline_private.games(code,host_uid,case_slug,capacity)
        values(lobby_code,u,'demo-v1',cap) on conflict(code) do nothing returning * into g;
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
    if coalesce(payload->>'player_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      return jsonb_build_object('error','Välj en misstänkt.');
    end if;
    target := (payload->>'player_id')::uuid;
    if not exists(select 1 from deadline_private.players where game_id=gid and id=target) then
      return jsonb_build_object('error','Personen finns inte i den här omgången.');
    end if;
    if p.vote is not null then return jsonb_build_object('error','Din slutanklagelse är redan inlämnad.'); end if;
    update deadline_private.players set vote=target where id=p.id;
  elsif action='finish' then
    if g.phase<>'playing' then return jsonb_build_object('error','Utredningen är inte igång.'); end if;
    select duration_seconds into duration from deadline_private.cases where slug=g.case_slug;
    -- Any member may finish after timeout, even if the host lost their phone.
    if now()<g.started_at+make_interval(secs=>duration) and
      (not is_host or exists(select 1 from deadline_private.players where game_id=gid and vote is null)) then
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

create or replace function public.deadline(action text, payload jsonb default '{}'::jsonb)
returns jsonb language sql security invoker set search_path = '' as $$
  select deadline_private.dispatch(action,payload);
$$;
revoke all on all functions in schema deadline_private from public, anon, authenticated;
grant execute on function deadline_private.dispatch(text,jsonb) to authenticated;
revoke all on function public.deadline(text,jsonb) from public, anon, authenticated;
grant execute on function public.deadline(text,jsonb) to authenticated;
notify pgrst, 'reload schema';
commit;
