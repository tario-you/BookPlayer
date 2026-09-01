create extension if not exists pgcrypto with schema extensions;

create table public.bookplayer_progress (
  library_hash text not null,
  item_key text not null,
  display_title text not null,
  duration_ms bigint not null check (duration_ms >= 0),
  position_ms bigint not null check (position_ms >= 0),
  is_finished boolean not null default false,
  event_at timestamptz not null,
  source_device_id uuid not null,
  server_updated_at timestamptz not null default now(),
  primary key (library_hash, item_key)
);

alter table public.bookplayer_progress enable row level security;
revoke all on table public.bookplayer_progress from anon, authenticated;

comment on table public.bookplayer_progress is
  'Private playback state. Clients can only access rows through secret-scoped RPCs.';

create or replace function public.bookplayer_push_progress(
  p_library_secret text,
  p_item_key text,
  p_display_title text,
  p_duration_ms bigint,
  p_position_ms bigint,
  p_is_finished boolean,
  p_event_at timestamptz,
  p_source_device_id uuid
)
returns table (
  item_key text,
  display_title text,
  duration_ms bigint,
  position_ms bigint,
  is_finished boolean,
  event_at timestamptz,
  source_device_id uuid,
  server_updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_library_hash text;
begin
  if length(p_library_secret) < 32 then
    raise exception 'invalid library secret';
  end if;
  if length(p_item_key) < 16 or length(p_item_key) > 128 then
    raise exception 'invalid item key';
  end if;
  if p_duration_ms < 0 or p_position_ms < 0 then
    raise exception 'invalid playback position';
  end if;

  v_library_hash := encode(
    extensions.digest(convert_to(p_library_secret, 'UTF8'), 'sha256'),
    'hex'
  );

  insert into public.bookplayer_progress as existing (
    library_hash,
    item_key,
    display_title,
    duration_ms,
    position_ms,
    is_finished,
    event_at,
    source_device_id,
    server_updated_at
  ) values (
    v_library_hash,
    p_item_key,
    left(p_display_title, 500),
    p_duration_ms,
    case
      when p_duration_ms > 0 then least(p_position_ms, p_duration_ms)
      else p_position_ms
    end,
    p_is_finished,
    p_event_at,
    p_source_device_id,
    now()
  )
  on conflict on constraint bookplayer_progress_pkey do update
  set
    display_title = excluded.display_title,
    duration_ms = excluded.duration_ms,
    position_ms = excluded.position_ms,
    is_finished = excluded.is_finished,
    event_at = excluded.event_at,
    source_device_id = excluded.source_device_id,
    server_updated_at = now()
  where
    excluded.event_at > existing.event_at
    or (
      excluded.event_at = existing.event_at
      and excluded.source_device_id::text > existing.source_device_id::text
    );

  return query
  select
    progress.item_key,
    progress.display_title,
    progress.duration_ms,
    progress.position_ms,
    progress.is_finished,
    progress.event_at,
    progress.source_device_id,
    progress.server_updated_at
  from public.bookplayer_progress as progress
  where progress.library_hash = v_library_hash
    and progress.item_key = p_item_key;
end;
$$;

create or replace function public.bookplayer_pull_progress(
  p_library_secret text
)
returns table (
  item_key text,
  display_title text,
  duration_ms bigint,
  position_ms bigint,
  is_finished boolean,
  event_at timestamptz,
  source_device_id uuid,
  server_updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_library_hash text;
begin
  if length(p_library_secret) < 32 then
    raise exception 'invalid library secret';
  end if;

  v_library_hash := encode(
    extensions.digest(convert_to(p_library_secret, 'UTF8'), 'sha256'),
    'hex'
  );

  return query
  select
    progress.item_key,
    progress.display_title,
    progress.duration_ms,
    progress.position_ms,
    progress.is_finished,
    progress.event_at,
    progress.source_device_id,
    progress.server_updated_at
  from public.bookplayer_progress as progress
  where progress.library_hash = v_library_hash
  order by progress.server_updated_at asc;
end;
$$;

revoke all on function public.bookplayer_push_progress(
  text, text, text, bigint, bigint, boolean, timestamptz, uuid
) from public;
revoke all on function public.bookplayer_pull_progress(text) from public;

grant execute on function public.bookplayer_push_progress(
  text, text, text, bigint, bigint, boolean, timestamptz, uuid
) to anon, authenticated;
grant execute on function public.bookplayer_pull_progress(text) to anon, authenticated;
