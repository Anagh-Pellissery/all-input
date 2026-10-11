-- All-in Put — Supabase schema.
-- Run once in Supabase Dashboard → SQL Editor. Safe to re-run; saved admin auction settings are preserved.
--
-- Security model:
--   * Every table has RLS on and NO policies for anon/authenticated, so the browser
--     (publishable key) cannot read or write game data directly.
--   * The only thing the browser can read is public_state (a snapshot of what every
--     screen already shows publicly) and server_now() (clock sync).
--   * All game rules run inside the game_* functions below, executable only by the
--     service role (used by the Vercel API with the secret key).
--   * Every mutation takes one advisory lock, so simultaneous bids/purchases from
--     many teams are applied one at a time — no double-spending or lost updates.
--   * Supabase blocks UPDATE/DELETE without WHERE (pg_safeupdate), hence the "where true" on bulk resets.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tables
create table if not exists settings (
  id int primary key default 1 check (id = 1),
  mult numeric not null default 2,
  default_credits int not null default 15000,
  base_min numeric not null default 15,
  started_at timestamptz
);

create table if not exists teams (
  id bigint generated always as identity primary key,
  username text not null unique,
  password_hash text not null,
  credits int not null default 0,
  token_ver int not null default 1, -- bumped on password change to log out old sessions
  created_at timestamptz not null default now()
);

create table if not exists shop_components (
  id text primary key,
  sort int not null,
  name text not null,
  qty int not null check (qty >= 0),
  price int not null check (price >= 0),
  default_qty int not null -- restored by "Reset all event data"
);

create table if not exists auction_items (
  id text primary key,
  sort int not null,
  name text not null,
  reveal_name text,
  time_sec int not null default 0, -- 0 = no limit
  qty int not null default 0,      -- number of auction rounds
  base int not null default 0,
  inc int not null default 0,
  next_price int not null default 0
);
alter table auction_items add column if not exists reveal_name text;

create table if not exists inventory (
  team_id bigint not null references teams(id) on delete cascade,
  item_id text not null,
  qty int not null,
  primary key (team_id, item_id)
);

create table if not exists orders (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  team_id bigint references teams(id) on delete set null,
  team_name text not null,
  item text not null,
  qty int not null,
  total int not null,
  phase text not null
);
create index if not exists orders_team_idx on orders (team_id, id desc);

create table if not exists auction_state (
  id int primary key default 1 check (id = 1),
  status text not null default 'idle' check (status in ('idle', 'live', 'paused', 'done')),
  queue text[] not null default '{}',
  lot_item_id text,
  lot_name text,
  lot_start int,
  lot_time int,
  lot_bid int not null default 0,
  lot_leader_id bigint,
  lot_leader_name text,
  lot_ends_at timestamptz,
  lot_remaining_ms int,
  lot_bids jsonb not null default '[]'
);
-- every team that bid on the lot on the block, and the same for the lot before it (shown with balances on the display)
alter table auction_state add column if not exists lot_bidders bigint[] not null default '{}';
alter table auction_state add column if not exists last_lot_name text;
alter table auction_state add column if not exists last_lot_bidders bigint[] not null default '{}';

create table if not exists auction_history (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  item_id text,
  name text not null,
  reveal_name text,
  start_price int not null,
  price int not null,
  team_name text,
  sold boolean not null
);
alter table auction_history add column if not exists reveal_name text;

create table if not exists trading_listings (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  team_id bigint not null references teams(id) on delete cascade,
  item_id text not null references shop_components(id) on delete cascade,
  initial_qty int not null check (initial_qty > 0),
  qty int not null check (qty >= 0),
  price int not null check (price >= 0),
  status text not null default 'active' check (status in ('active', 'sold_out', 'cancelled'))
);
create index if not exists trading_listings_team_idx on trading_listings (team_id, id desc);

create table if not exists trading_history (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  seller_id bigint not null references teams(id) on delete cascade,
  buyer_id bigint not null references teams(id) on delete cascade,
  item_id text not null references shop_components(id) on delete cascade,
  qty int not null,
  price int not null,
  total int not null
);

-- Trading can reference either catalog. Remove only the legacy, single-column
-- shop foreign keys; item validity is enforced by the trading functions below.
do $$
declare fk record;
begin
  for fk in
    select c.conrelid::regclass as table_name, c.conname
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.contype = 'f'
      and c.conrelid in ('public.trading_listings'::regclass, 'public.trading_history'::regclass)
      and array_length(c.conkey, 1) = 1
      and a.attname = 'item_id'
  loop
    execute format('alter table %s drop constraint %I', fk.table_name, fk.conname);
  end loop;
end $$;

create table if not exists public_state (
  id int primary key default 1 check (id = 1),
  v bigint not null default 0,
  data jsonb not null default '{}'
);

-- ---------------------------------------------------------------- access control
alter table settings enable row level security;
alter table teams enable row level security;
alter table shop_components enable row level security;
alter table auction_items enable row level security;
alter table inventory enable row level security;
alter table orders enable row level security;
alter table auction_state enable row level security;
alter table auction_history enable row level security;
alter table public_state enable row level security;
alter table trading_listings enable row level security;
alter table trading_history enable row level security;

revoke all on settings, teams, shop_components, auction_items, inventory, orders,
  auction_state, auction_history, public_state, trading_listings, trading_history from anon, authenticated;
grant select on public_state to anon, authenticated;

drop policy if exists "public snapshot is readable" on public_state;
create policy "public snapshot is readable" on public_state for select to anon, authenticated using (true);

do $$ begin
  alter publication supabase_realtime add table public_state;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------- helpers
create or replace function _ms(ts timestamptz) returns bigint
language sql immutable set search_path = public as $$
  select (extract(epoch from ts) * 1000)::bigint
$$;

-- callable by browsers, so it must not depend on any locked-down helper
create or replace function server_now() returns bigint
language sql volatile set search_path = public as $$
  select (extract(epoch from clock_timestamp()) * 1000)::bigint
$$;

-- lenient number parse for admin form values ('' / junk / NaN / huge -> null)
create or replace function _num(j jsonb) returns numeric
language plpgsql immutable set search_path = public as $$
declare v numeric;
begin
  if j is null or jsonb_typeof(j) not in ('number', 'string') then return null; end if;
  v := (j #>> '{}')::numeric;
  if v::text in ('NaN', 'Infinity', '-Infinity') or abs(v) > 1000000000 then return null; end if;
  return v;
exception when others then return null;
end $$;

create or replace function _trade_item_exists(p_item_id text) returns boolean
language sql stable set search_path = public as $$
  select exists(select 1 from shop_components where id = p_item_id)
      or exists(select 1 from auction_items where id = p_item_id)
$$;

create or replace function _trade_item_name(p_item_id text) returns text
language sql stable set search_path = public as $$
  select coalesce(
    (select name from shop_components where id = p_item_id),
    (select name from auction_items where id = p_item_id)
  )
$$;

create or replace function _trade_item_source(p_item_id text) returns text
language sql stable set search_path = public as $$
  select case
    when exists(select 1 from shop_components where id = p_item_id) then 'shop'
    when exists(select 1 from auction_items where id = p_item_id) then 'auction'
    else null
  end
$$;

create or replace function game_phase() returns text
language sql stable set search_path = public as $$
  select case
    when started_at is null then 'idle'
    when now() - started_at < make_interval(secs => (base_min * 60)::float8) then 'base'
    else 'double' end
  from settings where id = 1
$$;

-- rebuild the snapshot every screen subscribes to (Realtime)
create or replace function refresh_public_state() returns void
language plpgsql set search_path = public as $$
declare s settings; a auction_state; d jsonb;
begin
  select * into s from settings where id = 1;
  select * into a from auction_state where id = 1;
  d := jsonb_build_object(
    'startedAt', _ms(s.started_at),
    'baseMs', (s.base_min * 60000)::bigint,
    'mult', s.mult,
    'components', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'base', price, 'soldOut', qty <= 0) order by sort) from shop_components), '[]'),
    'auctionItems', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id,
        'name', name,
        'reveal', case when exists (
          select 1 from auction_history h where h.item_id = auction_items.id and h.sold
        ) then reveal_name end
      ) order by sort) from auction_items), '[]'),
    'tradingListings', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'teamId', l.team_id, 'teamName', t.username,
        'itemId', l.item_id, 'qty', l.qty, 'price', l.price, 'createdAt', _ms(l.created_at)) order by l.id)
      from trading_listings l join teams t on t.id = l.team_id where l.status = 'active'), '[]'),
    'auction', jsonb_build_object(
      'status', a.status,
      'left', cardinality(a.queue),
      'lot', case when a.lot_item_id is null then null else jsonb_build_object(
        'name', a.lot_name, 'start', a.lot_start, 'bid', a.lot_bid, 'leader', a.lot_leader_name,
        'time', a.lot_time, 'endsAt', _ms(a.lot_ends_at), 'remainingMs', a.lot_remaining_ms, 'bids', a.lot_bids,
        'inc', coalesce((select inc from auction_items where id = a.lot_item_id), 0)) end,
      'recent', coalesce((select jsonb_agg(jsonb_build_object('name', h.name, 'reveal', h.reveal_name,
                          'price', h.price, 'team', h.team_name, 'sold', h.sold) order by h.id desc)
                          from (select * from auction_history order by id desc limit 6) h), '[]'),
      'lastLot', case when a.last_lot_name is null then null else jsonb_build_object('name', a.last_lot_name,
        'teams', coalesce((select jsonb_agg(jsonb_build_object('team', t.username, 'credits', t.credits) order by t.credits desc)
                           from teams t where t.id = any(a.last_lot_bidders)), '[]')) end,
      'sold', (select count(*) from auction_history where sold),
      'done', (select count(*) from auction_history)));
  update public_state set v = v + 1, data = d || jsonb_build_object('v', v + 1) where id = 1;
end $$;

create or replace function _clear_lot(p_status text) returns void
language sql set search_path = public as $$
  update auction_state set status = p_status, lot_item_id = null, lot_name = null, lot_start = null, lot_time = null,
    lot_bid = 0, lot_leader_id = null, lot_leader_name = null, lot_ends_at = null, lot_remaining_ms = null, lot_bids = '[]',
    lot_bidders = '{}'
  where id = 1
$$;

-- remember who bid on the lot that is closing, before the next one replaces it
create or replace function _archive_lot() returns void
language sql set search_path = public as $$
  update auction_state set last_lot_name = lot_name, last_lot_bidders = lot_bidders
  where id = 1 and lot_item_id is not null
$$;

-- give the current highest bid back to its team
create or replace function _refund_leader() returns void
language sql set search_path = public as $$
  update teams t set credits = t.credits + a.lot_bid
  from auction_state a where a.id = 1 and a.lot_leader_id is not null and t.id = a.lot_leader_id
$$;

-- put the next queued item on the block; its next starting price rises by its increment
create or replace function _auc_next() returns void
language plpgsql set search_path = public as $$
declare a auction_state; it auction_items;
begin
  loop
    select * into a from auction_state where id = 1;
    if cardinality(a.queue) = 0 then perform _clear_lot('done'); return; end if;
    update auction_state set queue = queue[2:] where id = 1;
    select * into it from auction_items where id = a.queue[1];
    if found then
      update auction_state set status = 'live', lot_item_id = it.id, lot_name = it.name, lot_start = it.next_price,
        lot_time = it.time_sec, lot_bid = 0, lot_leader_id = null, lot_leader_name = null,
        lot_ends_at = case when it.time_sec > 0 then now() + make_interval(secs => it.time_sec) end,
        lot_remaining_ms = null, lot_bids = '[]', lot_bidders = '{}'
      where id = 1;
      update auction_items set next_price = next_price + inc where id = it.id;
      return;
    end if;
  end loop;
end $$;

create or replace function _bid(p_team bigint, p_amount numeric) returns void
language plpgsql set search_path = public as $$
declare a auction_state; t teams; amt int; v_inc int; min_next int;
begin
  select * into a from auction_state where id = 1;
  if a.status <> 'live' or a.lot_item_id is null then raise exception 'No live lot'; end if;
  if a.lot_ends_at is not null and now() > a.lot_ends_at then raise exception 'Time is up for this lot'; end if;
  select * into t from teams where id = p_team;
  if not found then raise exception 'Pick a team'; end if;
  if p_amount is null then raise exception 'Enter a bid amount'; end if;
  amt := floor(p_amount);
  select inc into v_inc from auction_items where id = a.lot_item_id;
  v_inc := coalesce(v_inc, 0);
  min_next := case when a.lot_leader_id is not null then a.lot_bid + v_inc else a.lot_start end;
  if amt < min_next then raise exception 'Bid must be at least %', min_next; end if;
  -- a leader raising its own bid gets its held bid counted back first
  if (t.credits + (case when a.lot_leader_id = t.id then a.lot_bid else 0 end)) < amt then
    raise exception 'Team does not have enough credits';
  end if;
  perform _refund_leader();
  update teams set credits = credits - amt where id = t.id;
  update auction_state set lot_bid = amt, lot_leader_id = t.id, lot_leader_name = t.username,
    lot_bidders = case when t.id = any(lot_bidders) then lot_bidders else lot_bidders || t.id end,
    lot_bids =(select coalesce(jsonb_agg(x order by (x->>'bid')::int desc), '[]') from (
      select x from (
        select e.value as x from jsonb_array_elements(a.lot_bids) e where e.value->>'team' <> t.username
        union all select jsonb_build_object('team', t.username, 'bid', amt)
      ) u order by (x->>'bid')::int desc limit 3) top)
  where id = 1;
end $$;

create or replace function _buy(p_team bigint, p_id text, p_qty numeric) returns void
language plpgsql set search_path = public as $$
declare
  ph text := game_phase();
  c shop_components;
  t teams;
  q int;
  cost int;
  m numeric;
  v_cap int;
  v_owned int := 0;
  v_limit_name text;
begin
  if ph = 'idle' then raise exception 'The shop opens when the event starts'; end if;
  select * into c from shop_components where id = p_id;
  if not found or p_qty is null or p_qty < 1 or p_qty > 100000 then raise exception 'Invalid order'; end if;
  q := floor(p_qty);
  if c.qty < q then raise exception 'Not enough stock'; end if;
  if c.id in ('c3', 'c4', 'c5', 'c6') then
    v_cap := 10;
    v_limit_name := 'resistors (combined)';
    select coalesce(sum(qty), 0)::int into v_owned
    from inventory
    where team_id = p_team and item_id in ('c3', 'c4', 'c5', 'c6');
  else
    v_cap := case c.id
      when 'c1' then 2
      when 'c2' then 2
      when 'c7' then 10
      when 'c8' then 1
      when 'c9' then 2
      when 'c10' then 2
    end;
    v_limit_name := c.name;
    select coalesce(sum(qty), 0)::int into v_owned
    from inventory
    where team_id = p_team and item_id = c.id;
  end if;
  if v_cap is not null and v_owned + q > v_cap then
    raise exception 'Team cap exceeded for %: maximum % per team (% remaining)',
      v_limit_name, v_cap, greatest(0, v_cap - v_owned);
  end if;
  select mult into m from settings where id = 1;
  cost := round(case when ph = 'double' then c.price * m else c.price end) * q;
  select * into t from teams where id = p_team;
  if t.credits < cost then raise exception 'Not enough credits'; end if;
  update shop_components set qty = qty - q where id = c.id;
  update teams set credits = credits - cost where id = t.id;
  insert into inventory (team_id, item_id, qty) values (t.id, c.id, q)
    on conflict (team_id, item_id) do update set qty = inventory.qty + excluded.qty;
  insert into orders (team_id, team_name, item, qty, total, phase) values (t.id, t.username, c.name, q, cost, ph);
end $$;

create or replace function _reset_auction() returns void
language plpgsql set search_path = public as $$
begin
  perform _clear_lot('idle');
  update auction_state set queue = '{}', last_lot_name = null, last_lot_bidders = '{}' where id = 1;
  delete from auction_history where true;
  update auction_items set next_price = base where true;
end $$;

-- ---------------------------------------------------------------- trading (public listings; admin settles agreed transfers)
-- items stay in the seller's inventory until settled; active listings only reserve them
-- trading is closed until the auction has finished (all lots done, or the admin pressed "End auction")
create or replace function _trading_open() returns boolean
language sql stable set search_path = public as $$
  select coalesce((select status = 'done' from auction_state where id = 1), false)
$$;

create or replace function _trade_sell(p_team bigint, p_item_id text, p_qty numeric) returns void
language plpgsql set search_path = public as $$
declare owned int; committed int; q int;
begin
  if not _trading_open() then raise exception 'Trading opens after the auction ends'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 100000 or p_qty <> trunc(p_qty) then raise exception 'Invalid quantity'; end if;
  q := p_qty::int;
  if not _trade_item_exists(p_item_id) then raise exception 'Component not found'; end if;
  select coalesce(sum(qty), 0) into owned from inventory where team_id = p_team and item_id = p_item_id;
  select coalesce(sum(qty), 0) into committed from trading_listings where team_id = p_team and item_id = p_item_id and status = 'active';
  if q > owned - committed then raise exception 'Not enough available inventory to list'; end if;
  insert into trading_listings (team_id, item_id, initial_qty, qty, price) values (p_team, p_item_id, q, q, 0);
end $$;

create or replace function _trade_update(p_team bigint, p_listing_id numeric, p_qty numeric) returns void
language plpgsql set search_path = public as $$
declare l trading_listings; owned int; committed int; q int;
begin
  if not _trading_open() then raise exception 'Trading opens after the auction ends'; end if;
  if p_listing_id is null or p_listing_id < 1 or p_listing_id <> trunc(p_listing_id) then raise exception 'Listing not found'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 100000 or p_qty <> trunc(p_qty) then raise exception 'Invalid quantity'; end if;
  q := p_qty::int;
  select * into l from trading_listings where id = p_listing_id and team_id = p_team;
  if not found then raise exception 'Listing not found'; end if;
  if l.status <> 'active' then raise exception 'Listing is not active'; end if;
  select coalesce(sum(qty), 0) into owned from inventory where team_id = p_team and item_id = l.item_id;
  select coalesce(sum(qty), 0) into committed from trading_listings
    where team_id = p_team and item_id = l.item_id and status = 'active' and id <> l.id;
  if q > owned - committed then raise exception 'Not enough available inventory to list'; end if;
  update trading_listings set qty = q where id = l.id;
end $$;

create or replace function _trade_cancel(p_team bigint, p_listing_id numeric) returns void
language plpgsql set search_path = public as $$
declare l trading_listings;
begin
  if not _trading_open() then raise exception 'Trading opens after the auction ends'; end if;
  select * into l from trading_listings where id = p_listing_id and team_id = p_team;
  if not found then raise exception 'Listing not found'; end if;
  if l.status <> 'active' then raise exception 'Listing is not active'; end if;
  update trading_listings set status = 'cancelled' where id = l.id;
end $$;

drop function if exists _trade_buy(bigint, numeric, numeric);

-- ---------------------------------------------------------------- API entry points
create or replace function game_login(p_u text, p_p text) returns jsonb
language sql stable set search_path = public, extensions as $$
  select jsonb_build_object('id', id, 'u', username, 'ver', token_ver)
  from teams where username = trim(p_u) and password_hash = extensions.crypt(p_p, password_hash)
$$;

create or replace function game_me(p_team bigint) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', t.id,
    'u', t.username,
    'credits', t.credits,
    'inv', coalesce((select jsonb_object_agg(item_id, qty) from inventory where team_id = t.id and qty > 0), '{}'),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('item', item, 'qty', qty, 'total', total, 't', _ms(created_at)) order by id desc)
                        from orders where team_id = t.id), '[]'),
    'listings', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'itemId', l.item_id, 'initialQty', l.initial_qty, 'qty', l.qty,
                            'price', l.price, 'status', l.status, 't', _ms(l.created_at)) order by l.id desc)
                          from trading_listings l where l.team_id = t.id), '[]'),
    'trades', coalesce((select jsonb_agg(jsonb_build_object('id', th.id, 'isSeller', th.seller_id = t.id,
                          'otherTeam', case when th.seller_id = t.id then b.username else s.username end,
                          'itemId', th.item_id, 'qty', th.qty, 'price', th.price, 'total', th.total, 't', _ms(th.created_at)) order by th.id desc)
                        from trading_history th
                        join teams s on s.id = th.seller_id
                        join teams b on b.id = th.buyer_id
                        where th.seller_id = t.id or th.buyer_id = t.id), '[]'),
    'tradeCommitted', coalesce((select jsonb_object_agg(c.item_id, c.n) from (
                        select l.item_id, sum(l.qty) as n from trading_listings l
                        where l.team_id = t.id and l.status = 'active' group by l.item_id) c), '{}'))
  from teams t where t.id = p_team
$$;

create or replace function game_team(p_team bigint, p_ver int, p_action text, p_body jsonb) returns jsonb
language plpgsql set search_path = public as $$
begin
  if p_action <> 'me' then perform pg_advisory_xact_lock(4242); end if;
  if not exists (select 1 from teams where id = p_team and token_ver = p_ver) then
    raise exception 'Please log in again' using errcode = 'ZG401';
  end if;
  if p_action = 'me' then return game_me(p_team);
  elsif p_action = 'buy' then perform _buy(p_team, p_body->>'id', _num(p_body->'qty'));
  elsif p_action = 'bid' then perform _bid(p_team, _num(p_body->'amount'));
  elsif p_action = 'trade_sell' then perform _trade_sell(p_team, p_body->>'itemId', _num(p_body->'qty'));
  elsif p_action = 'trade_update' then perform _trade_update(p_team, _num(p_body->'listingId'), _num(p_body->'qty'));
  elsif p_action = 'trade_cancel' then perform _trade_cancel(p_team, _num(p_body->'listingId'));
  else raise exception 'Not found';
  end if;
  perform refresh_public_state();
  return game_me(p_team);
end $$;

create or replace function admin_state() returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'mult', s.mult,
    'defaultCredits', s.default_credits,
    'timer', jsonb_build_object('startedAt', _ms(s.started_at), 'baseMin', s.base_min),
    'phase', game_phase(),
    'now', _ms(clock_timestamp()),
    'components', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'qty', qty, 'price', price) order by sort) from shop_components), '[]'),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('u', t.username, 'credits', t.credits,
        'inv', coalesce((select jsonb_object_agg(i.item_id, i.qty) from inventory i where i.team_id = t.id and i.qty > 0), '{}')) order by t.id)
      from teams t), '[]'),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('t', _ms(o.created_at), 'team', o.team_name, 'item', o.item, 'qty', o.qty, 'total', o.total, 'phase', o.phase) order by o.id desc)
      from (select * from orders order by id desc limit 2000) o), '[]'),
    'auction', jsonb_build_object(
      'status', a.status,
      'queue', to_jsonb(a.queue),
      'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'reveal', reveal_name,
          'time', time_sec, 'qty', qty, 'base', base, 'inc', inc, 'next', next_price) order by sort) from auction_items), '[]'),
      'history', coalesce((select jsonb_agg(jsonb_build_object('t', _ms(created_at), 'itemId', item_id,
          'name', name, 'reveal', reveal_name, 'start', start_price, 'price', price, 'team', team_name, 'sold', sold) order by id desc) from auction_history), '[]')))
  from settings s, auction_state a where s.id = 1 and a.id = 1
$$;

create or replace function game_admin(p_action text, p_body jsonb) returns jsonb
language plpgsql set search_path = public, extensions as $$
declare
  b jsonb := coalesce(p_body, '{}');
  a auction_state; t teams; x jsonb; n numeric; sold boolean; v_u text; v_p text; v_reveal text;
begin
  if p_action = 'state' then return admin_state(); end if;
  perform pg_advisory_xact_lock(4242);
  select * into a from auction_state where id = 1;

  if p_action = 'components' then
    for x in select value from jsonb_array_elements(coalesce(b->'list', '[]')) loop
      update shop_components set
        name = coalesce(nullif(trim(x->>'name'), ''), name),
        qty = greatest(0, coalesce(floor(_num(x->'qty')), 0)),
        price = greatest(0, coalesce(round(_num(x->'price')), 0))
      where id = x->>'id';
    end loop;

  elsif p_action = 'timer' then
    n := _num(b->'baseMin');
    if n > 0 then update settings set base_min = n where id = 1; end if;
    if b->>'action' = 'start' then update settings set started_at = now() where id = 1;
    elsif b->>'action' = 'reset' then update settings set started_at = null where id = 1; end if;

  elsif p_action = 'settings' then
    n := _num(b->'mult');
    if n > 0 then update settings set mult = n where id = 1; end if;
    n := _num(b->'defaultCredits');
    if n >= 0 then update settings set default_credits = floor(n) where id = 1; end if;

  elsif p_action = 'auction-items' then
    for x in select value from jsonb_array_elements(coalesce(b->'list', '[]')) loop
      update auction_items set
        name = coalesce(nullif(trim(x->>'name'), ''), name),
        time_sec = greatest(0, coalesce(floor(_num(x->'time')), 0)),
        qty = greatest(0, coalesce(floor(_num(x->'qty')), 0)),
        base = greatest(0, coalesce(round(_num(x->'base')), 0)),
        inc = greatest(0, coalesce(round(_num(x->'inc')), 0))
      where id = x->>'id';
    end loop;
    if a.status = 'idle' then update auction_items set next_price = base where true; end if;

  elsif p_action = 'auction-generate' then
    if a.status <> 'idle' then raise exception 'Reset the auction before generating a new list'; end if;
    update auction_items set next_price = base where true;
    update auction_state set queue =
      (case when exists (select 1 from auction_items where id = 'a18' and qty > 0)
        then array['a18']::text[] else '{}'::text[] end)
      || coalesce((select array_agg(i.id order by random())
          from auction_items i, generate_series(1, i.qty)
          where i.id <> 'a18'), '{}')
      where id = 1;
    if (select cardinality(queue) from auction_state where id = 1) = 0 then
      raise exception 'No component has a quantity above 0';
    end if;

  elsif p_action = 'auction-queue' then
    if jsonb_typeof(b->'queue') <> 'array' or exists (
      select 1 from jsonb_array_elements_text(b->'queue') q where q not in (select id from auction_items)) then
      raise exception 'Invalid list';
    end if;
    update auction_state set queue = array(select jsonb_array_elements_text(b->'queue')) where id = 1;

  elsif p_action = 'auction-start' then
    if a.status <> 'idle' then raise exception 'Auction already started'; end if;
    if cardinality(a.queue) = 0 then raise exception 'Generate a list first'; end if;
    perform _auc_next();

  elsif p_action = 'auction-pause' then
    if a.status <> 'live' or a.lot_item_id is null then raise exception 'Nothing to pause'; end if;
    update auction_state set status = 'paused',
      lot_remaining_ms = case when lot_ends_at is not null then greatest(0, _ms(lot_ends_at) - _ms(now())) else lot_remaining_ms end,
      lot_ends_at = null
    where id = 1;

  elsif p_action = 'auction-resume' then
    if a.status <> 'paused' or a.lot_item_id is null then raise exception 'Not paused'; end if;
    update auction_state set status = 'live',
      lot_ends_at = case when lot_remaining_ms is not null then now() + make_interval(secs => lot_remaining_ms / 1000.0) else lot_ends_at end,
      lot_remaining_ms = null
    where id = 1;

  elsif p_action = 'auction-extend' then
    if a.lot_item_id is null or coalesce(a.lot_time, 0) = 0 then raise exception 'This lot has no time limit'; end if;
    n := greatest(0, coalesce(nullif(_num(b->'sec'), 0), 10));
    if a.lot_ends_at is not null then
      update auction_state set lot_ends_at = greatest(lot_ends_at, now()) + make_interval(secs => n::float8) where id = 1;
    elsif a.lot_remaining_ms is not null then
      update auction_state set lot_remaining_ms = lot_remaining_ms + (n * 1000)::int where id = 1;
    end if;

  elsif p_action = 'auction-bid' then
    select * into t from teams where username = b->>'team';
    perform _bid(t.id, _num(b->'amount'));

  elsif p_action = 'auction-resolve' then
    if a.lot_item_id is null or a.status not in ('live', 'paused') then raise exception 'No lot to close'; end if;
    sold := coalesce((b->>'sold')::boolean, false);
    select reveal_name into v_reveal from auction_items where id = a.lot_item_id;
    if sold then
      if a.lot_leader_id is null or not exists (select 1 from teams where id = a.lot_leader_id) then
        raise exception 'Nobody has bid on this lot';
      end if;
      insert into inventory (team_id, item_id, qty) values (a.lot_leader_id, a.lot_item_id, 1)
        on conflict (team_id, item_id) do update set qty = inventory.qty + 1;
      insert into orders (team_id, team_name, item, qty, total, phase)
        values (a.lot_leader_id, a.lot_leader_name,
                case when v_reveal is null then a.lot_name else a.lot_name || ' — ' || v_reveal end,
                1, a.lot_bid, 'auction');
    else
      perform _refund_leader();
    end if;
    insert into auction_history (item_id, name, reveal_name, start_price, price, team_name, sold)
      values (a.lot_item_id, a.lot_name, case when sold then v_reveal end,
              a.lot_start, case when sold then a.lot_bid else 0 end,
              case when sold then a.lot_leader_name end, sold);
    perform _archive_lot();
    perform _auc_next();

  elsif p_action = 'auction-reset' then
    perform _refund_leader();
    perform _reset_auction();

  -- stop the auction early (opens trading): the lot on the block goes unsold and its top bid is refunded
  elsif p_action = 'auction-end' then
    if a.status = 'done' then raise exception 'The auction has already ended'; end if;
    if a.lot_item_id is not null then
      perform _refund_leader();
      insert into auction_history (item_id, name, start_price, price, team_name, sold)
        values (a.lot_item_id, a.lot_name, a.lot_start, 0, null, false);
      perform _archive_lot();
    end if;
    perform _clear_lot('done');
    update auction_state set queue = '{}' where id = 1;

  elsif p_action = 'team-add' then
    v_u := trim(coalesce(b->>'u', ''));
    v_p := coalesce(b->>'p', '');
    if v_u = '' or v_p = '' then raise exception 'Name and password required'; end if;
    if length(v_u) > 40 then raise exception 'Team name is too long'; end if;
    if exists (select 1 from teams where username = v_u) then raise exception 'Team exists'; end if;
    n := _num(b->'credits');
    insert into teams (username, password_hash, credits)
      values (v_u, extensions.crypt(v_p, extensions.gen_salt('bf')),
              coalesce(floor(n), (select default_credits from settings where id = 1)));

  elsif p_action = 'team-edit' then
    select * into t from teams where username = b->>'u';
    if found then
      if coalesce(b->>'p', '') <> '' then
        update teams set password_hash = extensions.crypt(b->>'p', extensions.gen_salt('bf')), token_ver = token_ver + 1 where id = t.id;
      end if;
      n := _num(b->'credits');
      if n is not null then update teams set credits = floor(n) where id = t.id; end if;
    end if;

  elsif p_action = 'team-del' then
    select * into t from teams where username = b->>'u';
    if found then
      if a.lot_leader_id = t.id then
        update auction_state set lot_bid = 0, lot_leader_id = null, lot_leader_name = null where id = 1;
      end if;
      update auction_state set lot_bids = coalesce((select jsonb_agg(e.value) from jsonb_array_elements(lot_bids) e
        where e.value->>'team' <> t.username), '[]') where id = 1;
      delete from teams where id = t.id;
    end if;

  elsif p_action = 'reset-orders' then
    delete from orders where true;

  elsif p_action = 'reset-shop' then
    -- undo team-to-team trades, refund shop purchases, take the components back and restock; auction items stay
    update teams tm set credits = tm.credits
      + coalesce((select sum(h.total) from trading_history h where h.buyer_id = tm.id), 0)
      - coalesce((select sum(h.total) from trading_history h where h.seller_id = tm.id), 0)
      + coalesce((select sum(o.total) from orders o where o.team_id = tm.id and o.phase <> 'auction'), 0)
    where true;
    delete from orders where phase <> 'auction';
    delete from inventory where item_id in (select id from shop_components);
    delete from trading_listings where true;
    delete from trading_history where true;
    update shop_components set qty = default_qty where true;

  elsif p_action = 'reset-all' then
    delete from orders where true;
    delete from trading_listings where true;
    delete from trading_history where true;
    delete from inventory where true;
    perform _reset_auction();
    update settings set started_at = null where id = 1;
    update teams set credits = (select default_credits from settings where id = 1) where true;
    update shop_components set qty = default_qty where true;

  else
    raise exception 'Not found';
  end if;

  perform refresh_public_state();
  return '{"ok":1}'::jsonb;
end $$;

-- only the service role (Vercel API) may call game functions; browsers get server_now() only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname in ('_ms', 'server_now', '_num', 'game_phase', 'refresh_public_state',
      '_clear_lot', '_archive_lot', '_refund_leader', '_auc_next', '_bid', '_buy', '_reset_auction', '_trade_item_exists', '_trade_item_name', '_trade_item_source', '_trading_open', '_trade_sell', '_trade_update', '_trade_cancel', 'game_login', 'game_me',
      'game_team', 'admin_state', 'game_admin')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant execute on function server_now() to anon, authenticated;

-- ---------------------------------------------------------------- seed data
insert into settings (id) values (1) on conflict do nothing;
insert into auction_state (id) values (1) on conflict do nothing;
insert into public_state (id) values (1) on conflict do nothing;

insert into shop_components (id, sort, name, qty, price, default_qty) values
  ('c1', 1, 'Bread board', 20, 200, 20),
  ('c2', 2, 'Jumper wires 8x each', 24, 30, 24),
  ('c3', 3, '10k resistor', 100, 10, 100),
  ('c4', 4, '1k resistor', 100, 10, 100),
  ('c5', 5, '3k3 resistor', 100, 10, 100),
  ('c6', 6, '220 resistor', 100, 10, 100),
  ('c7', 7, 'LED', 300, 10, 300),
  ('c8', 8, 'Power supply', 10, 1000, 10),
  ('c9', 9, 'Pushbutton', 16, 20, 16),
  ('c10', 10, 'Switch', 10, 20, 10)
on conflict do nothing;

-- Keep the corrected label when this idempotent schema is re-run on an existing event database.
update shop_components set name = 'Jumper wires 8x each' where id = 'c2';

insert into auction_items (id, sort, name, time_sec, qty, base, inc, next_price) values
  ('a1', 1, 'Arduino Nano & Cable', 80, 10, 1000, 50, 1000),
  ('a2', 2, 'ESP & Cable', 100, 10, 2000, 100, 2000),
  ('a3', 3, 'Voltage Sensor', 45, 3, 100, 10, 100),
  ('a4', 4, 'Current Sensor', 45, 3, 100, 10, 100),
  ('a5', 5, 'LDR', 40, 40, 100, 10, 100),
  ('a6', 6, 'PIR', 50, 5, 200, 10, 200),
  ('a7', 7, 'Ultrasonic', 50, 40, 200, 10, 200),
  ('a8', 8, 'Buzzer', 30, 40, 50, 5, 50),
  ('a9', 9, 'IR Sensor', 40, 10, 100, 10, 100),
  ('a10', 10, 'SG90 Servo', 80, 6, 1000, 50, 1000),
  ('a11', 11, 'MG90 Servo', 150, 4, 1500, 50, 1500),
  ('a12', 12, 'DHT', 40, 5, 100, 10, 100),
  ('a14', 14, 'Potentiometer (10k)', 20, 10, 20, 5, 20),
  ('a15', 15, 'Potentiometer (1M)', 20, 10, 20, 5, 20),
  ('a16', 16, 'Chassis Kit', 240, 2, 7000, 100, 7000),
  ('a17', 17, 'LCD', 90, 1, 3000, 100, 3000)
on conflict do nothing;

-- Mystery contents are service-role/admin data until the corresponding lot is sold.
insert into auction_items (id, sort, name, reveal_name, time_sec, qty, base, inc, next_price) values
  ('a18', 18, 'Mystery Box 1', 'Chassis Kit', 90, 1, 3000, 100, 3000),
  ('a19', 19, 'Mystery Box 2', '₹5,000 game credits (added manually)', 90, 1, 3000, 100, 3000),
  ('a20', 20, 'Mystery Box 3', '15 LEDs, 2 resistors, jumper wires', 90, 1, 3000, 100, 3000),
  ('a21', 21, 'Mystery Box 4', '3 resistors, 1 battery snapper, 4 batteries, 1 SG90 servo, ultrasonic sensor, DHT sensor, 2 potentiometers (1k and 1M), 2 buzzers, 1 voltage sensor, 2 IR sensors, 2 switches', 90, 1, 3000, 100, 3000)
on conflict (id) do update set
  sort = excluded.sort,
  name = excluded.name,
  reveal_name = excluded.reveal_name;

-- Retire the standalone auction LED while keeping the separate shop LED component.
update auction_state set queue = array_remove(queue, 'a13') where id = 1;
update auction_items set qty = 0 where id = 'a13';

select refresh_public_state();
