
-- BEGIN ORIGINAL 20261014005000_pipeline_next_steps.sql
-- Booked next steps on both boards (client: src/data/pipeline/booking.ts).
--
-- The free-text "next step" on a card ("MG1", "Open the door") becomes a
-- booking: the column the card moves into next (`next_column`, a column after
-- the card's current one on its owner's board, never "Not contacted yet" or
-- an outcome), a day (`next_step_date`) and an optional time
-- (`next_step_time`). The card also gets a free-text `note`.
--
--  * Existing text that names a column the card can still book (its label,
--    the team name of a milestone like "MG1", or a common name like "Info"
--    for First plan; legacy_next_column()) is booked, keeping its day. Any
--    other text moves to the note as it was, and its day goes (nothing is
--    booked). Then `next_step` is dropped.
--  * move_pipeline_card() / move_customer_card() take `p_next_column`,
--    `p_next_step_date`, `p_next_step_time` (a booking made with the move).
--    Without one the card keeps its booking unless it moves into the booked
--    column or past it on the owner's board (the outcomes count as past);
--    moving backwards keeps it. The booking before the move is kept on the
--    move (`booking_before`), so undoing the move (deleting it) restores it.
--  * Cancelling a booked step with a reason is recorded in
--    `pipeline_step_cancellations` (both boards, for stats such as no-show
--    rates). Same readers and writers as the card; you remove your own
--    within the hour (undo). Each one writes a "MG1 cancelled · No-show"
--    activity entry about the person, removed again with the record.
-- RLS on the cards is unchanged (the same people edit the booking and note).

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------

alter table public.pipeline_cards
  add column next_column text,
  add column next_step_time time,
  add column note text check (note is null or length(note) <= 500);
alter table public.customer_cards
  add column next_column text,
  add column next_step_time time,
  add column note text check (note is null or length(note) <= 500);
comment on column public.pipeline_cards.next_column is
  'The booked next step: a column on the owner''s board the card moves into next (a step that is gone shows as removed).';
comment on column public.customer_cards.next_column is
  'The booked next step: a column on the list owner''s board the card moves into next.';

-- The booking on the card before the move (restored by undo). Null on moves
-- recorded before bookings existed.
alter table public.pipeline_moves add column booking_before jsonb;
alter table public.customer_moves add column booking_before jsonb;

-- ---------------------------------------------------------------------------
-- A board's columns, in order (mirror of columnsFor in src/data/pipeline/rules.ts)
-- ---------------------------------------------------------------------------

create function public.board_columns(p_board text, p_owner text)
returns table (id text, band text, kind text, label text, ord integer)
language sql stable security definer set search_path = ''
as $$
  with chain as (
    select c.person_id, c.depth from public.sponsor_chain(p_owner) c
  ),
  bands (band, bord) as (
    select * from (values ('start', 0), ('contact', 1), ('first_meeting', 2),
                          ('first_plan', 3), ('first_sale', 3), ('registered', 4),
                          ('on_ditto', 4), ('out', 5)) b (band, bord)
  ),
  fixed (id, band, kind, label, sub) as (
    select * from (values
      ('not_contacted', 'start', 'fixed', 'Not contacted yet', 0),
      ('not_interested', 'out', 'fixed', 'Not interested', 0),
      ('do_not_contact', 'out', 'fixed', 'Do not contact', 1)) f (id, band, kind, label, sub)
  ),
  milestones (id, band, kind, label, sub) as (
    select m.id, m.id, 'milestone', m.label, 0 from (values
      ('recruiting', 'contact', 'Contact made'),
      ('recruiting', 'first_meeting', 'First meeting (MG1)'),
      ('recruiting', 'first_plan', 'First plan (Info 1)'),
      ('recruiting', 'registered', 'Registered'),
      ('customer', 'contact', 'Contact'),
      ('customer', 'first_meeting', 'First meeting'),
      ('customer', 'first_sale', 'First sale'),
      ('customer', 'on_ditto', 'On Ditto')) m (board, id, label)
    where m.board = p_board
  ),
  steps (id, band, label, depth, pos, created) as (
    select s.id, s.band, s.label, ch.depth, s.position, s.created_at
      from public.pipeline_steps s join chain ch on ch.person_id = s.owner_id
     where p_board = 'recruiting'
       and not exists (select 1 from public.pipeline_step_hides h
                        join chain c2 on c2.person_id = h.person_id where h.step_id = s.id)
    union all
    select s.id, s.band, s.label, ch.depth, s.position, s.created_at
      from public.customer_steps s join chain ch on ch.person_id = s.owner_id
     where p_board = 'customer'
       and not exists (select 1 from public.customer_step_hides h
                        join chain c2 on c2.person_id = h.person_id where h.step_id = s.id)
  ),
  cols (id, band, kind, label, sub, depth, pos, created) as (
    select f.id, f.band, f.kind, f.label, f.sub, 0, 0, null::timestamptz from fixed f
    union all
    select m.id, m.band, m.kind, m.label, 0, 0, 0, null from milestones m
    union all
    select s.id, s.band, 'step', s.label, 1, s.depth, s.pos, s.created from steps s
  )
  select c.id, c.band, c.kind, c.label,
         (row_number() over (order by b.bord, c.sub, c.depth, c.pos, c.created, c.id))::integer
    from cols c join bands b on b.band = c.band
$$;
comment on function public.board_columns(text, text) is
  'The columns of p_owner''s board (recruiting or customer) in board order: fixed columns, milestones, and the steps of their sponsor line minus hidden ones.';

-- Where a column sits on the owner's board (a step it doesn't show counts as
-- its band's milestone); null when unknown.
create function public.board_column_ord(p_board text, p_owner text, p_column text)
returns integer
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select c.ord from public.board_columns(p_board, p_owner) c where c.id = p_column),
    (select c.ord from public.board_columns(p_board, p_owner) c
      where c.id = (case p_board
                      when 'recruiting' then (select s.band from public.pipeline_steps s where s.id = p_column)
                      else (select s.band from public.customer_steps s where s.id = p_column)
                    end)))
$$;

-- The booking after a move to p_to (mirror of bookingAfterMove): cleared when
-- the card moves into the booked column or past it, kept otherwise (also
-- when the booked column is no longer on the board).
create function public.booking_kept(p_board text, p_owner text, p_booked text, p_to text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select case
    when p_booked is null or p_booked = p_to then false
    when (select c.ord from public.board_columns(p_board, p_owner) c where c.id = p_booked) is null then true
    else coalesce(public.board_column_ord(p_board, p_owner, p_to), 0)
         < (select c.ord from public.board_columns(p_board, p_owner) c where c.id = p_booked)
  end
$$;

-- ---------------------------------------------------------------------------
-- Old free text → a booked column (mirror of legacyNextColumn)
-- ---------------------------------------------------------------------------

create function public.normalize_step_text(p_text text) returns text
language sql immutable set search_path = ''
as $$
  select trim(regexp_replace(regexp_replace(lower(trim(coalesce(p_text, ''))), '\s+', ' ', 'g'),
                             '[.!?:;,]+$', ''))
$$;

create function public.legacy_next_column(p_board text, p_owner text, p_current text, p_text text)
returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_t text := public.normalize_step_text(p_text);
  v_cur integer;
  v_id text;
begin
  if v_t = '' then
    return null;
  end if;
  v_cur := coalesce(public.board_column_ord(p_board, p_owner, p_current), 0);

  -- A column's label, or a milestone's team name ("First meeting (MG1)" -> "mg1").
  select c.id into v_id
    from public.board_columns(p_board, p_owner) c
   where c.ord > v_cur and c.band not in ('start', 'out')
     and (public.normalize_step_text(c.label) = v_t
          or (c.kind = 'milestone'
              and public.normalize_step_text(substring(c.label from '\(([^)]+)\)\s*$')) = v_t))
   order by c.ord
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  -- Common names for milestones.
  v_id := case p_board
    when 'recruiting' then case
      when v_t in ('contact', 'contact made') then 'contact'
      when v_t in ('first meeting', 'mg1', 'mg 1', '1st meeting', 'meeting 1') then 'first_meeting'
      when v_t in ('first plan', 'info', 'info 1', 'info1', 'show the plan', 'show plan', 'plan') then 'first_plan'
      when v_t in ('registered', 'register', 'registration', 'sign up') then 'registered'
    end
    else case
      when v_t in ('contact') then 'contact'
      when v_t in ('first meeting', 'mg1', 'mg 1', '1st meeting') then 'first_meeting'
      when v_t in ('first sale', 'sale') then 'first_sale'
      when v_t in ('on ditto', 'ditto', 'offer ditto') then 'on_ditto'
    end
  end;
  if v_id is not null and exists (select 1 from public.board_columns(p_board, p_owner) c
                                   where c.id = v_id and c.ord > v_cur) then
    return v_id;
  end if;
  return null;
end $$;

-- Convert the existing cards.
update public.pipeline_cards c
   set next_column = public.legacy_next_column('recruiting', coalesce(p.sponsor_id, p.id),
                                               c.column_id, c.next_step)
  from public.people p
 where p.id = c.person_id and nullif(trim(c.next_step), '') is not null;
update public.pipeline_cards
   set note = left(trim(next_step), 500), next_step_date = null
 where next_column is null and nullif(trim(next_step), '') is not null;
update public.pipeline_cards set next_step_date = null where next_column is null;

update public.customer_cards c
   set next_column = public.legacy_next_column('customer', e.owner_id, c.column_id, c.next_step)
  from public.list_entries e
 where e.id = c.entry_id and nullif(trim(c.next_step), '') is not null;
update public.customer_cards
   set note = left(trim(next_step), 500), next_step_date = null
 where next_column is null and nullif(trim(next_step), '') is not null;
update public.customer_cards set next_step_date = null where next_column is null;

alter table public.pipeline_cards drop column next_step;
alter table public.customer_cards drop column next_step;

-- A day and time only belong to a booked column; a time needs a day.
alter table public.pipeline_cards add constraint pipeline_cards_booking_check check (
  (next_column is not null or (next_step_date is null and next_step_time is null))
  and (next_step_time is null or next_step_date is not null));
alter table public.customer_cards add constraint customer_cards_booking_check check (
  (next_column is not null or (next_step_date is null and next_step_time is null))
  and (next_step_time is null or next_step_date is not null));

-- ---------------------------------------------------------------------------
-- Moves keep or clear the booking; undo restores it
-- ---------------------------------------------------------------------------

drop function public.move_pipeline_card(text, text, text, text, date, text, boolean);

-- Move a prospect's card (or create it) and record the move. As in
-- 20261014002500_pipeline_fixed_columns.sql, plus the booking: `p_next_column`
-- (with a day and time) books the next step with the move; without it the
-- card keeps its booking unless it moves into the booked column or past it.
create function public.move_pipeline_card(
  p_person_id text,
  p_to text,
  p_move_id text default null,
  p_next_column text default null,
  p_next_step_date date default null,
  p_next_step_time time default null,
  p_source text default null,
  p_hot boolean default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_me text := public.current_person_id();
  v_ws text := public.current_workspace_id();
  v_p public.people;
  v_card public.pipeline_cards;
  v_had_card boolean;
  v_band text;
  v_owner text;
  v_next text;
  v_date date;
  v_time time;
  v_move public.pipeline_moves;
begin
  if v_me is null or public.is_candidate() then
    raise exception 'Candidates don''t have a pipeline yet' using errcode = '42501';
  end if;
  select * into v_p from public.people p where p.id = p_person_id for update;
  if not found or v_p.workspace_id is distinct from v_ws or not public.can_see_person(p_person_id) then
    raise exception 'Person not found' using errcode = 'P0002';
  end if;
  if v_p.biz_class <> 'prospect' then
    raise exception 'Only prospects move on the board' using errcode = '22023';
  end if;
  v_owner := coalesce(v_p.sponsor_id, v_me);

  v_band := case
    when p_to in ('contact', 'first_meeting', 'first_plan', 'registered') then p_to
    when p_to = 'not_contacted' then 'start'
    when p_to in ('not_interested', 'do_not_contact') then 'out'
  end;
  if v_band is null then
    select s.band into v_band from public.pipeline_steps s
     where s.id = p_to and s.workspace_id = v_ws
       and (s.owner_id in (select c.person_id from public.sponsor_chain(v_owner) c)
            or s.owner_id in (select public.my_chain_ids()));
  end if;
  if v_band is null then
    raise exception 'That column isn''t on this board' using errcode = '22023';
  end if;

  select * into v_card from public.pipeline_cards c where c.person_id = p_person_id for update;
  v_had_card := found;
  if v_had_card and v_card.dropped_at is not null then
    raise exception 'That card is off the board' using errcode = '22023';
  end if;
  if v_had_card and v_card.column_id = p_to then
    raise exception 'Already there' using errcode = '22023';
  end if;

  -- The booking after the move.
  if nullif(trim(p_next_column), '') is not null and p_next_column <> p_to then
    v_next := p_next_column;
    v_date := p_next_step_date;
    v_time := case when p_next_step_date is not null then p_next_step_time end;
  elsif v_had_card and public.booking_kept('recruiting', v_owner, v_card.next_column, p_to) then
    v_next := v_card.next_column;
    v_date := v_card.next_step_date;
    v_time := v_card.next_step_time;
  end if;

  insert into public.pipeline_moves (id, workspace_id, person_id, owner_id, from_column, to_column,
                                     milestone, moved_at, moved_by, booking_before)
  values (coalesce(nullif(trim(p_move_id), ''), gen_random_uuid()::text), v_ws, p_person_id,
          v_owner, case when v_had_card then v_card.column_id end, p_to,
          v_band, now(), v_me,
          jsonb_build_object('next_column', v_card.next_column,
                             'next_step_date', v_card.next_step_date,
                             'next_step_time', v_card.next_step_time))
  returning * into v_move;

  insert into public.pipeline_cards (person_id, workspace_id, column_id, entered_at, next_column,
                                     next_step_date, next_step_time, hot, source, dropped_at, updated_at)
  values (p_person_id, v_ws, p_to, v_move.moved_at, v_next, v_date, v_time,
          coalesce(p_hot, false), nullif(trim(p_source), ''), null, now())
  on conflict (person_id) do update
     set column_id = excluded.column_id,
         entered_at = excluded.entered_at,
         next_column = excluded.next_column,
         next_step_date = excluded.next_step_date,
         next_step_time = excluded.next_step_time,
         hot = coalesce(p_hot, public.pipeline_cards.hot),
         source = coalesce(nullif(trim(p_source), ''), public.pipeline_cards.source),
         updated_at = now()
  returning * into v_card;

  if p_to = 'registered' then
    update public.people
       set biz_class = 'apprentice',
           pipeline_stage = 'apprentice',
           business_start_date = public.workspace_today(v_ws),
           stage_history = stage_history || jsonb_build_array(jsonb_build_object(
             'stage', 'apprentice',
             'at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')))
     where id = p_person_id;
    insert into public.activity (workspace_id, actor_name, actor_id, entity_type, entity_id,
                                 related_person_id, kind, summary, meta)
    values (v_ws, coalesce((select p.name from public.people p where p.id = v_me), 'Someone'), v_me,
            'person', p_person_id, p_person_id, 'stage_changed', 'Pipeline → apprentice',
            jsonb_build_object('from', 'prospect', 'to', 'apprentice'));
  end if;

  return jsonb_build_object('move', to_jsonb(v_move), 'card', to_jsonb(v_card));
end $$;

drop function public.move_customer_card(text, text, text, text, text, date);

-- Move a list entry's card (or create it) and record the move. As in
-- 20261014002000_customer_new_contacts_into_contact.sql, plus the booking
-- (as move_pipeline_card()).
create function public.move_customer_card(
  p_entry_id text,
  p_to text,
  p_move_id text default null,
  p_customer_id text default null,
  p_next_column text default null,
  p_next_step_date date default null,
  p_next_step_time time default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_me text := public.current_person_id();
  v_ws text := public.current_workspace_id();
  v_e public.list_entries;
  v_card public.customer_cards;
  v_had_card boolean;
  v_band text;
  v_customer text;
  v_created text;
  v_ditto boolean := false;
  v_next text;
  v_date date;
  v_time time;
  v_move public.customer_moves;
begin
  if v_me is null or public.is_candidate() then
    raise exception 'Candidates don''t have a customer pipeline yet' using errcode = '42501';
  end if;
  select * into v_e from public.list_entries e where e.id = p_entry_id for update;
  if not found or not public.list_owner_visible(v_e.workspace_id, v_e.owner_id) then
    raise exception 'Name not found' using errcode = 'P0002';
  end if;

  v_band := case
    when p_to in ('contact', 'first_meeting', 'first_sale', 'on_ditto') then p_to
    when p_to = 'not_contacted' then 'start'
    when p_to in ('not_interested', 'do_not_contact') then 'out'
  end;
  if v_band is null then
    select s.band into v_band from public.customer_steps s
     where s.id = p_to and s.workspace_id = v_ws
       and (s.owner_id in (select c.person_id from public.sponsor_chain(v_e.owner_id) c)
            or s.owner_id in (select public.my_chain_ids()));
  end if;
  if v_band is null then
    raise exception 'That column isn''t on this board' using errcode = '22023';
  end if;

  select * into v_card from public.customer_cards c where c.entry_id = p_entry_id for update;
  v_had_card := found;
  if coalesce(v_card.column_id, 'not_contacted') = p_to then
    raise exception 'Already there' using errcode = '22023';
  end if;

  -- First sale: the name becomes a customer of the list's owner.
  v_customer := v_e.customer_id;
  if v_band in ('first_sale', 'on_ditto') and v_customer is null then
    v_created := coalesce(nullif(trim(p_customer_id), ''), gen_random_uuid()::text);
    insert into public.people (id, workspace_id, name, phone, email, biz_class, owner_id,
                               sponsor_id, joined_date, notes)
    values (v_created, v_ws, v_e.name, v_e.phone, v_e.email, 'customer', v_e.owner_id, null,
            public.workspace_today(v_ws),
            case when v_e.how_known is not null then 'From your list: ' || v_e.how_known end);
    update public.list_entries set customer_id = v_created where id = v_e.id;
    insert into public.activity (workspace_id, actor_name, actor_id, entity_type, entity_id,
                                 related_person_id, kind, summary)
    values (v_ws, coalesce((select p.name from public.people p where p.id = v_me), 'Someone'), v_me,
            'person', v_created, v_created, 'created', format('Added %s (Customer)', v_e.name));
    v_customer := v_created;
  end if;

  -- On Ditto: a subscription customer from today.
  if v_band = 'on_ditto' then
    update public.people p set ditto_since = public.workspace_today(v_ws)
     where p.id = v_customer and p.biz_class = 'customer' and p.ditto_since is null;
    v_ditto := found;
  end if;

  -- The booking after the move.
  if nullif(trim(p_next_column), '') is not null and p_next_column <> p_to then
    v_next := p_next_column;
    v_date := p_next_step_date;
    v_time := case when p_next_step_date is not null then p_next_step_time end;
  elsif v_had_card and public.booking_kept('customer', v_e.owner_id, v_card.next_column, p_to) then
    v_next := v_card.next_column;
    v_date := v_card.next_step_date;
    v_time := v_card.next_step_time;
  end if;

  insert into public.customer_moves (id, workspace_id, entry_id, owner_id, from_column, to_column,
                                     band, moved_at, moved_by, created_customer_id, set_ditto,
                                     booking_before)
  values (coalesce(nullif(trim(p_move_id), ''), gen_random_uuid()::text), v_ws, p_entry_id,
          v_e.owner_id, case when v_had_card then v_card.column_id end, p_to, v_band, now(), v_me,
          v_created, v_ditto,
          jsonb_build_object('next_column', v_card.next_column,
                             'next_step_date', v_card.next_step_date,
                             'next_step_time', v_card.next_step_time))
  returning * into v_move;

  insert into public.customer_cards (entry_id, workspace_id, column_id, entered_at, next_column,
                                     next_step_date, next_step_time, updated_at)
  values (p_entry_id, v_ws, p_to, v_move.moved_at, v_next, v_date, v_time, now())
  on conflict (entry_id) do update
     set column_id = excluded.column_id,
         entered_at = excluded.entered_at,
         next_column = excluded.next_column,
         next_step_date = excluded.next_step_date,
         next_step_time = excluded.next_step_time,
         updated_at = now()
  returning * into v_card;

  return jsonb_build_object('move', to_jsonb(v_move), 'card', to_jsonb(v_card));
end $$;

grant execute on function public.move_pipeline_card(text, text, text, text, date, time, text, boolean) to authenticated;
grant execute on function public.move_customer_card(text, text, text, text, text, date, time) to authenticated;
revoke execute on function public.move_pipeline_card(text, text, text, text, date, time, text, boolean) from public, anon;
revoke execute on function public.move_customer_card(text, text, text, text, text, date, time) from public, anon;

-- Undoing a move: as in 20261013000500_pipeline_undo_registration.sql, and the
-- booking the card had before the move comes back.
create or replace function public.pipeline_moves_after_delete() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_actor text := public.current_person_id();
begin
  if old.from_column is null then
    delete from public.pipeline_cards c
     where c.person_id = old.person_id and c.column_id = old.to_column;
  else
    update public.pipeline_cards c
       set column_id = old.from_column,
           entered_at = coalesce((select max(m.moved_at) from public.pipeline_moves m
                                  where m.person_id = old.person_id), c.entered_at),
           next_column = case when old.booking_before is null then c.next_column
                              else old.booking_before ->> 'next_column' end,
           next_step_date = case when old.booking_before is null then c.next_step_date
                                 else (old.booking_before ->> 'next_step_date')::date end,
           next_step_time = case when old.booking_before is null then c.next_step_time
                                 else (old.booking_before ->> 'next_step_time')::time end,
           updated_at = now()
     where c.person_id = old.person_id and c.column_id = old.to_column;
  end if;

  if old.to_column = 'registered' then
    update public.people p
       set biz_class = 'prospect',
           pipeline_stage = 'prospect',
           business_start_date = null,
           stage_history = coalesce(p.stage_history, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
             'stage', 'prospect',
             'at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')))
     where p.id = old.person_id and p.biz_class = 'apprentice';
    if found then
      insert into public.activity (workspace_id, actor_name, actor_id, entity_type, entity_id,
                                   related_person_id, kind, summary, meta)
      values (old.workspace_id,
              coalesce((select p.name from public.people p where p.id = v_actor), 'Someone'), v_actor,
              'person', old.person_id, old.person_id, 'stage_changed', 'Pipeline → prospect',
              jsonb_build_object('from', 'apprentice', 'to', 'prospect'));
    end if;
  end if;
  return old;
end $$;

-- As in 20261014000500_customer_pipeline.sql, and the booking comes back.
create or replace function public.customer_moves_after_delete() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.from_column is null then
    delete from public.customer_cards c
     where c.entry_id = old.entry_id and c.column_id = old.to_column;
  else
    update public.customer_cards c
       set column_id = old.from_column,
           entered_at = coalesce((select max(m.moved_at) from public.customer_moves m
                                  where m.entry_id = old.entry_id), c.entered_at),
           next_column = case when old.booking_before is null then c.next_column
                              else old.booking_before ->> 'next_column' end,
           next_step_date = case when old.booking_before is null then c.next_step_date
                                 else (old.booking_before ->> 'next_step_date')::date end,
           next_step_time = case when old.booking_before is null then c.next_step_time
                                 else (old.booking_before ->> 'next_step_time')::time end,
           updated_at = now()
     where c.entry_id = old.entry_id and c.column_id = old.to_column;
  end if;

  if old.created_customer_id is not null then
    delete from public.people p
     where p.id = old.created_customer_id and p.biz_class = 'customer';
  elsif old.set_ditto then
    update public.people p set ditto_since = null
     where p.biz_class = 'customer'
       and p.id = (select e.customer_id from public.list_entries e where e.id = old.entry_id);
  end if;
  return old;
end $$;

-- ---------------------------------------------------------------------------
-- Cancelled next steps
-- ---------------------------------------------------------------------------

create table public.pipeline_step_cancellations (
  id text primary key default gen_random_uuid()::text,
  workspace_id text not null default public.current_workspace_id()
    references public.workspaces (id) on delete cascade,
  board text not null check (board in ('recruiting', 'customer')),
  -- The prospect (recruiting) or list entry (customer board). Kept after the
  -- card goes (the stats still count it): no link.
  card_id text not null,
  -- Whose card it was (the prospect's sponsor, the list's owner).
  owner_id text references public.people (id) on delete set null,
  column_id text not null,
  booked_date date,
  booked_time time,
  reason text not null check (reason in ('they_cancelled', 'no_show', 'unreachable',
                                         'not_interested', 'other')),
  reason_text text check (reason_text is null or length(reason_text) <= 200),
  cancelled_at timestamptz not null default now(),
  cancelled_by text default public.current_person_id() references public.people (id) on delete set null,
  constraint pipeline_step_cancellations_other_check
    check (reason <> 'other' or length(trim(coalesce(reason_text, ''))) > 0)
);
create index pipeline_step_cancellations_owner_idx
  on public.pipeline_step_cancellations (owner_id, cancelled_at);
create index pipeline_step_cancellations_card_idx
  on public.pipeline_step_cancellations (board, card_id);
comment on table public.pipeline_step_cancellations is
  'Booked next steps that were cancelled, with the reason (stats such as no-show rates).';

-- The card's owner as the database has it.
create function public.step_card_owner(p_board text, p_card_id text) returns text
language sql stable security definer set search_path = ''
as $$
  select case p_board
    when 'recruiting' then (select coalesce(p.sponsor_id, p.id) from public.people p where p.id = p_card_id)
    else (select e.owner_id from public.list_entries e where e.id = p_card_id)
  end
$$;

-- May the caller see / edit this card? (The cards' own policies.)
create function public.step_card_visible(p_board text, p_card_id text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select not public.is_candidate()
     and case p_board
           when 'recruiting' then p_card_id in (select public.visible_person_ids())
           else public.list_entry_visible(p_card_id)
         end
$$;

-- The activity entry about the person ("MG1 cancelled · No-show"), with the
-- id the app shows (stepcancel-<id>); removed with the record.
create function public.pipeline_step_cancellations_after_insert() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_person text;
  v_label text;
  v_why text;
begin
  v_person := case new.board
    when 'recruiting' then new.card_id
    else (select coalesce(e.customer_id, e.prospect_id) from public.list_entries e where e.id = new.card_id)
  end;
  if v_person is null then
    return new;
  end if;
  -- The short name the app shows (bookingLabel): "First meeting (MG1)" -> "MG1".
  select coalesce(case when c.kind = 'milestone' then substring(c.label from '\(([^)]+)\)\s*$') end,
                  c.label) into v_label
    from public.board_columns(new.board, coalesce(new.owner_id, '')) c
   where c.id = new.column_id;
  if v_label is null then
    v_label := coalesce(
      (select s.label from public.pipeline_steps s where new.board = 'recruiting' and s.id = new.column_id),
      (select s.label from public.customer_steps s where new.board = 'customer' and s.id = new.column_id),
      'Next step');
  end if;
  v_why := case new.reason
    when 'they_cancelled' then 'They cancelled'
    when 'no_show' then 'No-show'
    when 'unreachable' then 'Couldn''t reach them'
    when 'not_interested' then 'Not interested anymore'
    else coalesce(nullif(trim(new.reason_text), ''), 'Other')
  end;
  insert into public.activity (id, workspace_id, "timestamp", actor_name, actor_id, entity_type,
                               entity_id, related_person_id, kind, summary, meta)
  values ('stepcancel-' || new.id, new.workspace_id, new.cancelled_at,
          coalesce((select p.name from public.people p where p.id = new.cancelled_by), 'Someone'),
          new.cancelled_by, 'person', v_person, v_person, 'note',
          v_label || ' cancelled · ' || v_why,
          jsonb_build_object('cancellationId', new.id, 'board', new.board, 'reason', new.reason))
  on conflict (id) do nothing;
  return new;
end $$;
create trigger pipeline_step_cancellations_after_insert
  after insert on public.pipeline_step_cancellations
  for each row execute function public.pipeline_step_cancellations_after_insert();

create function public.pipeline_step_cancellations_after_delete() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.activity a where a.id = 'stepcancel-' || old.id;
  return old;
end $$;
create trigger pipeline_step_cancellations_after_delete
  after delete on public.pipeline_step_cancellations
  for each row execute function public.pipeline_step_cancellations_after_delete();

alter table public.pipeline_step_cancellations enable row level security;

-- Read: whoever reads the card, or the moves of its owner (so the numbers
-- outlive the card). Candidates have no pipeline.
create policy "read cancellations of your team" on public.pipeline_step_cancellations
  for select to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and not (select public.is_candidate())
         and (public.step_card_visible(board, card_id)
              or owner_id in (select public.visible_person_ids())));
-- Write: whoever edits the card, as themselves, naming the card's real owner.
create policy "cancel a booked step on a card you edit" on public.pipeline_step_cancellations
  for insert to authenticated
  with check (workspace_id = (select public.current_workspace_id())
              and cancelled_by = (select public.current_person_id())
              and public.step_card_visible(board, card_id)
              and owner_id = public.step_card_owner(board, card_id));
-- Undo: your own, within the hour. Nobody edits one.
create policy "undo your cancellation within the hour" on public.pipeline_step_cancellations
  for delete to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and cancelled_by = (select public.current_person_id())
         and cancelled_at > now() - interval '1 hour');

revoke execute on function public.board_columns(text, text) from public, anon;
revoke execute on function public.board_column_ord(text, text, text) from public, anon;
revoke execute on function public.booking_kept(text, text, text, text) from public, anon;
revoke execute on function public.legacy_next_column(text, text, text, text) from public, anon, authenticated;
revoke execute on function public.step_card_owner(text, text) from public, anon;
revoke execute on function public.step_card_visible(text, text) from public, anon;
revoke execute on function public.pipeline_step_cancellations_after_insert() from public, anon, authenticated;
revoke execute on function public.pipeline_step_cancellations_after_delete() from public, anon, authenticated;
grant execute on function public.board_columns(text, text) to authenticated;
grant execute on function public.board_column_ord(text, text, text) to authenticated;
grant execute on function public.booking_kept(text, text, text, text) to authenticated;
grant execute on function public.step_card_owner(text, text) to authenticated;
grant execute on function public.step_card_visible(text, text) to authenticated;

-- END ORIGINAL 20261014005000_pipeline_next_steps.sql

-- BEGIN ORIGINAL 20261014009000_event_ticket_url.sql
-- Where people buy a ticket for an event (client: CrmEvent.ticketUrl).
--
-- A link the event's organiser pastes in: the bigger team's ticket page, a
-- Venmo link for a small meeting, and so on. The app shows a "Buy ticket"
-- button that opens it. Only http(s) links are allowed, so a stored value can
-- never run script when it's opened.

alter table public.events
  add column ticket_url text
    check (ticket_url is null or (ticket_url ~* '^https?://[^\s]+$' and length(ticket_url) <= 2000));

-- END ORIGINAL 20261014009000_event_ticket_url.sql

-- BEGIN ORIGINAL 20261014010000_milestone_history.sql
-- Growth path: milestone history (client: MilestoneHistory, store
-- `milestoneHistory`, src/data/growth).
--
-- Milestones are no longer "first reached stays reached": the headcount ones
-- (3/10, 6/25, 6/50, 12/100) count only while the numbers meet them now, and
-- the volume ones for the month they're met and the month after. The first
-- day each was ever reached is still history, and unlocks go by it (dropping
-- below 3/10 keeps event planning). The volume milestones' history comes
-- from the PV on record; the ones counted from the sponsor tree (First
-- sponsor and the headcount milestones) would be forgotten when the tree
-- shrinks, so the app records them here while the data shows them: the first
-- day reached and the last day seen met (refreshed at most monthly).
--
-- The rules run in the app; the database keeps a row per person and
-- milestone, lets the person and their uplines write it, never moves the
-- first day later or the last day earlier, and records who wrote it. Nobody
-- deletes history from the app (the row goes with the person).

create table public.milestone_history (
  person_id text not null references public.people (id) on delete cascade,
  code text not null check (code in ('new_apprentice', 'first_sale', 'core_150', 'core_300',
    'first_sponsor', 'bronze_foundation', '3_10', 'bronze_builder', '6_25', '6_50',
    'platinum', 'ruby', '12_100')),
  workspace_id text not null default public.current_workspace_id()
    references public.workspaces (id) on delete cascade,
  first_reached_on date not null,
  last_met_on date not null,
  recorded_by text default public.current_person_id() references public.people (id) on delete set null,
  recorded_at timestamptz not null default now(),
  primary key (person_id, code),
  check (last_met_on >= first_reached_on)
);
comment on table public.milestone_history is
  'The first day a growth milestone was reached and the last day it was seen met, recorded by the app (count milestones; the PV ones come from the PV on record).';

-- Clients can't choose who recorded a row or when, move it to another person
-- or milestone, or date it in the future (a day of slack for time zones). An
-- update keeps the earlier first day and the later last day, so two people
-- recording at once can't lose history.
create function public.milestone_history_stamp() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if public.is_client_write() then
    if tg_op = 'UPDATE' then
      if new.person_id is distinct from old.person_id or new.code is distinct from old.code
          or new.workspace_id is distinct from old.workspace_id then
        raise exception 'Milestone history can''t move to another person or milestone'
          using errcode = '42501';
      end if;
      new.first_reached_on := least(old.first_reached_on, new.first_reached_on);
      new.last_met_on := greatest(old.last_met_on, new.last_met_on);
    end if;
    if new.first_reached_on > current_date + 1 or new.last_met_on > current_date + 1 then
      raise exception 'Milestone history can''t be in the future' using errcode = '23514';
    end if;
    new.recorded_by := public.current_person_id();
    new.recorded_at := now();
  end if;
  return new;
end $$;
create trigger milestone_history_stamp before insert or update on public.milestone_history
  for each row execute function public.milestone_history_stamp();
revoke execute on function public.milestone_history_stamp() from public, anon, authenticated;

-- RLS: anyone who can see the person reads; the person and their uplines
-- record (candidates never); nobody deletes.
alter table public.milestone_history enable row level security;

create policy "milestone history of visible people" on public.milestone_history
  for select to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and person_id in (select public.visible_person_ids()));
create policy "the person and their uplines record history" on public.milestone_history
  for insert to authenticated
  with check (workspace_id = (select public.current_workspace_id())
              and not public.is_candidate()
              and (person_id = public.current_person_id() or public.is_upline_of(person_id)));
create policy "the person and their uplines update history" on public.milestone_history
  for update to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and not public.is_candidate()
         and (person_id = public.current_person_id() or public.is_upline_of(person_id)))
  with check (workspace_id = (select public.current_workspace_id())
              and not public.is_candidate()
              and (person_id = public.current_person_id() or public.is_upline_of(person_id)));

grant select, insert, update on public.milestone_history to authenticated;

-- END ORIGINAL 20261014010000_milestone_history.sql

-- BEGIN ORIGINAL 20261016000100_contact_rating.sql
-- Hot / Warm / Cold for new contacts (src/data/rating.ts).
--
-- * list_entries.rating gains 'cold' (it was 'warm' or 'hot').
-- * pipeline_cards gets the same rating column. The old `hot` flag stays (the
--   move_pipeline_card() RPC and older clients still send it) and is kept in
--   step by a trigger: a new rating sets hot = (rating = 'hot'); a changed
--   hot flag alone sets the rating to 'hot', or clears a 'hot' rating.
--
-- RLS is unchanged: both are ordinary columns of tables that already have
-- their policies.

alter table public.list_entries drop constraint list_entries_rating_check;
alter table public.list_entries
  add constraint list_entries_rating_check check (rating in ('hot', 'warm', 'cold'));

alter table public.pipeline_cards
  add column rating text check (rating in ('hot', 'warm', 'cold'));

update public.pipeline_cards set rating = 'hot' where hot;

create function public.pipeline_cards_sync_rating() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.rating is not null then
      new.hot := new.rating = 'hot';
    elsif new.hot then
      new.rating := 'hot';
    end if;
  elsif new.rating is distinct from old.rating then
    new.hot := coalesce(new.rating = 'hot', false);
  elsif new.hot is distinct from old.hot then
    new.rating := case
      when new.hot then 'hot'
      when old.rating = 'hot' then null
      else old.rating
    end;
  end if;
  return new;
end $$;

create trigger pipeline_cards_sync_rating
  before insert or update on public.pipeline_cards
  for each row execute function public.pipeline_cards_sync_rating();

-- END ORIGINAL 20261016000100_contact_rating.sql

-- BEGIN ORIGINAL 20261016000200_move_pipeline_card_rating.sql
-- move_pipeline_card() takes the card's rating (Hot / Warm / Cold, migration
-- 20261016000100_contact_rating), so a prospect added with a rating comes
-- back from its first move with it (the app shows the RPC's card row). Same
-- body as 20261014005000_pipeline_next_steps.sql otherwise; the rating trigger
-- keeps `hot` in step.

drop function public.move_pipeline_card(text, text, text, text, date, time, text, boolean);

create function public.move_pipeline_card(
  p_person_id text,
  p_to text,
  p_move_id text default null,
  p_next_column text default null,
  p_next_step_date date default null,
  p_next_step_time time default null,
  p_source text default null,
  p_hot boolean default null,
  p_rating text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_me text := public.current_person_id();
  v_ws text := public.current_workspace_id();
  v_p public.people;
  v_card public.pipeline_cards;
  v_had_card boolean;
  v_band text;
  v_owner text;
  v_next text;
  v_date date;
  v_time time;
  v_move public.pipeline_moves;
begin
  if v_me is null or public.is_candidate() then
    raise exception 'Candidates don''t have a pipeline yet' using errcode = '42501';
  end if;
  select * into v_p from public.people p where p.id = p_person_id for update;
  if not found or v_p.workspace_id is distinct from v_ws or not public.can_see_person(p_person_id) then
    raise exception 'Person not found' using errcode = 'P0002';
  end if;
  if v_p.biz_class <> 'prospect' then
    raise exception 'Only prospects move on the board' using errcode = '22023';
  end if;
  v_owner := coalesce(v_p.sponsor_id, v_me);

  v_band := case
    when p_to in ('contact', 'first_meeting', 'first_plan', 'registered') then p_to
    when p_to = 'not_contacted' then 'start'
    when p_to in ('not_interested', 'do_not_contact') then 'out'
  end;
  if v_band is null then
    select s.band into v_band from public.pipeline_steps s
     where s.id = p_to and s.workspace_id = v_ws
       and (s.owner_id in (select c.person_id from public.sponsor_chain(v_owner) c)
            or s.owner_id in (select public.my_chain_ids()));
  end if;
  if v_band is null then
    raise exception 'That column isn''t on this board' using errcode = '22023';
  end if;

  select * into v_card from public.pipeline_cards c where c.person_id = p_person_id for update;
  v_had_card := found;
  if v_had_card and v_card.dropped_at is not null then
    raise exception 'That card is off the board' using errcode = '22023';
  end if;
  if v_had_card and v_card.column_id = p_to then
    raise exception 'Already there' using errcode = '22023';
  end if;

  -- The booking after the move.
  if nullif(trim(p_next_column), '') is not null and p_next_column <> p_to then
    v_next := p_next_column;
    v_date := p_next_step_date;
    v_time := case when p_next_step_date is not null then p_next_step_time end;
  elsif v_had_card and public.booking_kept('recruiting', v_owner, v_card.next_column, p_to) then
    v_next := v_card.next_column;
    v_date := v_card.next_step_date;
    v_time := v_card.next_step_time;
  end if;

  insert into public.pipeline_moves (id, workspace_id, person_id, owner_id, from_column, to_column,
                                     milestone, moved_at, moved_by, booking_before)
  values (coalesce(nullif(trim(p_move_id), ''), gen_random_uuid()::text), v_ws, p_person_id,
          v_owner, case when v_had_card then v_card.column_id end, p_to,
          v_band, now(), v_me,
          jsonb_build_object('next_column', v_card.next_column,
                             'next_step_date', v_card.next_step_date,
                             'next_step_time', v_card.next_step_time))
  returning * into v_move;

  insert into public.pipeline_cards (person_id, workspace_id, column_id, entered_at, next_column,
                                     next_step_date, next_step_time, hot, rating, source,
                                     dropped_at, updated_at)
  values (p_person_id, v_ws, p_to, v_move.moved_at, v_next, v_date, v_time,
          coalesce(p_hot, false), p_rating, nullif(trim(p_source), ''), null, now())
  on conflict (person_id) do update
     set column_id = excluded.column_id,
         entered_at = excluded.entered_at,
         next_column = excluded.next_column,
         next_step_date = excluded.next_step_date,
         next_step_time = excluded.next_step_time,
         hot = coalesce(p_hot, public.pipeline_cards.hot),
         rating = coalesce(p_rating, public.pipeline_cards.rating),
         source = coalesce(nullif(trim(p_source), ''), public.pipeline_cards.source),
         updated_at = now()
  returning * into v_card;

  if p_to = 'registered' then
    update public.people
       set biz_class = 'apprentice',
           pipeline_stage = 'apprentice',
           business_start_date = public.workspace_today(v_ws),
           stage_history = stage_history || jsonb_build_array(jsonb_build_object(
             'stage', 'apprentice',
             'at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')))
     where id = p_person_id;
    insert into public.activity (workspace_id, actor_name, actor_id, entity_type, entity_id,
                                 related_person_id, kind, summary, meta)
    values (v_ws, coalesce((select p.name from public.people p where p.id = v_me), 'Someone'), v_me,
            'person', p_person_id, p_person_id, 'stage_changed', 'Pipeline → apprentice',
            jsonb_build_object('from', 'prospect', 'to', 'apprentice'));
  end if;

  return jsonb_build_object('move', to_jsonb(v_move), 'card', to_jsonb(v_card));
end $$;

grant execute on function public.move_pipeline_card(text, text, text, text, date, time, text, boolean, text) to authenticated;
revoke execute on function public.move_pipeline_card(text, text, text, text, date, time, text, boolean, text) from public, anon;

-- END ORIGINAL 20261016000200_move_pipeline_card_rating.sql

-- BEGIN ORIGINAL 20261016001000_dashboard_layouts.sql
-- Home's card layout, per person (client: src/data/homeLayout.ts, store
-- `homeLayouts`, binding `homeLayoutBinding`).
--
-- People rearrange the cards on Home (drag on desktop, "Edit layout" on
-- phones) and the layout follows them to every device. One row per person:
--
--  * layout = {"order": [card id, ...], "side": [card id, ...]}: every card in
--    order (phones show them in this order), and the cards in the right-hand
--    column on desktop. Card ids are the app's ("today", "team", "myDay", ...);
--    only their shape is checked here, so a new card needs no migration. The
--    app keeps ids it doesn't know (a newer client's), appends cards missing
--    from the list in their default place, and skips cards the person can't
--    see right now.
--  * No row = the default layout. "Reset layout" deletes the row.
--
-- Only the person reads or writes their own row.

create function public.dashboard_layout_valid(p_layout jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_key text;
  v_list jsonb;
  v_id jsonb;
begin
  if p_layout is null or jsonb_typeof(p_layout) <> 'object' then
    return false;
  end if;
  for v_key in select jsonb_object_keys(p_layout) loop
    if v_key not in ('order', 'side') then
      return false;
    end if;
    v_list := p_layout -> v_key;
    if jsonb_typeof(v_list) <> 'array' or jsonb_array_length(v_list) > 50 then
      return false;
    end if;
    for v_id in select value from jsonb_array_elements(v_list) loop
      if jsonb_typeof(v_id) <> 'string' or (v_id #>> '{}') !~ '^[A-Za-z][A-Za-z0-9_-]{0,39}$' then
        return false;
      end if;
    end loop;
    if (select count(distinct value) from jsonb_array_elements(v_list)) <> jsonb_array_length(v_list) then
      return false;
    end if;
  end loop;
  return true;
end $$;

comment on function public.dashboard_layout_valid(jsonb) is
  'dashboard_layouts.layout shape: an object with only "order" and "side", each an array of at '
  'most 50 distinct card ids (a letter, then letters, digits, _ or -, at most 40 characters).';

create table public.dashboard_layouts (
  person_id text primary key default public.current_person_id()
    references public.people (id) on delete cascade,
  workspace_id text not null default public.current_workspace_id()
    references public.workspaces (id) on delete cascade,
  layout jsonb not null default '{"order": [], "side": []}'::jsonb
    constraint dashboard_layouts_layout_valid check (public.dashboard_layout_valid(layout)),
  updated_at timestamptz not null default now()
);
comment on table public.dashboard_layouts is
  'How each person arranged the cards on Home (order, and the desktop right-hand column); no row = the default.';

create trigger dashboard_layouts_touch before update on public.dashboard_layouts
  for each row execute function public.touch_updated_at();

alter table public.dashboard_layouts enable row level security;

create policy "own dashboard layout" on public.dashboard_layouts
  for all to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and person_id = (select public.current_person_id()))
  with check (workspace_id = (select public.current_workspace_id())
              and person_id = (select public.current_person_id()));

grant select, insert, update, delete on public.dashboard_layouts to authenticated;

-- END ORIGINAL 20261016001000_dashboard_layouts.sql

-- BEGIN ORIGINAL 20261016001500_referral_source.sql
-- "Referral source": a fixed outcome column on both boards (Jay's request,
-- 2026-10-16; client: src/data/pipeline/types.ts REFERRAL_SOURCE). Someone
-- who isn't a fit or isn't interested but passes on names of people who are.
--
--  * The column sits in the "out" band, first (before Not interested and Do
--    not contact). Like the other outcomes it reaches no milestone, so the
--    counts (pipeline_person_counts(), the funnels) are unchanged; a card can
--    move there from anywhere and back.
--  * move_pipeline_card() / move_customer_card() accept it; board_columns()
--    lists it (so bookings and their clearing treat it as an outcome).
--  * Steps can't take its id or name. A step already called "Referral source"
--    gets " (step)" added, so nothing is lost.

-- ---------------------------------------------------------------------------
-- Steps can't take the name or id
-- ---------------------------------------------------------------------------

update public.pipeline_steps
   set label = left(trim(label), 17) || ' (step)'
 where lower(trim(label)) = 'referral source';
update public.customer_steps
   set label = left(trim(label), 17) || ' (step)'
 where lower(trim(label)) = 'referral source';

alter table public.pipeline_steps drop constraint pipeline_steps_id_check;
alter table public.pipeline_steps add constraint pipeline_steps_id_check check (
  id not in ('contact', 'first_meeting', 'first_plan', 'registered',
             'not_contacted', 'not_interested', 'do_not_contact', 'referral_source')
);
alter table public.pipeline_steps drop constraint pipeline_steps_label_check;
alter table public.pipeline_steps add constraint pipeline_steps_label_check check (
  length(trim(label)) between 1 and 24
  and lower(trim(label)) not in ('contact made', 'first meeting', 'first plan', 'registered',
                                 'not contacted yet', 'not interested', 'do not contact',
                                 'referral source')
);

alter table public.customer_steps drop constraint customer_steps_id_check;
alter table public.customer_steps add constraint customer_steps_id_check check (
  id not in ('contact', 'first_meeting', 'first_sale', 'on_ditto', 'not_contacted',
             'new_contact', 'not_interested', 'do_not_contact', 'referral_source')
);
alter table public.customer_steps drop constraint customer_steps_label_check;
alter table public.customer_steps add constraint customer_steps_label_check check (
  length(trim(label)) between 1 and 24
  and lower(trim(label)) not in ('contact', 'first meeting', 'first sale', 'on ditto',
                                 'not contacted yet', 'new contacts', 'not interested',
                                 'do not contact', 'referral source')
);

-- ---------------------------------------------------------------------------
-- A board's columns, in order: as in 20261014005000_pipeline_next_steps.sql,
-- with Referral source first in the outcomes (mirror of columnsFor).
-- ---------------------------------------------------------------------------

create or replace function public.board_columns(p_board text, p_owner text)
returns table (id text, band text, kind text, label text, ord integer)
language sql stable security definer set search_path = ''
as $$
  with chain as (
    select c.person_id, c.depth from public.sponsor_chain(p_owner) c
  ),
  bands (band, bord) as (
    select * from (values ('start', 0), ('contact', 1), ('first_meeting', 2),
                          ('first_plan', 3), ('first_sale', 3), ('registered', 4),
                          ('on_ditto', 4), ('out', 5)) b (band, bord)
  ),
  fixed (id, band, kind, label, sub) as (
    select * from (values
      ('not_contacted', 'start', 'fixed', 'Not contacted yet', 0),
      ('referral_source', 'out', 'fixed', 'Referral source', 0),
      ('not_interested', 'out', 'fixed', 'Not interested', 1),
      ('do_not_contact', 'out', 'fixed', 'Do not contact', 2)) f (id, band, kind, label, sub)
  ),
  milestones (id, band, kind, label, sub) as (
    select m.id, m.id, 'milestone', m.label, 0 from (values
      ('recruiting', 'contact', 'Contact made'),
      ('recruiting', 'first_meeting', 'First meeting (MG1)'),
      ('recruiting', 'first_plan', 'First plan (Info 1)'),
      ('recruiting', 'registered', 'Registered'),
      ('customer', 'contact', 'Contact'),
      ('customer', 'first_meeting', 'First meeting'),
      ('customer', 'first_sale', 'First sale'),
      ('customer', 'on_ditto', 'On Ditto')) m (board, id, label)
    where m.board = p_board
  ),
  steps (id, band, label, depth, pos, created) as (
    select s.id, s.band, s.label, ch.depth, s.position, s.created_at
      from public.pipeline_steps s join chain ch on ch.person_id = s.owner_id
     where p_board = 'recruiting'
       and not exists (select 1 from public.pipeline_step_hides h
                        join chain c2 on c2.person_id = h.person_id where h.step_id = s.id)
    union all
    select s.id, s.band, s.label, ch.depth, s.position, s.created_at
      from public.customer_steps s join chain ch on ch.person_id = s.owner_id
     where p_board = 'customer'
       and not exists (select 1 from public.customer_step_hides h
                        join chain c2 on c2.person_id = h.person_id where h.step_id = s.id)
  ),
  cols (id, band, kind, label, sub, depth, pos, created) as (
    select f.id, f.band, f.kind, f.label, f.sub, 0, 0, null::timestamptz from fixed f
    union all
    select m.id, m.band, m.kind, m.label, 0, 0, 0, null from milestones m
    union all
    select s.id, s.band, 'step', s.label, 1, s.depth, s.pos, s.created from steps s
  )
  select c.id, c.band, c.kind, c.label,
         (row_number() over (order by b.bord, c.sub, c.depth, c.pos, c.created, c.id))::integer
    from cols c join bands b on b.band = c.band
$$;

-- ---------------------------------------------------------------------------
-- Moves: as in 20261016000200_move_pipeline_card_rating.sql and
-- 20261014005000_pipeline_next_steps.sql, with Referral source an outcome.
-- ---------------------------------------------------------------------------

create or replace function public.move_pipeline_card(
  p_person_id text,
  p_to text,
  p_move_id text default null,
  p_next_column text default null,
  p_next_step_date date default null,
  p_next_step_time time default null,
  p_source text default null,
  p_hot boolean default null,
  p_rating text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_me text := public.current_person_id();
  v_ws text := public.current_workspace_id();
  v_p public.people;
  v_card public.pipeline_cards;
  v_had_card boolean;
  v_band text;
  v_owner text;
  v_next text;
  v_date date;
  v_time time;
  v_move public.pipeline_moves;
begin
  if v_me is null or public.is_candidate() then
    raise exception 'Candidates don''t have a pipeline yet' using errcode = '42501';
  end if;
  select * into v_p from public.people p where p.id = p_person_id for update;
  if not found or v_p.workspace_id is distinct from v_ws or not public.can_see_person(p_person_id) then
    raise exception 'Person not found' using errcode = 'P0002';
  end if;
  if v_p.biz_class <> 'prospect' then
    raise exception 'Only prospects move on the board' using errcode = '22023';
  end if;
  v_owner := coalesce(v_p.sponsor_id, v_me);

  v_band := case
    when p_to in ('contact', 'first_meeting', 'first_plan', 'registered') then p_to
    when p_to = 'not_contacted' then 'start'
    when p_to in ('referral_source', 'not_interested', 'do_not_contact') then 'out'
  end;
  if v_band is null then
    select s.band into v_band from public.pipeline_steps s
     where s.id = p_to and s.workspace_id = v_ws
       and (s.owner_id in (select c.person_id from public.sponsor_chain(v_owner) c)
            or s.owner_id in (select public.my_chain_ids()));
  end if;
  if v_band is null then
    raise exception 'That column isn''t on this board' using errcode = '22023';
  end if;

  select * into v_card from public.pipeline_cards c where c.person_id = p_person_id for update;
  v_had_card := found;
  if v_had_card and v_card.dropped_at is not null then
    raise exception 'That card is off the board' using errcode = '22023';
  end if;
  if v_had_card and v_card.column_id = p_to then
    raise exception 'Already there' using errcode = '22023';
  end if;

  -- The booking after the move.
  if nullif(trim(p_next_column), '') is not null and p_next_column <> p_to then
    v_next := p_next_column;
    v_date := p_next_step_date;
    v_time := case when p_next_step_date is not null then p_next_step_time end;
  elsif v_had_card and public.booking_kept('recruiting', v_owner, v_card.next_column, p_to) then
    v_next := v_card.next_column;
    v_date := v_card.next_step_date;
    v_time := v_card.next_step_time;
  end if;

  insert into public.pipeline_moves (id, workspace_id, person_id, owner_id, from_column, to_column,
                                     milestone, moved_at, moved_by, booking_before)
  values (coalesce(nullif(trim(p_move_id), ''), gen_random_uuid()::text), v_ws, p_person_id,
          v_owner, case when v_had_card then v_card.column_id end, p_to,
          v_band, now(), v_me,
          jsonb_build_object('next_column', v_card.next_column,
                             'next_step_date', v_card.next_step_date,
                             'next_step_time', v_card.next_step_time))
  returning * into v_move;

  insert into public.pipeline_cards (person_id, workspace_id, column_id, entered_at, next_column,
                                     next_step_date, next_step_time, hot, rating, source,
                                     dropped_at, updated_at)
  values (p_person_id, v_ws, p_to, v_move.moved_at, v_next, v_date, v_time,
          coalesce(p_hot, false), p_rating, nullif(trim(p_source), ''), null, now())
  on conflict (person_id) do update
     set column_id = excluded.column_id,
         entered_at = excluded.entered_at,
         next_column = excluded.next_column,
         next_step_date = excluded.next_step_date,
         next_step_time = excluded.next_step_time,
         hot = coalesce(p_hot, public.pipeline_cards.hot),
         rating = coalesce(p_rating, public.pipeline_cards.rating),
         source = coalesce(nullif(trim(p_source), ''), public.pipeline_cards.source),
         updated_at = now()
  returning * into v_card;

  if p_to = 'registered' then
    update public.people
       set biz_class = 'apprentice',
           pipeline_stage = 'apprentice',
           business_start_date = public.workspace_today(v_ws),
           stage_history = stage_history || jsonb_build_array(jsonb_build_object(
             'stage', 'apprentice',
             'at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')))
     where id = p_person_id;
    insert into public.activity (workspace_id, actor_name, actor_id, entity_type, entity_id,
                                 related_person_id, kind, summary, meta)
    values (v_ws, coalesce((select p.name from public.people p where p.id = v_me), 'Someone'), v_me,
            'person', p_person_id, p_person_id, 'stage_changed', 'Pipeline → apprentice',
            jsonb_build_object('from', 'prospect', 'to', 'apprentice'));
  end if;

  return jsonb_build_object('move', to_jsonb(v_move), 'card', to_jsonb(v_card));
end $$;

create or replace function public.move_customer_card(
  p_entry_id text,
  p_to text,
  p_move_id text default null,
  p_customer_id text default null,
  p_next_column text default null,
  p_next_step_date date default null,
  p_next_step_time time default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_me text := public.current_person_id();
  v_ws text := public.current_workspace_id();
  v_e public.list_entries;
  v_card public.customer_cards;
  v_had_card boolean;
  v_band text;
  v_customer text;
  v_created text;
  v_ditto boolean := false;
  v_next text;
  v_date date;
  v_time time;
  v_move public.customer_moves;
begin
  if v_me is null or public.is_candidate() then
    raise exception 'Candidates don''t have a customer pipeline yet' using errcode = '42501';
  end if;
  select * into v_e from public.list_entries e where e.id = p_entry_id for update;
  if not found or not public.list_owner_visible(v_e.workspace_id, v_e.owner_id) then
    raise exception 'Name not found' using errcode = 'P0002';
  end if;

  v_band := case
    when p_to in ('contact', 'first_meeting', 'first_sale', 'on_ditto') then p_to
    when p_to = 'not_contacted' then 'start'
    when p_to in ('referral_source', 'not_interested', 'do_not_contact') then 'out'
  end;
  if v_band is null then
    select s.band into v_band from public.customer_steps s
     where s.id = p_to and s.workspace_id = v_ws
       and (s.owner_id in (select c.person_id from public.sponsor_chain(v_e.owner_id) c)
            or s.owner_id in (select public.my_chain_ids()));
  end if;
  if v_band is null then
    raise exception 'That column isn''t on this board' using errcode = '22023';
  end if;

  select * into v_card from public.customer_cards c where c.entry_id = p_entry_id for update;
  v_had_card := found;
  if coalesce(v_card.column_id, 'not_contacted') = p_to then
    raise exception 'Already there' using errcode = '22023';
  end if;

  -- First sale: the name becomes a customer of the list's owner.
  v_customer := v_e.customer_id;
  if v_band in ('first_sale', 'on_ditto') and v_customer is null then
    v_created := coalesce(nullif(trim(p_customer_id), ''), gen_random_uuid()::text);
    insert into public.people (id, workspace_id, name, phone, email, biz_class, owner_id,
                               sponsor_id, joined_date, notes)
    values (v_created, v_ws, v_e.name, v_e.phone, v_e.email, 'customer', v_e.owner_id, null,
            public.workspace_today(v_ws),
            case when v_e.how_known is not null then 'From your list: ' || v_e.how_known end);
    update public.list_entries set customer_id = v_created where id = v_e.id;
    insert into public.activity (workspace_id, actor_name, actor_id, entity_type, entity_id,
                                 related_person_id, kind, summary)
    values (v_ws, coalesce((select p.name from public.people p where p.id = v_me), 'Someone'), v_me,
            'person', v_created, v_created, 'created', format('Added %s (Customer)', v_e.name));
    v_customer := v_created;
  end if;

  -- On Ditto: a subscription customer from today.
  if v_band = 'on_ditto' then
    update public.people p set ditto_since = public.workspace_today(v_ws)
     where p.id = v_customer and p.biz_class = 'customer' and p.ditto_since is null;
    v_ditto := found;
  end if;

  -- The booking after the move.
  if nullif(trim(p_next_column), '') is not null and p_next_column <> p_to then
    v_next := p_next_column;
    v_date := p_next_step_date;
    v_time := case when p_next_step_date is not null then p_next_step_time end;
  elsif v_had_card and public.booking_kept('customer', v_e.owner_id, v_card.next_column, p_to) then
    v_next := v_card.next_column;
    v_date := v_card.next_step_date;
    v_time := v_card.next_step_time;
  end if;

  insert into public.customer_moves (id, workspace_id, entry_id, owner_id, from_column, to_column,
                                     band, moved_at, moved_by, created_customer_id, set_ditto,
                                     booking_before)
  values (coalesce(nullif(trim(p_move_id), ''), gen_random_uuid()::text), v_ws, p_entry_id,
          v_e.owner_id, case when v_had_card then v_card.column_id end, p_to, v_band, now(), v_me,
          v_created, v_ditto,
          jsonb_build_object('next_column', v_card.next_column,
                             'next_step_date', v_card.next_step_date,
                             'next_step_time', v_card.next_step_time))
  returning * into v_move;

  insert into public.customer_cards (entry_id, workspace_id, column_id, entered_at, next_column,
                                     next_step_date, next_step_time, updated_at)
  values (p_entry_id, v_ws, p_to, v_move.moved_at, v_next, v_date, v_time, now())
  on conflict (entry_id) do update
     set column_id = excluded.column_id,
         entered_at = excluded.entered_at,
         next_column = excluded.next_column,
         next_step_date = excluded.next_step_date,
         next_step_time = excluded.next_step_time,
         updated_at = now()
  returning * into v_card;

  return jsonb_build_object('move', to_jsonb(v_move), 'card', to_jsonb(v_card));
end $$;

-- END ORIGINAL 20261016001500_referral_source.sql

-- BEGIN ORIGINAL 20261016001600_referred_by.sql
-- "Referred by": who passed on a prospect's, customer's or list name's
-- details (client: src/data/referrals). A referrer is a person (a prospect,
-- a customer, a team member) or a name on a list (the customer board's
-- Referral source column holds list names, which aren't people), so each
-- referred row has two optional links, at most one of them set:
--
--  * people.referred_by / list_entries.referred_by: a person;
--  * people.referred_by_entry / list_entries.referred_by_entry: a list name.
--
-- Both are "on delete set null": deleting the referrer only drops the link.
-- Nothing is copied when a name becomes a prospect or customer: the app reads
-- the referral through the entry's prospect_id / customer_id link.
--
-- Rules (row-level security is unchanged; a guard adds, for client writes):
--  * the referrer must be someone the writer can see (can_see_person(), the
--    same set as the CRM view) or a name on a list they can see
--    (list_entry_visible()); checked only when the link is set or changed, so
--    an upline editing a downline's prospect referred by the downline's
--    private customer can still save other fields;
--  * nobody refers themselves (a row never links to itself).

alter table public.people
  add column referred_by text references public.people (id) on delete set null,
  add column referred_by_entry text references public.list_entries (id) on delete set null,
  add constraint people_referred_by_one check (num_nonnulls(referred_by, referred_by_entry) <= 1),
  add constraint people_referred_by_not_self check (referred_by is distinct from id);
create index people_referred_by_idx on public.people (referred_by) where referred_by is not null;
create index people_referred_by_entry_idx on public.people (referred_by_entry)
  where referred_by_entry is not null;
comment on column public.people.referred_by is 'Who referred this prospect or customer (a person).';
comment on column public.people.referred_by_entry is 'Who referred this prospect or customer (a name on a list).';

alter table public.list_entries
  add column referred_by text references public.people (id) on delete set null,
  add column referred_by_entry text references public.list_entries (id) on delete set null,
  add constraint list_entries_referred_by_one check (num_nonnulls(referred_by, referred_by_entry) <= 1),
  add constraint list_entries_referred_by_not_self check (referred_by_entry is distinct from id);
create index list_entries_referred_by_idx on public.list_entries (referred_by)
  where referred_by is not null;
create index list_entries_referred_by_entry_idx on public.list_entries (referred_by_entry)
  where referred_by_entry is not null;
comment on column public.list_entries.referred_by is 'Who referred this name (a person).';
comment on column public.list_entries.referred_by_entry is 'Who referred this name (another name on a list).';

-- The referrer must be visible to the writer (client writes only: the seed
-- and security-definer RPCs are trusted).
create function public.referral_guard() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if not public.is_client_write() then
    return new;
  end if;
  if new.referred_by is not null
     and (tg_op = 'INSERT' or new.referred_by is distinct from old.referred_by)
     and not public.can_see_person(new.referred_by) then
    raise exception 'Referred by someone you can''t see' using errcode = '42501';
  end if;
  if new.referred_by_entry is not null
     and (tg_op = 'INSERT' or new.referred_by_entry is distinct from old.referred_by_entry)
     and not public.list_entry_visible(new.referred_by_entry) then
    raise exception 'Referred by a name you can''t see' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger people_referral_guard
  before insert or update of referred_by, referred_by_entry on public.people
  for each row execute function public.referral_guard();
create trigger list_entries_referral_guard
  before insert or update of referred_by, referred_by_entry on public.list_entries
  for each row execute function public.referral_guard();

-- END ORIGINAL 20261016001600_referred_by.sql

-- BEGIN ORIGINAL 20261016002000_event_categories.sql
-- Event categories replace the six fixed event types
-- (docs/plans/mvp-plan-2026-10-13.md "Events", Jay's requests 2026-10-16;
-- mirror of src/data/eventCategories):
--   * each team keeps its own list of kinds of event: a name, an icon and a
--     color from small curated sets, and yes/no settings that used to come
--     from the type (online, tickets, travel, missed-event reminders,
--     customers welcome), in the team's order;
--   * every workspace starts with the six old types as categories (ids
--     '<workspace>-<old type>'), and every event points at one
--     (events.category_id; events.type is gone);
--   * anyone who may add events adds a category; leaders and their deputies
--     rename, change, reorder, archive and merge them. Merging moves every
--     event over and archives the old category in one step
--     (merge_event_categories). Categories are never deleted: archived ones
--     stay readable for old events and can't be picked for new ones;
--   * customers' missed events: the customer's owner (and the owner's
--     uplines) may leave the "already handled" note.

-- ---------------------------------------------------------------------------
-- event_categories (EventCategory)
-- ---------------------------------------------------------------------------

create table public.event_categories (
  id text primary key default gen_random_uuid()::text,
  workspace_id text not null default public.current_workspace_id()
    references public.workspaces (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 40),
  -- A key from the app's curated lucide set (unknown keys show a calendar).
  icon text not null default 'calendar' check (icon ~ '^[a-z0-9-]{1,32}$'),
  -- A color token key (src/data/eventCategories/types.ts CATEGORY_TONES).
  tone text not null default 'neutral'
    check (tone in ('neutral', 'green', 'blue', 'amber', 'rose')),
  allows_virtual boolean not null default false,
  uses_tickets boolean not null default false,
  uses_travel boolean not null default false,
  counts_for_missed_followups boolean not null default true,
  welcomes_customers boolean not null default false,
  -- Display order (lowest first); a new one without it goes last.
  position integer not null,
  archived_at timestamptz,
  created_by text default public.current_person_id() references public.people (id) on delete set null,
  created_at timestamptz not null default now()
);
comment on table public.event_categories is
  'A team''s kinds of event (Night Owls, Conference, …) and what each one uses: online, tickets, travel, missed-event reminders, customers welcome. Archived, never deleted.';
comment on column public.event_categories.counts_for_missed_followups is
  'Someone who came to the last one and misses the next one gets a follow-up from their uplines.';
comment on column public.event_categories.welcomes_customers is
  'Home suggests inviting your customers to the next ones.';

create index event_categories_workspace_idx on public.event_categories (workspace_id, position);
-- One active category per name in a team (archived ones may repeat a name).
create unique index event_categories_active_name_idx
  on public.event_categories (workspace_id, lower(btrim(name)))
  where archived_at is null;

-- The six starting categories (the old event types), same as
-- STARTING_CATEGORIES in src/data/eventCategories/rules.ts. Their ids are
-- '<workspace>-<old type>', so the demo, the seed and old links agree.
create function public.add_starting_event_categories(p_workspace_id text) returns void
language sql security definer set search_path = ''
as $$
  insert into public.event_categories
    (id, workspace_id, name, icon, tone, allows_virtual, uses_tickets, uses_travel,
     counts_for_missed_followups, welcomes_customers, position, created_by)
  select p_workspace_id || '-' || s.key, p_workspace_id, s.name, s.icon, 'neutral',
         s.virtual, s.tickets, s.travel, true, s.customers, s.position, null
  from (values
    ('night_owls',      'Night Owls',           'moon',       false, false, false, false, 0),
    ('work_session',    'Work session',         'briefcase',  false, false, false, false, 1),
    ('info_session',    'Info session',         'lightbulb',  true,  false, false, true,  2),
    ('training',        'Training',             'graduation', true,  false, false, true,  3),
    ('monthly_meeting', 'Monthly team meeting', 'users',      true,  true,  false, true,  4),
    ('conference',      'Conference',           'ticket',     true,  true,  true,  false, 5)
  ) as s(key, name, icon, virtual, tickets, travel, customers, position)
  on conflict do nothing
$$;
revoke execute on function public.add_starting_event_categories(text) from public, anon, authenticated;

-- A new workspace starts with them too.
create function public.workspaces_starting_categories() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.add_starting_event_categories(new.id);
  return new;
end $$;
revoke execute on function public.workspaces_starting_categories() from public, anon, authenticated;

create trigger workspaces_starting_categories after insert on public.workspaces
  for each row execute function public.workspaces_starting_categories();

select public.add_starting_event_categories(w.id) from public.workspaces w;

-- Who made a category and when are the database's, and never change. A new
-- category without a position goes after the others.
create function public.event_categories_stamp() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and new.position is null then
    select coalesce(max(c.position) + 1, 0) into new.position
      from public.event_categories c where c.workspace_id = new.workspace_id;
  end if;
  if public.is_client_write() then
    if tg_op = 'INSERT' then
      new.created_by := public.current_person_id();
      new.created_at := now();
      new.archived_at := null;
    else
      if new.workspace_id <> old.workspace_id then
        raise exception 'A category stays in its workspace' using errcode = '42501';
      end if;
      new.created_by := old.created_by;
      new.created_at := old.created_at;
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.event_categories_stamp() from public, anon, authenticated;

create trigger event_categories_stamp before insert or update on public.event_categories
  for each row execute function public.event_categories_stamp();

alter table public.event_categories enable row level security;

-- Everyone on the team reads the list (archived ones too: old events use them).
create policy "read event categories" on public.event_categories
  for select to authenticated
  using (workspace_id = (select public.current_workspace_id()));

-- Anyone who may add events adds a category (same rule as "add events").
create policy "add event categories" on public.event_categories
  for insert to authenticated
  with check (workspace_id = (select public.current_workspace_id())
              and not (select public.is_candidate()));

-- Renaming, settings, order and archiving: leaders and their deputies.
create policy "leaders edit event categories" on public.event_categories
  for update to authenticated
  using (workspace_id = (select public.current_workspace_id()) and (select public.acts_as_leader()))
  with check (workspace_id = (select public.current_workspace_id()));

-- No delete policy: categories are archived, never deleted.

-- ---------------------------------------------------------------------------
-- events.category_id replaces events.type
-- ---------------------------------------------------------------------------

alter table public.events add column category_id text
  references public.event_categories (id) on delete restrict;
update public.events set category_id = workspace_id || '-' || type;
alter table public.events alter column category_id set not null;
create index events_category_idx on public.events (category_id);
comment on column public.events.category_id is
  'The team''s event category (what kind of event; its settings decide tickets, travel and online).';

alter table public.events drop constraint events_format_for_type;
alter table public.events drop constraint events_type_check;
alter table public.events drop column type;
comment on column public.events.format is
  'How people can join: in_person, virtual or both. Virtual only when the category allows it (otherwise kept in person).';

-- An event's category: one of its workspace's, not archived when picked
-- (old events keep an archived one), the team's first one when left out.
-- A format the category doesn't allow becomes in person (the app does the
-- same before saving, and a merge relies on it).
create function public.events_category_check() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_cat public.event_categories;
begin
  if new.category_id is null then
    select c.id into new.category_id from public.event_categories c
     where c.workspace_id = new.workspace_id and c.archived_at is null
     order by c.position, c.created_at, c.id limit 1;
  end if;
  select * into v_cat from public.event_categories c where c.id = new.category_id;
  if v_cat.id is null or v_cat.workspace_id is distinct from new.workspace_id then
    raise exception 'The category isn''t in this workspace' using errcode = '23514';
  end if;
  if tg_op = 'INSERT' or new.category_id is distinct from old.category_id then
    if v_cat.archived_at is not null then
      raise exception 'That category is archived' using errcode = '23514';
    end if;
  end if;
  if not v_cat.allows_virtual and new.format <> 'in_person'
     and (tg_op = 'INSERT' or new.category_id is distinct from old.category_id
          or new.format is distinct from old.format) then
    new.format := 'in_person';
  end if;
  return new;
end $$;
revoke execute on function public.events_category_check() from public, anon, authenticated;

create trigger events_category_check before insert or update of category_id, format on public.events
  for each row execute function public.events_category_check();

-- ---------------------------------------------------------------------------
-- Merge: move every event of one category into another, then archive it
-- ---------------------------------------------------------------------------

create function public.merge_event_categories(p_from_id text, p_into_id text) returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_ws text := public.current_workspace_id();
  v_from public.event_categories;
  v_into public.event_categories;
  v_moved integer;
begin
  if not public.acts_as_leader() then
    raise exception 'Only your team''s leader and their deputies merge categories'
      using errcode = '42501';
  end if;
  select * into v_from from public.event_categories where id = p_from_id and workspace_id = v_ws;
  select * into v_into from public.event_categories where id = p_into_id and workspace_id = v_ws;
  if v_from.id is null or v_into.id is null then
    raise exception 'Category not found' using errcode = 'P0002';
  end if;
  if v_from.id = v_into.id then
    raise exception 'Pick a different category to merge into' using errcode = '22023';
  end if;
  if v_into.archived_at is not null then
    raise exception 'That category is archived' using errcode = '23514';
  end if;

  update public.events set category_id = v_into.id
   where category_id = v_from.id and workspace_id = v_ws;
  get diagnostics v_moved = row_count;

  update public.event_categories set archived_at = coalesce(archived_at, now())
   where id = v_from.id;
  return v_moved;
end $$;
comment on function public.merge_event_categories(text, text) is
  'Leaders and deputies: move every event of one category into another (in person if the other is in person only), then archive the first. Returns how many events moved.';
revoke execute on function public.merge_event_categories(text, text) from public, anon;
grant execute on function public.merge_event_categories(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Customers' missed events: their owner (and the owner's uplines) follow up
-- ---------------------------------------------------------------------------

-- The caller follows up this customer: they own them, or are an upline of
-- the owner (src/data/eventTypes/missed.ts missedAudience).
create function public.is_customer_upline(p_person_id text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
     where p.id = p_person_id
       and p.biz_class = 'customer'
       and p.workspace_id = public.current_workspace_id()
       and p.owner_id is not null
       and (p.owner_id = public.current_person_id() or public.is_upline_of(p.owner_id)))
$$;
revoke execute on function public.is_customer_upline(text) from public, anon;
grant execute on function public.is_customer_upline(text) to authenticated;

drop policy "uplines note a missed event" on public.missed_event_notes;
create policy "uplines note a missed event" on public.missed_event_notes
  for insert to authenticated
  with check (workspace_id = (select public.current_workspace_id())
              and (public.is_upline_of(person_id) or public.is_customer_upline(person_id)));

-- END ORIGINAL 20261016002000_event_categories.sql

-- BEGIN ORIGINAL 20261016002500_feedback.sql
-- In-app feedback: the "Feedback" button in the sidebar (client:
-- src/data/feedback, src/components/feedback, admin page at /settings/feedback).
--
-- A signed-in person describes a change they want and the app sends it with a
-- snapshot of the page they were looking at:
--
--  * public.feedback: one row per report. `message` is what they typed (1 to
--    2000 characters), `context` is a small JSON object the app fills in (page
--    path and search, page title, viewport, theme, user agent, brand slug, app
--    version, client time, sender name), `screenshot_path` is the object in the
--    `feedback` bucket (or null when the person removed the snapshot).
--  * storage bucket `feedback` (private): the snapshot, "<workspace_id>/<feedback_id>.jpg".
--
-- Who can do what:
--  * Any member inserts a report for themselves in their own workspace
--    (person_id and workspace_id must be theirs) and uploads the image into
--    their workspace's folder. They cannot set the status.
--  * The sender reads their own reports and images; nobody else on the team does.
--  * App admins (`app_admins`) read every report and image, in every
--    workspace, and change only `status` ('new' or 'done').
--  * Nobody deletes or edits a report's text; no policy or grant allows it.

create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  workspace_id text not null default public.current_workspace_id()
    references public.workspaces (id) on delete cascade,
  -- The sender. Set null if their person row is deleted; the report stays.
  person_id text default public.current_person_id()
    references public.people (id) on delete set null,
  message text not null
    constraint feedback_message_length check (char_length(btrim(message)) between 1 and 2000),
  context jsonb not null default '{}'::jsonb
    constraint feedback_context_object check (jsonb_typeof(context) = 'object')
    constraint feedback_context_size check (octet_length(context::text) <= 8000),
  screenshot_path text
    constraint feedback_screenshot_in_workspace
      check (screenshot_path is null or starts_with(screenshot_path, workspace_id || '/')),
  status text not null default 'new'
    constraint feedback_status_valid check (status in ('new', 'done')),
  created_at timestamptz not null default now()
);
comment on table public.feedback is
  'Change requests people send from the app, with a snapshot of the page (bucket `feedback`). Senders read their own; app admins read all and set status.';

create index feedback_created_idx on public.feedback (created_at desc);
create index feedback_person_idx on public.feedback (person_id);

alter table public.feedback enable row level security;

-- Send: a member, as themselves, in their own workspace.
create policy "members send their own feedback" on public.feedback
  for insert to authenticated
  with check (workspace_id = (select public.current_workspace_id())
              and person_id = (select public.current_person_id()));

-- Read: your own reports, or everything when you are an app admin.
create policy "senders read their own feedback" on public.feedback
  for select to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and person_id = (select public.current_person_id()));

create policy "app admins read all feedback" on public.feedback
  for select to authenticated
  using ((select public.is_app_admin()));

-- Triage: app admins flip the status (the column grant below limits the update to it).
create policy "app admins set feedback status" on public.feedback
  for update to authenticated
  using ((select public.is_app_admin()))
  with check ((select public.is_app_admin()));

revoke all on public.feedback from public, anon, authenticated;
grant select on public.feedback to authenticated;
grant insert (id, workspace_id, person_id, message, context, screenshot_path)
  on public.feedback to authenticated;
grant update (status) on public.feedback to authenticated;

-- ---------------------------------------------------------------------------
-- Storage: private `feedback` bucket, "<workspace_id>/<feedback_id>.jpg"
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feedback', 'feedback', false, 524288, array['image/jpeg', 'image/webp'])
on conflict (id) do nothing;

-- Upload: any member, into their workspace's folder.
create policy "feedback: members upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'feedback'
              and (storage.foldername(name))[1] = (select public.current_workspace_id()));

-- Read: the uploader, and app admins.
create policy "feedback: sender or admin reads" on storage.objects
  for select to authenticated
  using (bucket_id = 'feedback'
         and (owner_id = (select auth.uid())::text
              or (select public.is_app_admin())));

-- No update or delete policy: images are never replaced or removed by clients.

-- END ORIGINAL 20261016002500_feedback.sql

-- BEGIN ORIGINAL 20261017000100_stage_names.sql
-- Custom names for the pipelines' major stages (client: src/data/stageNames,
-- store `stageNames`, binding `stageNamesBinding`).
--
-- Each pipeline has four fixed top-level stages, known by key:
--   recruiting: contact, first_meeting, first_plan, registered
--   customer:   contact, first_meeting, first_sale, on_ditto
-- Their meaning, order and behaviour never change; only the name a person
-- sees can. Anyone who has a pipeline (not a candidate) names stages for
-- themselves, and their downline sees those names unless they set their own.
--
-- `stage_names` holds one row per person, pipeline and stage that the person
-- named. No row = "not set by me". The name a viewer sees for a stage is,
-- per pipeline and per stage independently:
--   1. their own row, if they have one; else
--   2. the row of the NEAREST person above them in the sponsor line
--      (sponsor by sponsor) who has one; else
--   3. the app's built-in name (the client's; the database stores none).
--
-- A person reads and writes only their own rows. Because a viewer must learn
-- the names set above them, by people whose rows (and sometimes whose profiles)
-- they can't read, `effective_stage_names()` walks the sponsor line for the
-- caller and returns the winning name per stage with who it comes from.

create table public.stage_names (
  person_id text not null default public.current_person_id()
    references public.people (id) on delete cascade,
  workspace_id text not null default public.current_workspace_id()
    references public.workspaces (id) on delete cascade,
  pipeline text not null,
  stage_key text not null,
  name text not null,
  updated_at timestamptz not null default now(),
  primary key (person_id, pipeline, stage_key),
  -- The stage key must be one of that pipeline's four.
  constraint stage_names_stage_valid check (
    (pipeline = 'recruiting' and stage_key in ('contact', 'first_meeting', 'first_plan', 'registered'))
    or (pipeline = 'customer' and stage_key in ('contact', 'first_meeting', 'first_sale', 'on_ditto'))),
  -- Trimmed, 1 to 30 characters, no control characters (line breaks, tabs).
  constraint stage_names_name_valid check (
    name = btrim(name) and char_length(name) between 1 and 30 and name !~ '[[:cntrl:]]')
);
comment on table public.stage_names is
  'A person''s own names for the major stages of the recruiting and customer pipelines; no row = not set by them.';
comment on column public.stage_names.stage_key is
  'The stage''s internal key (the milestone code): recruiting contact, first_meeting, first_plan, registered; customer contact, first_meeting, first_sale, on_ditto.';

create trigger stage_names_touch before update on public.stage_names
  for each row execute function public.touch_updated_at();

alter table public.stage_names enable row level security;

create policy "read own stage names" on public.stage_names
  for select to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and person_id = (select public.current_person_id()));
create policy "add own stage names" on public.stage_names
  for insert to authenticated
  with check (workspace_id = (select public.current_workspace_id())
              and person_id = (select public.current_person_id())
              and not (select public.is_candidate()));
create policy "change own stage names" on public.stage_names
  for update to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and person_id = (select public.current_person_id()))
  with check (workspace_id = (select public.current_workspace_id())
              and person_id = (select public.current_person_id()));
create policy "delete own stage names" on public.stage_names
  for delete to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and person_id = (select public.current_person_id()));

grant select, insert, update, delete on public.stage_names to authenticated;

-- The names the caller sees, one row per pipeline and stage that has a custom
-- name anywhere in their sponsor line: the caller's own, else the nearest
-- upline's. `p_include_own = false` leaves the caller's own rows out (what
-- they would inherit if they cleared theirs; the app uses it for the
-- placeholders in its rename dialog and combines it with the caller's own
-- rows). depth is 0 for the caller, 1 for their sponsor, and so on. The walk
-- stays in the caller's workspace, never visits a person twice (a sponsor
-- cycle ends it) and stops after 50 people.
create function public.effective_stage_names(p_include_own boolean default true)
returns table (
  pipeline text,
  stage_key text,
  name text,
  from_person_id text,
  from_person_name text,
  depth integer
)
language sql stable security definer set search_path = ''
as $$
  with recursive line (person_id, sponsor_id, d, seen) as (
    select p.id, p.sponsor_id, 0, array[p.id]
    from public.people p
    where p.id = public.current_person_id()
      and p.workspace_id = public.current_workspace_id()
    union all
    select s.id, s.sponsor_id, line.d + 1, line.seen || s.id
    from public.people s
    join line on s.id = line.sponsor_id
    where line.d < 49
      and s.workspace_id = public.current_workspace_id()
      and not s.id = any (line.seen)
  )
  select distinct on (n.pipeline, n.stage_key)
         n.pipeline, n.stage_key, n.name, line.person_id, who.name, line.d
  from line
  join public.stage_names n
    on n.person_id = line.person_id and n.workspace_id = public.current_workspace_id()
  join public.people who on who.id = line.person_id
  where p_include_own or line.d > 0
  order by n.pipeline, n.stage_key, line.d
$$;
comment on function public.effective_stage_names(boolean) is
  'For the caller: per pipeline and stage, the custom name they see (their own, else the nearest upline''s) and who set it. false leaves their own out.';

revoke execute on function public.effective_stage_names(boolean) from public, anon;
grant execute on function public.effective_stage_names(boolean) to authenticated;

-- END ORIGINAL 20261017000100_stage_names.sql

-- BEGIN ORIGINAL 20261018000100_invite_existing_person.sql
-- Invite a person who is already on the roster to sign in to THEIR record.
--
-- Until now accept_invite() always created a new person, so someone added as a
-- record first could only get a login by becoming a duplicate. An invite can
-- now be bound to a person (invites.person_id): accepting it attaches the
-- signed-in user to that person (members.user_id) and creates nothing new.
--
--  * invites.person_id: nullable, references people, on delete cascade. A
--    person-bound invite takes its sponsor, stage and name from the person
--    (trigger), so sponsor_person_id may now be null (a leader has no sponsor).
--  * At most one unused invite per person (unique partial index); creating a
--    new one withdraws the previous unused one (trigger).
--  * can_invite_person(): the rule for who may invite an existing person.
--  * accept_invite / get_invite replaced; ordinary invites behave as before.
--  * An unused invite is withdrawn when the person's registration is undone.

-- ---------------------------------------------------------------------------
-- invites: person-bound invites
-- ---------------------------------------------------------------------------

alter table public.invites
  add column person_id text references public.people (id) on delete cascade;
alter table public.invites alter column sponsor_person_id drop not null;
alter table public.invites
  add constraint invites_sponsor_or_person check (sponsor_person_id is not null or person_id is not null),
  add constraint invites_person_has_email check (person_id is null or nullif(btrim(email), '') is not null);

comment on column public.invites.person_id is
  'Set when the invite is for an existing person: accept_invite(token) signs the user in to that person instead of creating one. Sponsor, stage and name then come from the person.';

create index invites_person_idx on public.invites (person_id) where person_id is not null;
-- At most one unused invite per person (expiry is not part of the index: a new
-- invite withdraws the old unused one, see invites_for_person below).
create unique index invites_one_open_per_person_idx on public.invites (person_id)
  where person_id is not null and used_at is null;

-- ---------------------------------------------------------------------------
-- Who may invite an existing person
-- ---------------------------------------------------------------------------

-- Same rule as creating an ordinary invite (not a candidate, and the person is
-- someone the caller can see), and in addition: the person is in the caller's
-- own downline, or the caller is a leader (or a deputy acting for one). Never
-- yourself, never a customer, never someone who already has a login.
create function public.can_invite_person(p_person_id text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.people p
    where p.id = p_person_id
      and p.workspace_id = public.current_workspace_id()
      and p.biz_class <> 'customer'
      and p.id <> public.current_person_id()
      and not public.is_candidate()
      and p.id in (select public.visible_person_ids())
      and (public.acts_as_leader()
           or p.id in (select public.downline_ids(public.current_person_id())))
      and not exists (
        select 1 from public.members m
        where m.person_id = p.id and m.workspace_id = p.workspace_id and m.user_id is not null
      )
  )
$$;
revoke execute on function public.can_invite_person(text) from public, anon;
grant execute on function public.can_invite_person(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------

-- The ordinary-invite insert rule applies to ordinary invites only.
alter policy "invite into your team" on public.invites
  with check (
    person_id is null
    and workspace_id = (select public.current_workspace_id())
    and not (select public.is_candidate())
    and created_by = (select public.current_person_id())
    and sponsor_person_id in (select public.visible_person_ids())
    and exists (select 1 from public.people p
                where p.id = sponsor_person_id and p.biz_class in ('apprentice', 'ibo'))
  );

create policy "invite an existing person" on public.invites
  for insert to authenticated
  with check (
    person_id is not null
    and workspace_id = (select public.current_workspace_id())
    and created_by = (select public.current_person_id())
    and public.can_invite_person(person_id)
  );

-- Anyone who may invite the person sees (and may withdraw) their open invite,
-- not only whoever created it.
create policy "read invites for people you may invite" on public.invites
  for select to authenticated
  using (
    person_id is not null
    and workspace_id = (select public.current_workspace_id())
    and public.can_invite_person(person_id)
  );

create policy "withdraw invites for people you may invite" on public.invites
  for delete to authenticated
  using (
    person_id is not null
    and used_at is null
    and workspace_id = (select public.current_workspace_id())
    and public.can_invite_person(person_id)
  );

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- A person-bound invite takes sponsor, stage and name from the person, and
-- replaces the person's previous unused invite. (If the person can't be found
-- the row is left alone: the insert policy then refuses it.)
create function public.invites_for_person() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_person public.people;
begin
  if new.person_id is null then
    return new;
  end if;
  select * into v_person from public.people p where p.id = new.person_id;
  if not found or v_person.workspace_id <> new.workspace_id then
    return new;
  end if;
  new.sponsor_person_id := v_person.sponsor_id;
  new.stage := case when v_person.biz_class = 'customer' then new.stage else v_person.biz_class end;
  new.name := v_person.name;
  new.email := btrim(new.email);
  delete from public.invites i where i.person_id = new.person_id and i.used_at is null;
  return new;
end $$;
revoke execute on function public.invites_for_person() from public, anon, authenticated;

create trigger invites_for_person before insert on public.invites
  for each row execute function public.invites_for_person();

-- Undoing a registration puts the person back to prospect: their unused sign-in
-- invite goes with it.
create function public.people_withdraw_invites() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.invites i where i.person_id = new.id and i.used_at is null;
  return new;
end $$;
revoke execute on function public.people_withdraw_invites() from public, anon, authenticated;

create trigger people_withdraw_invites after update of biz_class on public.people
  for each row
  when (old.biz_class in ('apprentice', 'ibo') and new.biz_class = 'prospect')
  execute function public.people_withdraw_invites();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

create function public.mask_email(p_email text) returns text
language sql immutable set search_path = ''
as $$
  select case
    when p_email is null then null
    when position('@' in p_email) < 2 then '***'
    else left(p_email, 1) || '***' || substr(p_email, position('@' in p_email))
  end
$$;

-- Preview before signing in (anon may call this). Same fields as before plus
-- `for_person` (the invite is for someone already on the roster). For those,
-- `name` is the invitee's own name and `email` only a masked hint.
drop function public.get_invite(text);
create function public.get_invite(p_token text)
returns table (
  workspace_id text,
  workspace_name text,
  sponsor_name text,
  stage text,
  name text,
  email text,
  expires_at timestamptz,
  is_valid boolean,
  for_person boolean
)
language sql stable security definer set search_path = ''
as $$
  select i.workspace_id, w.name, s.name, i.stage, i.name,
         case when i.person_id is null then i.email else public.mask_email(i.email) end,
         i.expires_at,
         i.used_at is null and i.expires_at > now()
           and (i.person_id is null
                or not exists (select 1 from public.members m
                               where m.person_id = i.person_id and m.workspace_id = i.workspace_id
                                 and m.user_id is not null)),
         i.person_id is not null
  from public.invites i
  join public.workspaces w on w.id = i.workspace_id
  left join public.people s on s.id = i.sponsor_person_id
  where i.token = p_token
$$;
revoke execute on function public.get_invite(text) from public;
grant execute on function public.get_invite(text) to anon, authenticated;

-- Accept an invite as the signed-in user. An ordinary invite creates their
-- person under the sponsor (stage from the invite) and a member row; a
-- person-bound one signs them in to the existing person (member row updated, or
-- created when the person has none). Returns the person id.
create or replace function public.accept_invite(p_token text) returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_inv public.invites;
  v_email text;
  v_meta jsonb;
  v_name text;
  v_today date;
  v_person text;
  v_confirmed timestamptz;
  v_target public.people;
begin
  if v_uid is null then
    raise exception 'Sign in before accepting an invite' using errcode = '28000';
  end if;

  select * into v_inv from public.invites i where i.token = p_token for update;
  if not found then
    raise exception 'Invite not found' using errcode = 'P0002';
  end if;
  if v_inv.used_at is not null then
    raise exception 'This invite has already been used' using errcode = '22023';
  end if;
  if v_inv.expires_at <= now() then
    raise exception 'This invite has expired' using errcode = '22023';
  end if;
  if exists (select 1 from public.members m where m.user_id = v_uid and m.workspace_id = v_inv.workspace_id) then
    raise exception 'You are already a member of this team' using errcode = '23505';
  end if;

  select u.email, u.raw_user_meta_data, u.email_confirmed_at
    into v_email, v_meta, v_confirmed from auth.users u where u.id = v_uid;

  if v_inv.person_id is not null then
    -- Sign in to the existing person.
    select * into v_target from public.people p
     where p.id = v_inv.person_id and p.workspace_id = v_inv.workspace_id for update;
    if not found then
      raise exception 'Person not found: they are no longer on the team' using errcode = 'P0002';
    end if;
    if exists (select 1 from public.members m
               where m.person_id = v_target.id and m.workspace_id = v_target.workspace_id
                 and m.user_id is not null) then
      raise exception 'This person already has a sign-in' using errcode = '22023';
    end if;
    -- The inviter confirmed this address: only that account may claim the record.
    if v_confirmed is null then
      raise exception 'Confirm your email address first' using errcode = '42501';
    end if;
    if lower(btrim(coalesce(v_email, ''))) <> lower(btrim(v_inv.email)) then
      raise exception 'This invite was sent to a different email address' using errcode = '42501';
    end if;

    update public.members m set user_id = v_uid
     where m.workspace_id = v_target.workspace_id and m.person_id = v_target.id and m.user_id is null;
    if not found then
      insert into public.members (workspace_id, person_id, user_id, role)
      values (v_target.workspace_id, v_target.id, v_uid, 'member');
    end if;

    if nullif(btrim(coalesce(v_target.email, '')), '') is null then
      update public.people p set email = v_inv.email where p.id = v_target.id;
    end if;

    update public.invites set used_at = now(), used_by = v_uid where id = v_inv.id;

    insert into public.activity (workspace_id, actor_name, actor_id, entity_type, entity_id,
                                 related_person_id, kind, summary)
    values (v_target.workspace_id, v_target.name, v_target.id, 'person', v_target.id, v_target.id, 'created',
            'Joined from an invite link');

    return v_target.id;
  end if;

  v_name := coalesce(nullif(trim(v_inv.name), ''), nullif(trim(v_meta ->> 'name'), ''),
                     nullif(trim(v_meta ->> 'full_name'), ''), split_part(coalesce(v_email, 'New member'), '@', 1));
  v_today := public.workspace_today(v_inv.workspace_id);

  insert into public.people (workspace_id, name, email, biz_class, pipeline_stage, sponsor_id,
                             joined_date, business_start_date, stage_history)
  values (v_inv.workspace_id, v_name, coalesce(v_inv.email, v_email), v_inv.stage, v_inv.stage,
          v_inv.sponsor_person_id, v_today,
          case when v_inv.stage <> 'prospect' then v_today end,
          jsonb_build_array(jsonb_build_object('stage', v_inv.stage, 'at', now())))
  returning id into v_person;

  insert into public.members (workspace_id, person_id, user_id, role)
  values (v_inv.workspace_id, v_person, v_uid, 'member');

  update public.invites set used_at = now(), used_by = v_uid where id = v_inv.id;

  insert into public.activity (workspace_id, actor_name, actor_id, entity_type, entity_id,
                               related_person_id, kind, summary)
  values (v_inv.workspace_id, v_name, v_person, 'person', v_person, v_person, 'created',
          'Joined from an invite link');

  return v_person;
end;
$$;

-- END ORIGINAL 20261018000100_invite_existing_person.sql

-- BEGIN ORIGINAL 20261019000100_team_appearance.sql
-- Team appearance: the team's leader chooses the background picture, glass on or
-- off, the logo and three colours for the whole team (client: Settings > Team >
-- Appearance, src/data/teamLook, src/lib/teamLook.ts).
--
-- Where the choices live: the `workspaces` row, one typed column per choice.
--   background_mode  'default' (the brand's own picture), 'none' or 'picture'
--   background_path  the picture in the `team-appearance` bucket; set exactly when the mode is 'picture'
--   glass            true / false; null = the brand's own. Only meaningful over a picture
--   logo_path        the logo in the same bucket (was `logo_url`, which nothing used)
--   colors           {"main": "#rrggbb", "highlight": ..., "sidebar": ...}, any subset (was an unused palette)
-- The old `logo_url` held URLs nobody wrote and `colors` an unused example
-- palette; both are cleared here (the demo seed no longer writes them) and
-- take their new meaning, so no column is left half used.
--
-- Who can do what:
--  * Every member of the workspace reads the columns (they need them to render
--    the app); nobody outside the workspace, and nobody signed out, does.
--  * Nobody writes them directly: UPDATE on `workspaces` is limited to `name`
--    and `timezone` by a column grant. The only way is set_workspace_appearance(),
--    SECURITY DEFINER with an empty search_path, which checks that the caller is
--    the workspace LEADER (not a deputy, moderator or member) and validates
--    every value; the check constraints below say the same again.
--  * Pictures: public bucket `team-appearance`, `<workspace id>/(bg|logo)-<32 hex>.<ext>`.
--    Only the leader uploads, lists and removes, in their own workspace folder.

-- Old, unused values would not pass the new checks.
update public.workspaces set colors = '{}'::jsonb where colors <> '{}'::jsonb;
update public.workspaces set logo_url = null where logo_url is not null;

alter table public.workspaces rename column logo_url to logo_path;

-- ---------------------------------------------------------------------------
-- Value rules (immutable, so check constraints and the function share them)
-- ---------------------------------------------------------------------------

-- `<workspace id>/<file>` where the file name is generated: bg-<32 hex>.webp|jpg or logo-<32 hex>.png|webp.
-- No other folder, no traversal, no other extension (never svg).
create function public.team_look_path_ok(p_workspace text, p_path text, p_kind text)
returns boolean
language sql immutable parallel safe set search_path = ''
as $fn$
  select p_path is not null
    and p_kind in ('bg', 'logo')
    and p_workspace ~ '^[A-Za-z0-9_-]{1,64}$'
    and starts_with(p_path, p_workspace || '/')
    and substr(p_path, length(p_workspace) + 2) ~
      (case p_kind
         when 'bg' then '^bg-[0-9a-f]{32}\.(webp|jpg)$'
         else '^logo-[0-9a-f]{32}\.(png|webp)$'
       end)
$fn$;

-- An object with only the keys main, highlight and sidebar, each a lower-case #rrggbb.
create function public.team_colors_valid(p_colors jsonb)
returns boolean
language sql immutable parallel safe set search_path = ''
as $fn$
  select p_colors is not null
    and jsonb_typeof(p_colors) = 'object'
    and (p_colors - 'main' - 'highlight' - 'sidebar') = '{}'::jsonb
    and not exists (
      select 1 from jsonb_each(p_colors) e
      where jsonb_typeof(e.value) <> 'string' or (e.value #>> '{}') !~ '^#[0-9a-f]{6}$'
    )
$fn$;

alter table public.workspaces
  add column background_mode text not null default 'default',
  add column background_path text,
  add column glass boolean;

alter table public.workspaces
  add constraint workspaces_background_mode_valid
    check (background_mode in ('default', 'none', 'picture')),
  add constraint workspaces_background_path_valid
    check ((background_mode = 'picture') = (background_path is not null)
           and (background_path is null or public.team_look_path_ok(id, background_path, 'bg'))),
  add constraint workspaces_logo_path_valid
    check (logo_path is null or public.team_look_path_ok(id, logo_path, 'logo')),
  add constraint workspaces_colors_valid
    check (public.team_colors_valid(colors));

comment on column public.workspaces.background_mode is
  'Team background: default (the brand''s own picture), none, or picture (background_path). Written only by set_workspace_appearance().';
comment on column public.workspaces.background_path is
  'The team''s own background picture in the public team-appearance bucket, set exactly when background_mode is picture.';
comment on column public.workspaces.glass is
  'Glass look over the picture: true, false, or null for the brand''s own.';
comment on column public.workspaces.logo_path is
  'The team''s logo in the public team-appearance bucket; null shows the brand''s mark.';
comment on column public.workspaces.colors is
  'The team''s own colours {"main","highlight","sidebar"} as lower-case #rrggbb (any subset); {} = the brand''s own. The app derives every readable variant from them.';
comment on table public.workspaces is
  'A team. Its name, timezone and look (background, glass, logo, colors); the look is written only by set_workspace_appearance().';

-- No direct writes to the look: leaders keep UPDATE on name and timezone only.
revoke update on public.workspaces from public, anon, authenticated;
grant update (name, timezone) on public.workspaces to authenticated;

-- ---------------------------------------------------------------------------
-- set_workspace_appearance(): the only way to change the look
-- ---------------------------------------------------------------------------
-- Replaces the whole look (an argument left out is "default": calling it with
-- no arguments resets everything). Returns the picture paths the team no longer
-- uses, so the client can remove those files from the bucket.
-- Errors: 42501 not the leader, 22023 a value is not allowed, P0002 the file is not in the bucket.
create function public.set_workspace_appearance(
  p_background text default 'default',
  p_background_path text default null,
  p_glass boolean default null,
  p_logo_path text default null,
  p_main text default null,
  p_highlight text default null,
  p_sidebar text default null
) returns text[]
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_ws text := public.current_workspace_id();
  v_old public.workspaces%rowtype;
  v_colors jsonb := '{}'::jsonb;
begin
  if auth.uid() is null or v_ws is null or not public.is_leader() then
    raise exception 'Only the team leader can change the team look.' using errcode = '42501';
  end if;
  if p_background is null or p_background not in ('default', 'none', 'picture') then
    raise exception 'Background must be default, none or picture.' using errcode = '22023';
  end if;
  if (p_background = 'picture') <> (p_background_path is not null) then
    raise exception 'A picture background needs a picture, and only then.' using errcode = '22023';
  end if;
  if p_background_path is not null and not public.team_look_path_ok(v_ws, p_background_path, 'bg') then
    raise exception 'That background picture path is not allowed.' using errcode = '22023';
  end if;
  if p_logo_path is not null and not public.team_look_path_ok(v_ws, p_logo_path, 'logo') then
    raise exception 'That logo path is not allowed.' using errcode = '22023';
  end if;
  if p_main is not null then
    if p_main !~ '^#[0-9a-f]{6}$' then
      raise exception 'Main must be a colour like #336699.' using errcode = '22023';
    end if;
    v_colors := v_colors || jsonb_build_object('main', p_main);
  end if;
  if p_highlight is not null then
    if p_highlight !~ '^#[0-9a-f]{6}$' then
      raise exception 'Highlight must be a colour like #336699.' using errcode = '22023';
    end if;
    v_colors := v_colors || jsonb_build_object('highlight', p_highlight);
  end if;
  if p_sidebar is not null then
    if p_sidebar !~ '^#[0-9a-f]{6}$' then
      raise exception 'Sidebar must be a colour like #336699.' using errcode = '22023';
    end if;
    v_colors := v_colors || jsonb_build_object('sidebar', p_sidebar);
  end if;
  -- A path must be a file that was uploaded (by the leader: only they may insert into the folder).
  if p_background_path is not null and not exists (
    select 1 from storage.objects o where o.bucket_id = 'team-appearance' and o.name = p_background_path
  ) then
    raise exception 'The background picture was not uploaded.' using errcode = 'P0002';
  end if;
  if p_logo_path is not null and not exists (
    select 1 from storage.objects o where o.bucket_id = 'team-appearance' and o.name = p_logo_path
  ) then
    raise exception 'The logo was not uploaded.' using errcode = 'P0002';
  end if;

  select * into v_old from public.workspaces where id = v_ws for update;
  update public.workspaces
     set background_mode = p_background,
         background_path = p_background_path,
         glass = p_glass,
         logo_path = p_logo_path,
         colors = v_colors
   where id = v_ws;

  return array(
    select distinct p
    from unnest(array[v_old.background_path, v_old.logo_path]) as p
    where p is not null
      and p is distinct from p_background_path
      and p is distinct from p_logo_path
  );
end
$fn$;

revoke execute on function public.set_workspace_appearance(text, text, boolean, text, text, text, text)
  from public, anon;
grant execute on function public.set_workspace_appearance(text, text, boolean, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Storage: the `team-appearance` bucket
-- ---------------------------------------------------------------------------
-- PUBLIC on purpose. These are decorative pictures that every member's browser
-- loads on every page, as a CSS background and an <img>, and the look is painted
-- from a local cache before any data arrives: a signed URL would expire under
-- that cache and would have to be renewed by a timer. A public URL never
-- changes, caches for good, and cannot be listed or guessed: the path is the
-- workspace id plus a random 128-bit file name, only the leader can list the
-- folder (the policies below), and a replaced or reset picture is deleted.
-- Size limit 1 MB (the app shrinks to about 600 KB / 200 KB first); PNG, JPEG, WebP only.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('team-appearance', 'team-appearance', true, 1048576,
        array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

-- Upload: the leader, into their own workspace's folder, with a generated file name.
create policy "team appearance: leader uploads" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'team-appearance'
              and (select public.is_leader())
              and (storage.foldername(name))[1] = (select public.current_workspace_id())
              and (public.team_look_path_ok((select public.current_workspace_id()), name, 'bg')
                   or public.team_look_path_ok((select public.current_workspace_id()), name, 'logo')));

-- List and remove: the leader, their own folder only. Everyone else reads a picture
-- through its public URL and cannot list the bucket.
create policy "team appearance: leader lists" on storage.objects
  for select to authenticated
  using (bucket_id = 'team-appearance'
         and (select public.is_leader())
         and (storage.foldername(name))[1] = (select public.current_workspace_id()));

create policy "team appearance: leader removes" on storage.objects
  for delete to authenticated
  using (bucket_id = 'team-appearance'
         and (select public.is_leader())
         and (storage.foldername(name))[1] = (select public.current_workspace_id()));

-- No update policy: file names are never reused, a new picture is a new file.

-- END ORIGINAL 20261019000100_team_appearance.sql

-- BEGIN ORIGINAL 20261020000100_recurring_events.sql
-- Repeating events (client: src/data/recurrence).
--
-- An event can repeat with no end, the way calendar apps do it. The design:
--
--  * Every occurrence is a real row in `events` with its own id, so attendance, answers, rosters,
--    logistics, follow-ups, chat posts and counts keep working per session, unchanged.
--  * `event_series` holds the rule (frequency, first date, last date, dates deleted on their own) and
--    what a new occurrence is made from. Occurrences point at it with `events.series_id`, and are
--    identified in it by `events.series_date`, the date of their place in the rule (it never changes,
--    even when the event itself is moved).
--  * Exactly one occurrence per series date: a unique index on (series_id, series_date), and every
--    function that makes or re-plans occurrences first locks the series row.
--  * An occurrence deleted on its own keeps its date in `event_series.skipped` (a trigger does it, so
--    even a client that doesn't know about series can't bring it back), and a field changed on one
--    occurrence is remembered in `events.series_overrides` (a trigger, for the same reason).
--  * A series is kept filled ahead by `topup_event_series()`, which the app calls when someone signed
--    in loads events (no scheduled job: the earlier migrations only use pg_cron when it happens to be
--    installed, and an idle team gets its occurrences as soon as anyone opens the app).
--  * Generated occurrences carry the series creator in `created_by`, so they are editable by the same
--    people as if the creator had added them by hand, whoever's browser triggered the top-up.
--
-- Additive only: a new table, three new nullable columns on `events`, new functions and triggers.
-- Existing events don't repeat; a client that doesn't know about series keeps working.

-- ---------------------------------------------------------------------------
-- Date arithmetic (the same rules as src/data/recurrence/rule.ts; both are tested against the
-- same table of cases, src/data/recurrence/cases.ts)
-- ---------------------------------------------------------------------------

-- The nth occurrence (0 = the first date) of a rule. Monthly on a day the month lacks is the last day
-- of the month; monthly on the fifth weekday of a month that has only four is the last such weekday.
create function public.series_nth_date(p_freq text, p_anchor date, p_n integer) returns date
language plpgsql immutable set search_path = ''
as $$
declare
  v_first date;
  v_last date;
  v_day integer;
begin
  if p_n < 0 then
    raise exception 'n can''t be negative' using errcode = '22023';
  end if;
  if p_freq = 'daily' then
    return p_anchor + p_n;
  elsif p_freq = 'weekly' then
    return p_anchor + 7 * p_n;
  elsif p_freq = 'biweekly' then
    return p_anchor + 14 * p_n;
  elsif p_freq in ('monthly_date', 'monthly_weekday') then
    v_first := (make_date(extract(year from p_anchor)::integer, extract(month from p_anchor)::integer, 1)
                + make_interval(months => p_n))::date;
    v_last := ((v_first + interval '1 month')::date) - 1;
    if p_freq = 'monthly_date' then
      return least(v_first + (extract(day from p_anchor)::integer - 1), v_last);
    end if;
    v_day := ((extract(dow from p_anchor)::integer - extract(dow from v_first)::integer + 7) % 7)
             + 7 * ((extract(day from p_anchor)::integer - 1) / 7);
    if v_first + v_day > v_last then
      v_day := v_day - 7;
    end if;
    return v_first + v_day;
  end if;
  raise exception 'Unknown repeat: %', p_freq using errcode = '22023';
end $$;

-- The shortest gap, in days, between two occurrences of a rule.
create function public.series_period_days(p_freq text) returns integer
language sql immutable set search_path = ''
as $$
  select case p_freq when 'daily' then 1 when 'weekly' then 7 when 'biweekly' then 14 else 28 end
$$;

-- Whether a date is one of the rule's occurrences.
create function public.series_is_slot(p_freq text, p_anchor date, p_date date) returns boolean
language plpgsql immutable set search_path = ''
as $$
declare
  v_d date;
  n integer := 0;
begin
  if p_date < p_anchor then
    return false;
  end if;
  while n < 5000 loop
    v_d := public.series_nth_date(p_freq, p_anchor, n);
    if v_d = p_date then
      return true;
    elsif v_d > p_date then
      return false;
    end if;
    n := n + 1;
  end loop;
  return false;
end $$;

-- ---------------------------------------------------------------------------
-- The series
-- ---------------------------------------------------------------------------

create table public.event_series (
  id text primary key default gen_random_uuid()::text,
  workspace_id text not null default public.current_workspace_id()
    references public.workspaces (id) on delete cascade,
  -- Who made the series; every occurrence is created as theirs (edit rights follow created_by).
  created_by text references public.people (id) on delete set null,
  freq text not null
    check (freq in ('daily', 'weekly', 'biweekly', 'monthly_date', 'monthly_weekday')),
  -- The first occurrence's date: where the rule starts counting.
  starts_on date not null,
  -- The last date an occurrence may fall on; null = never ends.
  ends_on date,
  -- Dates whose occurrence was deleted on its own: they are not made again.
  skipped date[] not null default '{}',
  -- What a new occurrence is made from.
  name text not null check (length(btrim(name)) > 0),
  category_id text not null references public.event_categories (id) on delete restrict,
  location text,
  notes text,
  format text not null default 'in_person' check (format in ('in_person', 'virtual', 'both')),
  ticket_url text
    check (ticket_url is null or (ticket_url ~* '^https?://[^\s]+$' and length(ticket_url) <= 2000)),
  -- Days an occurrence runs past its first day (0 = a one-day event).
  length_days integer not null default 0 check (length_days between 0 and 366),
  created_at timestamptz not null default now()
);
create index event_series_workspace_idx on public.event_series (workspace_id);
comment on table public.event_series is
  'The rule of a repeating event and what each new occurrence is made from. Read by the team; made and changed only by the series functions (no direct writes).';

alter table public.event_series enable row level security;

create policy "read event series" on public.event_series
  for select to authenticated
  using (workspace_id = (select public.current_workspace_id()));

-- No insert, update or delete policy and no table privilege besides select: a series is made and changed
-- only by the security definer functions below, which check who may, and is never deleted by a client.
revoke all on public.event_series from public, anon, authenticated;
grant select on public.event_series to authenticated;

alter table public.events
  add column series_id text references public.event_series (id) on delete set null,
  add column series_date date,
  add column series_overrides text[];
comment on column public.events.series_id is 'The series this event is one occurrence of; null for an event that doesn''t repeat.';
comment on column public.events.series_date is 'The date of this occurrence''s place in its series; stays when the event itself is moved.';
comment on column public.events.series_overrides is 'Columns changed on this occurrence alone: a later "this and following" edit from an earlier occurrence leaves them as they are.';

-- Exactly one occurrence per series date.
create unique index events_series_slot_key on public.events (series_id, series_date)
  where series_id is not null;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The series functions set this while they work, so the triggers below let their own changes through.
create function public.series_internal_begin() returns text
language plpgsql set search_path = ''
as $$
declare
  v_prev text := coalesce(current_setting('app.series_internal', true), '');
begin
  perform set_config('app.series_internal', 'on', true);
  return v_prev;
end $$;

create function public.series_internal_end(p_prev text) returns void
language plpgsql set search_path = ''
as $$
begin
  perform set_config('app.series_internal', coalesce(p_prev, ''), true);
end $$;

-- Who may edit events: the same as the policies on public.events (the creator, a leader or moderator,
-- a deputy).
create function public.may_edit_events(p_created_by text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(p_created_by = public.current_person_id(), false)
      or public.is_moderator_or_leader()
      or public.is_deputy()
$$;

-- Whether anything hangs off an event: attendance, travel and logistics, shared costs, follow-up notes,
-- a library talk linked to it, a chat post about it. Such an occurrence is never thrown away when a
-- series is planned again.
create function public.event_has_dependents(p_event_id text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.attendances a where a.event_id = p_event_id)
      or exists (select 1 from public.logistics l where l.event_id = p_event_id)
      or exists (select 1 from public.shared_costs c where c.event_id = p_event_id)
      or exists (select 1 from public.missed_event_notes n where n.event_id = p_event_id)
      or exists (select 1 from public.library_items i where i.event_id = p_event_id)
      or exists (select 1 from public.messages m
                  where m.card ->> 'type' = 'event' and m.card ->> 'eventId' = p_event_id
                    and m.deleted_at is null)
$$;

-- ---------------------------------------------------------------------------
-- Triggers on events
-- ---------------------------------------------------------------------------

-- A client can't make, move or detach occurrences by hand (only the series functions do). A change to
-- one occurrence is remembered on it, so it is never overwritten by an edit from an earlier occurrence.
create function public.events_series_guard() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_fields text[];
begin
  if coalesce(current_setting('app.series_internal', true), '') = 'on' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.series_id is not null or new.series_date is not null or new.series_overrides is not null then
      raise exception 'Occurrences of a repeating event are made by their series'
        using errcode = '42501';
    end if;
    return new;
  end if;
  if new.series_id is distinct from old.series_id
     or new.series_date is distinct from old.series_date
     or new.series_overrides is distinct from old.series_overrides then
    raise exception 'The series of an event can''t be changed directly' using errcode = '42501';
  end if;
  if old.series_id is not null then
    v_fields := array_remove(array[
      case when new.name is distinct from old.name then 'name' end,
      case when new.category_id is distinct from old.category_id then 'category_id' end,
      case when new.location is distinct from old.location then 'location' end,
      case when new.notes is distinct from old.notes then 'notes' end,
      case when new.format is distinct from old.format then 'format' end,
      case when new.ticket_url is distinct from old.ticket_url then 'ticket_url' end,
      case when new.date is distinct from old.date then 'date' end,
      case when new.end_date is distinct from old.end_date then 'end_date' end
    ]::text[], null);
    if cardinality(v_fields) > 0 then
      new.series_overrides := array(
        select distinct f from unnest(coalesce(old.series_overrides, '{}'::text[]) || v_fields) f
         order by f);
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.events_series_guard() from public, anon, authenticated;

create trigger events_series_guard before insert or update on public.events
  for each row execute function public.events_series_guard();

-- An occurrence deleted on its own never comes back: its date is kept on the series. (The series
-- functions that delete occurrences stop or re-plan the series themselves and skip this.)
create function public.events_series_tombstone() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.series_id is not null and old.series_date is not null
     and coalesce(current_setting('app.series_internal', true), '') <> 'on' then
    update public.event_series
       set skipped = array(select distinct d from unnest(array_append(skipped, old.series_date)) d order by d)
     where id = old.series_id and not (old.series_date = any(skipped));
  end if;
  return old;
end $$;
revoke execute on function public.events_series_tombstone() from public, anon, authenticated;

create trigger events_series_tombstone before delete on public.events
  for each row execute function public.events_series_tombstone();

-- ---------------------------------------------------------------------------
-- Filling a series ahead
-- ---------------------------------------------------------------------------

-- Makes the occurrences a series is missing for p_today: every date from today on within 8 weeks, and
-- at least the next 2; never a date in the past, a skipped date or one after the end. Locks the series
-- row, so two callers at once take turns, and each date has its unique index besides: whoever is second
-- finds the occurrence there and makes nothing. Returns the occurrences it made.
create function public.series_fill(p_series_id text, p_today date) returns setof public.events
language plpgsql security definer set search_path = ''
as $$
declare
  s public.event_series;
  n integer := 0;
  v_slot date;
  v_wanted integer := 0;
  v_horizon date := p_today + 56;
  v_row public.events;
  v_prev text;
begin
  select * into s from public.event_series where id = p_series_id for update;
  if s.id is null or (s.ends_on is not null and s.ends_on < p_today) then
    return;
  end if;
  v_prev := public.series_internal_begin();
  while n < 5000 loop
    v_slot := public.series_nth_date(s.freq, s.starts_on, n);
    n := n + 1;
    exit when s.ends_on is not null and v_slot > s.ends_on;
    continue when v_slot < p_today;
    exit when v_slot > v_horizon and v_wanted >= 2;
    continue when v_slot = any(s.skipped);
    v_wanted := v_wanted + 1;
    insert into public.events
      (workspace_id, name, category_id, date, end_date, location, notes, format, ticket_url,
       created_by, series_id, series_date)
    values
      (s.workspace_id, s.name, s.category_id, v_slot,
       case when s.length_days > 0 then v_slot + s.length_days end,
       s.location, s.notes, s.format, s.ticket_url, s.created_by, s.id, v_slot)
    on conflict (series_id, series_date) where series_id is not null do nothing
    returning * into v_row;
    if found then
      return next v_row;
    end if;
  end loop;
  perform public.series_internal_end(v_prev);
  return;
end $$;
revoke execute on function public.series_fill(text, date) from public, anon, authenticated;

-- Tops up every open series of the caller's workspace. Any signed-in member may call it: it only makes
-- what the rules already say, always as the series' creator. A series that can't be filled (for
-- example its category was archived) is left and the others go on.
create function public.topup_event_series() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ws text := public.current_workspace_id();
  v_today date;
  v_prev text;
  v_id text;
  r public.events;
  v_events jsonb := '[]'::jsonb;
begin
  if v_ws is null then
    raise exception 'Not signed in to a team' using errcode = '42501';
  end if;
  v_today := public.workspace_today(v_ws);
  v_prev := public.series_internal_begin();
  for v_id in
    select id from public.event_series
     where workspace_id = v_ws and (ends_on is null or ends_on >= v_today)
     order by id
  loop
    begin
      for r in select * from public.series_fill(v_id, v_today) loop
        v_events := v_events || to_jsonb(r);
      end loop;
    exception when others then
      raise warning 'event series % could not be filled: %', v_id, sqlerrm;
    end;
  end loop;
  perform public.series_internal_end(v_prev);
  return jsonb_build_object('events', v_events);
end $$;
comment on function public.topup_event_series() is
  'Makes the occurrences the caller''s team''s repeating events are missing (8 weeks ahead, at least the next 2). Safe to call any time and from any number of clients at once.';
revoke execute on function public.topup_event_series() from public, anon;
grant execute on function public.topup_event_series() to authenticated;

-- ---------------------------------------------------------------------------
-- Making an event repeat, and "this and following"
-- ---------------------------------------------------------------------------

-- The first date of the event becomes the series' first occurrence and the next ones are made. Who may:
-- whoever may edit the event (its creator, a leader or moderator, a deputy); a new event is made by
-- anyone but a candidate, and its creator is whoever made it.
create function public.make_event_repeat(p_event_id text, p_freq text, p_ends_on date) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ws text := public.current_workspace_id();
  e public.events;
  v_id text;
  v_prev text;
  r public.events;
  v_events jsonb := '[]'::jsonb;
begin
  if v_ws is null then
    raise exception 'Not signed in to a team' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id and workspace_id = v_ws for update;
  if e.id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;
  if not public.may_edit_events(e.created_by) then
    raise exception 'You can''t change this event' using errcode = '42501';
  end if;
  if e.series_id is not null then
    raise exception 'That event already repeats' using errcode = '22023';
  end if;
  if p_freq is null or p_freq not in ('daily', 'weekly', 'biweekly', 'monthly_date', 'monthly_weekday') then
    raise exception 'Unknown repeat' using errcode = '22023';
  end if;
  if p_ends_on is not null and p_ends_on < e.date then
    raise exception 'The series can''t end before it starts' using errcode = '22023';
  end if;
  if coalesce(e.end_date - e.date, 0) > 0
     and coalesce(e.end_date - e.date, 0) + 1 >= public.series_period_days(p_freq) then
    raise exception 'A multi-day event can only repeat less often than it is long' using errcode = '22023';
  end if;

  v_prev := public.series_internal_begin();
  insert into public.event_series
    (workspace_id, created_by, freq, starts_on, ends_on, name, category_id, location, notes, format,
     ticket_url, length_days)
  values
    (e.workspace_id, e.created_by, p_freq, e.date, p_ends_on, e.name, e.category_id, e.location, e.notes,
     e.format, e.ticket_url, coalesce(e.end_date - e.date, 0))
  returning id into v_id;
  update public.events set series_id = v_id, series_date = e.date where id = e.id;
  for r in select * from public.series_fill(v_id, public.workspace_today(v_ws)) loop
    v_events := v_events || to_jsonb(r);
  end loop;
  perform public.series_internal_end(v_prev);
  return jsonb_build_object(
    'events', v_events || coalesce((select jsonb_agg(to_jsonb(x)) from public.events x where x.id = e.id), '[]'::jsonb),
    'series', coalesce((select jsonb_agg(to_jsonb(y)) from public.event_series y where y.id = v_id), '[]'::jsonb));
end $$;
comment on function public.make_event_repeat(text, text, date) is
  'Makes an event repeat (daily, weekly, biweekly, monthly_date, monthly_weekday), until p_ends_on or for ever. The event is the first occurrence; the next ones are made 8 weeks ahead.';
revoke execute on function public.make_event_repeat(text, text, date) from public, anon;
grant execute on function public.make_event_repeat(text, text, date) to authenticated;

-- "This and following events" on save: the edit made on one occurrence applies to it and the later ones
-- of its series, and to the occurrences made in future; earlier ones are never touched.
--
--  * p_patch: the fields as the person left them, by column (name, category_id, location, notes, format,
--    ticket_url, date, end_date; a null value clears). Only the fields that differ from the occurrence
--    as stored are applied to later ones, and not where that occurrence set the field itself with
--    "this event" (series_overrides). The occurrence itself takes all of it and clears its own marks.
--  * p_repeat: null = Repeats and Ends as they were; {"freq": "none"} = stop repeating here;
--    {"freq": "...", "ends_on": date|null} = a new rule.
--  * If the date, Repeats or Ends changed, the later occurrences are planned again from this one's
--    (new) date: the series is split here (or changed in place when this is its first). Later
--    occurrences that were never edited, have nothing hanging off them and are still ahead are dropped
--    and made again by the new rule; the others are never deleted: they stay in the series when their
--    date still fits the new rule and are otherwise kept as single events.
create function public.update_event_series_following(p_event_id text, p_patch jsonb, p_repeat jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ws text := public.current_workspace_id();
  v_today date;
  v_sid text;
  s public.event_series;
  e public.events;
  n public.events;
  v_key text;
  v_changed text[];
  v_old_len integer;
  v_new_len integer;
  v_freq text;
  v_ends date;
  v_stopped boolean := false;
  v_rule_changed boolean := false;
  v_target text;
  v_first boolean;
  v_later text[];
  v_taken date[] := '{}';
  v_removed text[] := '{}';
  v_touched text[];
  v_prev text;
  l public.events;
  r public.events;
begin
  if v_ws is null then
    raise exception 'Not signed in to a team' using errcode = '42501';
  end if;
  p_patch := coalesce(p_patch, '{}'::jsonb);
  for v_key in select jsonb_object_keys(p_patch) loop
    if v_key not in ('name', 'category_id', 'location', 'notes', 'format', 'ticket_url', 'date', 'end_date') then
      raise exception 'Unknown field: %', v_key using errcode = '22023';
    end if;
  end loop;

  -- Series first, then the occurrence: the same order everywhere, so two callers can't deadlock.
  select series_id into v_sid from public.events where id = p_event_id and workspace_id = v_ws;
  if v_sid is null then
    raise exception 'That event doesn''t repeat' using errcode = '22023';
  end if;
  select * into s from public.event_series where id = v_sid and workspace_id = v_ws for update;
  select * into e from public.events where id = p_event_id and series_id = v_sid for update;
  if s.id is null or e.id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;
  if not public.may_edit_events(e.created_by)
     or exists (select 1 from public.events x
                 where x.series_id = s.id and x.series_date > e.series_date
                   and not public.may_edit_events(x.created_by)) then
    raise exception 'You can''t change this event' using errcode = '42501';
  end if;
  v_today := public.workspace_today(v_ws);

  -- The occurrence as it will be.
  n := e;
  if p_patch ? 'name' then n.name := btrim(coalesce(p_patch ->> 'name', '')); end if;
  if p_patch ? 'category_id' then n.category_id := p_patch ->> 'category_id'; end if;
  if p_patch ? 'location' then n.location := p_patch ->> 'location'; end if;
  if p_patch ? 'notes' then n.notes := p_patch ->> 'notes'; end if;
  if p_patch ? 'format' then n.format := p_patch ->> 'format'; end if;
  if p_patch ? 'ticket_url' then n.ticket_url := p_patch ->> 'ticket_url'; end if;
  if p_patch ? 'date' then n.date := (p_patch ->> 'date')::date; end if;
  if p_patch ? 'end_date' then n.end_date := (p_patch ->> 'end_date')::date; end if;
  if n.name = '' or n.name is null or n.date is null then
    raise exception 'An event needs a name and a date' using errcode = '23514';
  end if;
  if n.end_date is not null and n.end_date < n.date then
    raise exception 'The end date can''t be before the start date' using errcode = '23514';
  end if;
  v_old_len := coalesce(e.end_date - e.date, 0);
  v_new_len := coalesce(n.end_date - n.date, 0);
  v_changed := array_remove(array[
    case when n.name is distinct from e.name then 'name' end,
    case when n.category_id is distinct from e.category_id then 'category_id' end,
    case when n.location is distinct from e.location then 'location' end,
    case when n.notes is distinct from e.notes then 'notes' end,
    case when n.format is distinct from e.format then 'format' end,
    case when n.ticket_url is distinct from e.ticket_url then 'ticket_url' end,
    case when n.date is distinct from e.date then 'date' end,
    case when n.end_date is distinct from e.end_date then 'end_date' end
  ]::text[], null);

  -- The rule as it will be.
  v_freq := s.freq;
  v_ends := s.ends_on;
  if p_repeat is not null and p_repeat <> 'null'::jsonb then
    if p_repeat ->> 'freq' = 'none' then
      v_stopped := true;
      v_rule_changed := true;
    else
      v_freq := p_repeat ->> 'freq';
      v_ends := (p_repeat ->> 'ends_on')::date;
      if v_freq is null or v_freq not in ('daily', 'weekly', 'biweekly', 'monthly_date', 'monthly_weekday') then
        raise exception 'Unknown repeat' using errcode = '22023';
      end if;
      v_rule_changed := v_freq is distinct from s.freq or v_ends is distinct from s.ends_on;
    end if;
  end if;
  if not v_stopped then
    if v_new_len > 0 and v_new_len + 1 >= public.series_period_days(v_freq) then
      raise exception 'A multi-day event can only repeat less often than it is long' using errcode = '22023';
    end if;
    if v_ends is not null and v_ends < n.date then
      raise exception 'The series can''t end before it starts' using errcode = '22023';
    end if;
  end if;

  v_prev := public.series_internal_begin();
  v_later := array(select x.id from public.events x
                    where x.series_id = s.id and x.series_date > e.series_date);

  -- The fields that changed move on to the later occurrences that haven't set them themselves.
  update public.events x set
    name = case when 'name' = any(v_changed) and not coalesce('name' = any(x.series_overrides), false)
                then n.name else x.name end,
    category_id = case when 'category_id' = any(v_changed) and not coalesce('category_id' = any(x.series_overrides), false)
                       then n.category_id else x.category_id end,
    location = case when 'location' = any(v_changed) and not coalesce('location' = any(x.series_overrides), false)
                    then n.location else x.location end,
    notes = case when 'notes' = any(v_changed) and not coalesce('notes' = any(x.series_overrides), false)
                 then n.notes else x.notes end,
    format = case when 'format' = any(v_changed) and not coalesce('format' = any(x.series_overrides), false)
                  then n.format else x.format end,
    ticket_url = case when 'ticket_url' = any(v_changed) and not coalesce('ticket_url' = any(x.series_overrides), false)
                      then n.ticket_url else x.ticket_url end,
    end_date = case when v_new_len <> v_old_len and not coalesce('end_date' = any(x.series_overrides), false)
                    then (case when v_new_len > 0 then x.date + v_new_len end) else x.end_date end
   where x.id = any(v_later);

  -- The occurrence itself takes everything and forgets what it had set on its own for those fields.
  update public.events set
    name = n.name, category_id = n.category_id, location = n.location, notes = n.notes,
    format = n.format, ticket_url = n.ticket_url, date = n.date, end_date = n.end_date,
    series_overrides = nullif(array(select f from unnest(coalesce(e.series_overrides, '{}'::text[])) f
                                     where f <> all(v_changed)), '{}'::text[])
   where id = e.id;

  -- What new occurrences are made from.
  update public.event_series set
    name = case when 'name' = any(v_changed) then n.name else name end,
    category_id = case when 'category_id' = any(v_changed) then n.category_id else category_id end,
    location = case when 'location' = any(v_changed) then n.location else location end,
    notes = case when 'notes' = any(v_changed) then n.notes else notes end,
    format = case when 'format' = any(v_changed) then n.format else format end,
    ticket_url = case when 'ticket_url' = any(v_changed) then n.ticket_url else ticket_url end,
    length_days = v_new_len
   where id = s.id;

  v_target := s.id;
  if (n.date is distinct from e.date) or v_rule_changed then
    -- The schedule changed: plan the later occurrences again from this one, on its (new) date.
    v_first := (e.series_date = s.starts_on);
    if v_stopped then
      update public.event_series set ends_on = e.series_date - 1 where id = s.id;
      v_target := null;
    elsif v_first then
      update public.event_series set freq = v_freq, starts_on = n.date, ends_on = v_ends where id = s.id;
    else
      insert into public.event_series
        (workspace_id, created_by, freq, starts_on, ends_on, skipped, name, category_id, location, notes,
         format, ticket_url, length_days)
      select t.workspace_id, t.created_by, v_freq, n.date, v_ends,
             array(select d from unnest(t.skipped) d where d >= e.series_date),
             t.name, t.category_id, t.location, t.notes, t.format, t.ticket_url, t.length_days
        from public.event_series t where t.id = s.id
      returning id into v_target;
      update public.event_series set ends_on = e.series_date - 1 where id = s.id;
    end if;

    -- Out of their places while they are sorted (the unique index would trip over a date that moves).
    update public.events set series_date = null where id = e.id or id = any(v_later);
    if v_target is not null then
      update public.events set series_id = v_target, series_date = n.date where id = e.id;
      v_taken := array[n.date];
    else
      update public.events set series_id = null, series_date = null, series_overrides = null where id = e.id;
    end if;
    for l in select * from public.events x where x.id = any(v_later) order by x.date, x.id loop
      if v_target is not null and not (l.date = any(v_taken))
         and public.series_is_slot(v_freq, n.date, l.date)
         and (v_ends is null or l.date <= v_ends) then
        -- Still on the new rule: stays in the series, whatever hangs off it.
        update public.events set series_id = v_target, series_date = l.date where id = l.id;
        v_taken := v_taken || l.date;
      elsif coalesce(cardinality(l.series_overrides), 0) = 0
            and not public.event_has_dependents(l.id)
            and coalesce(l.end_date, l.date) >= v_today then
        -- Untouched, empty and still ahead: the new rule makes its own.
        delete from public.events where id = l.id;
        v_removed := v_removed || l.id;
      else
        -- Kept as it is: a single event now.
        update public.events set series_id = null, series_date = null, series_overrides = null where id = l.id;
      end if;
    end loop;
    if v_target is not null then
      perform 1 from public.series_fill(v_target, v_today);
    end if;
  end if;

  v_touched := array[e.id] || v_later;
  perform public.series_internal_end(v_prev);
  return jsonb_build_object(
    'events', coalesce((select jsonb_agg(to_jsonb(x)) from public.events x
                         where x.id = any(v_touched) or x.series_id = v_target), '[]'::jsonb),
    'deleted', to_jsonb(v_removed),
    'series', coalesce((select jsonb_agg(to_jsonb(y)) from public.event_series y
                         where y.id = s.id or y.id = v_target), '[]'::jsonb));
end $$;
comment on function public.update_event_series_following(text, jsonb, jsonb) is
  'The "this and following events" edit of a repeating event: changes this occurrence and the later ones (and the rule, if asked), never an earlier one.';
revoke execute on function public.update_event_series_following(text, jsonb, jsonb) from public, anon;
grant execute on function public.update_event_series_following(text, jsonb, jsonb) to authenticated;

-- "This and following events" on delete: this occurrence and every later one go, and the series stops
-- just before this date. Later occurrences that are already over are history (attendance included)
-- and stay as single events; earlier ones are never touched.
create function public.delete_event_following(p_event_id text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ws text := public.current_workspace_id();
  v_today date;
  v_sid text;
  s public.event_series;
  e public.events;
  x public.events;
  v_removed text[] := '{}';
  v_kept text[] := '{}';
  v_prev text;
begin
  if v_ws is null then
    raise exception 'Not signed in to a team' using errcode = '42501';
  end if;
  select series_id into v_sid from public.events where id = p_event_id and workspace_id = v_ws;
  if v_sid is null then
    raise exception 'That event doesn''t repeat' using errcode = '22023';
  end if;
  select * into s from public.event_series where id = v_sid and workspace_id = v_ws for update;
  select * into e from public.events where id = p_event_id and series_id = v_sid for update;
  if s.id is null or e.id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.events y
              where y.series_id = s.id and y.series_date >= e.series_date
                and not public.may_edit_events(y.created_by)) then
    raise exception 'You can''t delete this event' using errcode = '42501';
  end if;
  v_today := public.workspace_today(v_ws);

  v_prev := public.series_internal_begin();
  update public.event_series
     set ends_on = least(coalesce(ends_on, e.series_date - 1), e.series_date - 1)
   where id = s.id;
  for x in select * from public.events y where y.series_id = s.id and y.series_date >= e.series_date
            order by y.series_date for update loop
    if x.id = e.id or coalesce(x.end_date, x.date) >= v_today then
      delete from public.events where id = x.id;
      v_removed := v_removed || x.id;
    else
      update public.events set series_id = null, series_date = null, series_overrides = null where id = x.id;
      v_kept := v_kept || x.id;
    end if;
  end loop;
  perform public.series_internal_end(v_prev);
  return jsonb_build_object(
    'events', coalesce((select jsonb_agg(to_jsonb(y)) from public.events y where y.id = any(v_kept)), '[]'::jsonb),
    'deleted', to_jsonb(v_removed),
    'series', coalesce((select jsonb_agg(to_jsonb(z)) from public.event_series z where z.id = s.id), '[]'::jsonb));
end $$;
comment on function public.delete_event_following(text) is
  'Deletes a repeating event''s occurrence and every later one and stops the series there. Finished later occurrences stay as single events.';
revoke execute on function public.delete_event_following(text) from public, anon;
grant execute on function public.delete_event_following(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Merging categories moves the series along (and is not an edit of each occurrence)
-- ---------------------------------------------------------------------------

create or replace function public.merge_event_categories(p_from_id text, p_into_id text) returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_ws text := public.current_workspace_id();
  v_from public.event_categories;
  v_into public.event_categories;
  v_moved integer;
  v_prev text;
begin
  if not public.acts_as_leader() then
    raise exception 'Only your team''s leader and their deputies merge categories'
      using errcode = '42501';
  end if;
  select * into v_from from public.event_categories where id = p_from_id and workspace_id = v_ws;
  select * into v_into from public.event_categories where id = p_into_id and workspace_id = v_ws;
  if v_from.id is null or v_into.id is null then
    raise exception 'Category not found' using errcode = 'P0002';
  end if;
  if v_from.id = v_into.id then
    raise exception 'Pick a different category to merge into' using errcode = '22023';
  end if;
  if v_into.archived_at is not null then
    raise exception 'That category is archived' using errcode = '23514';
  end if;

  v_prev := public.series_internal_begin();
  update public.events set category_id = v_into.id
   where category_id = v_from.id and workspace_id = v_ws;
  get diagnostics v_moved = row_count;
  -- Repeating events keep repeating in the category they were merged into.
  update public.event_series set category_id = v_into.id
   where category_id = v_from.id and workspace_id = v_ws;
  perform public.series_internal_end(v_prev);

  update public.event_categories set archived_at = coalesce(archived_at, now())
   where id = v_from.id;
  return v_moved;
end $$;

-- The internals are for the functions above only.
revoke execute on function public.series_nth_date(text, date, integer) from public, anon, authenticated;
revoke execute on function public.series_period_days(text) from public, anon, authenticated;
revoke execute on function public.series_is_slot(text, date, date) from public, anon, authenticated;
revoke execute on function public.series_internal_begin() from public, anon, authenticated;
revoke execute on function public.series_internal_end(text) from public, anon, authenticated;
revoke execute on function public.may_edit_events(text) from public, anon, authenticated;
revoke execute on function public.event_has_dependents(text) from public, anon, authenticated;

-- END ORIGINAL 20261020000100_recurring_events.sql

-- BEGIN ORIGINAL 20261030000100_event_times.sql
-- Events can have a start and an end time (client: src/data/eventTimes.ts, src/data/recurrence).
--
--  * `events.start_time` and `events.end_time` are wall-clock times (`time`, no zone) in the team's time
--    zone (`workspaces.timezone`); null = no time. An event with no start time is all-day, exactly as
--    every event was before. The zone is not stored on the event: a team has one, and the time stays
--    "7 PM" when the clocks change. Whoever turns a time into a point in time (the app's "Add to
--    calendar", a program reading events) applies `workspaces.timezone` to the event's date and time.
--  * Rules (`event_times_ok()`, a check constraint on `events` and on `event_series`): an end time needs
--    a start time; on a one-day event the end time is after the start time; on a multi-day event the
--    start time belongs to the first day and the end time to the last, so the end may be earlier.
--  * `event_series.start_time` / `end_time` are what a new occurrence is made from, like the other
--    template fields. A series takes its times from the event that starts it, occurrences made later get
--    them, "this and following" changes them from that occurrence on, and a time changed on one
--    occurrence alone is remembered in `series_overrides` like every other field ('start_time',
--    'end_time'): the guard trigger's field list and the following-update function's allowed fields grow
--    by those two (TypeScript twin: src/data/recurrence/plan.ts).
--  * `events.updated_at` (timestamptz, default now()) is kept current by a trigger on every update, so a
--    program reading events can tell what changed. Existing rows start at their `created_at`.
--
-- Additive only: five new nullable/defaulted columns, one pure helper function, one trigger and the new
-- constraints (which every existing row satisfies, because every existing row has no time). The currently
-- deployed client writes none of these columns and keeps working: its inserts and updates leave them
-- alone, its "this event" edits still pass the guard trigger, and it calls the same three series
-- functions with the same arguments. Replaced functions keep their signatures, `security definer`,
-- `search_path = ''`, caller checks and grants.

-- ---------------------------------------------------------------------------
-- The rule
-- ---------------------------------------------------------------------------

-- Whether a start and end time are allowed on an event that runs p_length_days past its first day (0 = a
-- one-day event). Pure: it reads no table, so it is safe for a check constraint and for any caller (the same
-- rule as `timesOk()` in src/data/eventTimes.ts; both are tested against the one table of cases in
-- src/data/recurrence/cases.ts).
create function public.event_times_ok(p_length_days integer, p_start_time time, p_end_time time)
returns boolean
language sql immutable set search_path = ''
as $$
  select case
    when p_end_time is null then true
    when p_start_time is null then false
    else coalesce(p_length_days, 0) > 0 or p_end_time > p_start_time
  end
$$;
comment on function public.event_times_ok(integer, time, time) is
  'Whether a start and end time are allowed on an event that runs p_length_days past its first day: no end time without a start time, and on a one-day event the end is after the start.';

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------

alter table public.events
  add column start_time time,
  add column end_time time,
  add column updated_at timestamptz not null default now();
comment on column public.events.start_time is 'Wall-clock start time in the workspace''s time zone; null = all-day (and then there is no end time).';
comment on column public.events.end_time is 'Wall-clock end time in the workspace''s time zone, on the last day for a multi-day event; null = none.';
comment on column public.events.updated_at is 'When the event row last changed (set by a trigger on every update); the starting value of an event from before is its created_at.';

alter table public.events
  add constraint events_times_ok
  check (public.event_times_ok(coalesce(end_date - date, 0), start_time, end_time));

alter table public.event_series
  add column start_time time,
  add column end_time time;
comment on column public.event_series.start_time is 'The start time a new occurrence gets (wall-clock, in the workspace''s time zone); null = all-day.';
comment on column public.event_series.end_time is 'The end time a new occurrence gets; null = none.';

alter table public.event_series
  add constraint event_series_times_ok
  check (public.event_times_ok(length_days, start_time, end_time));

-- ---------------------------------------------------------------------------
-- updated_at
-- ---------------------------------------------------------------------------

-- Existing events start at the day they were made. (Before the trigger below exists, so this is not
-- itself a change.)
update public.events set updated_at = created_at;

create function public.events_touch_updated_at() returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end $$;
revoke execute on function public.events_touch_updated_at() from public, anon, authenticated;

create trigger events_touch_updated_at before update on public.events
  for each row execute function public.events_touch_updated_at();

-- ---------------------------------------------------------------------------
-- Series functions that know the two new fields. Each is `create or replace` with the same signature;
-- ownership, `security definer`, `search_path = ''` and the grants below are the same as before.
-- ---------------------------------------------------------------------------

-- A change to one occurrence is remembered on it, now including its times.
create or replace function public.events_series_guard() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_fields text[];
begin
  if coalesce(current_setting('app.series_internal', true), '') = 'on' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.series_id is not null or new.series_date is not null or new.series_overrides is not null then
      raise exception 'Occurrences of a repeating event are made by their series'
        using errcode = '42501';
    end if;
    return new;
  end if;
  if new.series_id is distinct from old.series_id
     or new.series_date is distinct from old.series_date
     or new.series_overrides is distinct from old.series_overrides then
    raise exception 'The series of an event can''t be changed directly' using errcode = '42501';
  end if;
  if old.series_id is not null then
    v_fields := array_remove(array[
      case when new.name is distinct from old.name then 'name' end,
      case when new.category_id is distinct from old.category_id then 'category_id' end,
      case when new.location is distinct from old.location then 'location' end,
      case when new.notes is distinct from old.notes then 'notes' end,
      case when new.format is distinct from old.format then 'format' end,
      case when new.ticket_url is distinct from old.ticket_url then 'ticket_url' end,
      case when new.date is distinct from old.date then 'date' end,
      case when new.end_date is distinct from old.end_date then 'end_date' end,
      case when new.start_time is distinct from old.start_time then 'start_time' end,
      case when new.end_time is distinct from old.end_time then 'end_time' end
    ]::text[], null);
    if cardinality(v_fields) > 0 then
      new.series_overrides := array(
        select distinct f from unnest(coalesce(old.series_overrides, '{}'::text[]) || v_fields) f
         order by f);
    end if;
  end if;
  return new;
end $$;

-- New occurrences carry the series' times.
create or replace function public.series_fill(p_series_id text, p_today date) returns setof public.events
language plpgsql security definer set search_path = ''
as $$
declare
  s public.event_series;
  n integer := 0;
  v_slot date;
  v_wanted integer := 0;
  v_horizon date := p_today + 56;
  v_row public.events;
  v_prev text;
begin
  select * into s from public.event_series where id = p_series_id for update;
  if s.id is null or (s.ends_on is not null and s.ends_on < p_today) then
    return;
  end if;
  v_prev := public.series_internal_begin();
  while n < 5000 loop
    v_slot := public.series_nth_date(s.freq, s.starts_on, n);
    n := n + 1;
    exit when s.ends_on is not null and v_slot > s.ends_on;
    continue when v_slot < p_today;
    exit when v_slot > v_horizon and v_wanted >= 2;
    continue when v_slot = any(s.skipped);
    v_wanted := v_wanted + 1;
    insert into public.events
      (workspace_id, name, category_id, date, end_date, location, notes, format, ticket_url,
       start_time, end_time, created_by, series_id, series_date)
    values
      (s.workspace_id, s.name, s.category_id, v_slot,
       case when s.length_days > 0 then v_slot + s.length_days end,
       s.location, s.notes, s.format, s.ticket_url, s.start_time, s.end_time, s.created_by, s.id, v_slot)
    on conflict (series_id, series_date) where series_id is not null do nothing
    returning * into v_row;
    if found then
      return next v_row;
    end if;
  end loop;
  perform public.series_internal_end(v_prev);
  return;
end $$;

-- A new series takes the event's times.
create or replace function public.make_event_repeat(p_event_id text, p_freq text, p_ends_on date) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ws text := public.current_workspace_id();
  e public.events;
  v_id text;
  v_prev text;
  r public.events;
  v_events jsonb := '[]'::jsonb;
begin
  if v_ws is null then
    raise exception 'Not signed in to a team' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id and workspace_id = v_ws for update;
  if e.id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;
  if not public.may_edit_events(e.created_by) then
    raise exception 'You can''t change this event' using errcode = '42501';
  end if;
  if e.series_id is not null then
    raise exception 'That event already repeats' using errcode = '22023';
  end if;
  if p_freq is null or p_freq not in ('daily', 'weekly', 'biweekly', 'monthly_date', 'monthly_weekday') then
    raise exception 'Unknown repeat' using errcode = '22023';
  end if;
  if p_ends_on is not null and p_ends_on < e.date then
    raise exception 'The series can''t end before it starts' using errcode = '22023';
  end if;
  if coalesce(e.end_date - e.date, 0) > 0
     and coalesce(e.end_date - e.date, 0) + 1 >= public.series_period_days(p_freq) then
    raise exception 'A multi-day event can only repeat less often than it is long' using errcode = '22023';
  end if;

  v_prev := public.series_internal_begin();
  insert into public.event_series
    (workspace_id, created_by, freq, starts_on, ends_on, name, category_id, location, notes, format,
     ticket_url, start_time, end_time, length_days)
  values
    (e.workspace_id, e.created_by, p_freq, e.date, p_ends_on, e.name, e.category_id, e.location, e.notes,
     e.format, e.ticket_url, e.start_time, e.end_time, coalesce(e.end_date - e.date, 0))
  returning id into v_id;
  update public.events set series_id = v_id, series_date = e.date where id = e.id;
  for r in select * from public.series_fill(v_id, public.workspace_today(v_ws)) loop
    v_events := v_events || to_jsonb(r);
  end loop;
  perform public.series_internal_end(v_prev);
  return jsonb_build_object(
    'events', v_events || coalesce((select jsonb_agg(to_jsonb(x)) from public.events x where x.id = e.id), '[]'::jsonb),
    'series', coalesce((select jsonb_agg(to_jsonb(y)) from public.event_series y where y.id = v_id), '[]'::jsonb));
end $$;

-- "This and following" changes the times (and drops an end time that no longer fits an occurrence).
create or replace function public.update_event_series_following(p_event_id text, p_patch jsonb, p_repeat jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ws text := public.current_workspace_id();
  v_today date;
  v_sid text;
  s public.event_series;
  e public.events;
  n public.events;
  v_key text;
  v_changed text[];
  v_old_len integer;
  v_new_len integer;
  v_freq text;
  v_ends date;
  v_stopped boolean := false;
  v_rule_changed boolean := false;
  v_target text;
  v_first boolean;
  v_later text[];
  v_taken date[] := '{}';
  v_removed text[] := '{}';
  v_touched text[];
  v_prev text;
  l public.events;
  m public.events;
  r public.events;
  v_t_start time;
  v_t_end time;
begin
  if v_ws is null then
    raise exception 'Not signed in to a team' using errcode = '42501';
  end if;
  p_patch := coalesce(p_patch, '{}'::jsonb);
  for v_key in select jsonb_object_keys(p_patch) loop
    if v_key not in ('name', 'category_id', 'location', 'notes', 'format', 'ticket_url', 'date', 'end_date',
                     'start_time', 'end_time') then
      raise exception 'Unknown field: %', v_key using errcode = '22023';
    end if;
  end loop;

  -- Series first, then the occurrence: the same order everywhere, so two callers can't deadlock.
  select series_id into v_sid from public.events where id = p_event_id and workspace_id = v_ws;
  if v_sid is null then
    raise exception 'That event doesn''t repeat' using errcode = '22023';
  end if;
  select * into s from public.event_series where id = v_sid and workspace_id = v_ws for update;
  select * into e from public.events where id = p_event_id and series_id = v_sid for update;
  if s.id is null or e.id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;
  if not public.may_edit_events(e.created_by)
     or exists (select 1 from public.events x
                 where x.series_id = s.id and x.series_date > e.series_date
                   and not public.may_edit_events(x.created_by)) then
    raise exception 'You can''t change this event' using errcode = '42501';
  end if;
  v_today := public.workspace_today(v_ws);

  -- The occurrence as it will be.
  n := e;
  if p_patch ? 'name' then n.name := btrim(coalesce(p_patch ->> 'name', '')); end if;
  if p_patch ? 'category_id' then n.category_id := p_patch ->> 'category_id'; end if;
  if p_patch ? 'location' then n.location := p_patch ->> 'location'; end if;
  if p_patch ? 'notes' then n.notes := p_patch ->> 'notes'; end if;
  if p_patch ? 'format' then n.format := p_patch ->> 'format'; end if;
  if p_patch ? 'ticket_url' then n.ticket_url := p_patch ->> 'ticket_url'; end if;
  if p_patch ? 'date' then n.date := (p_patch ->> 'date')::date; end if;
  if p_patch ? 'end_date' then n.end_date := (p_patch ->> 'end_date')::date; end if;
  if p_patch ? 'start_time' then n.start_time := (p_patch ->> 'start_time')::time; end if;
  if p_patch ? 'end_time' then n.end_time := (p_patch ->> 'end_time')::time; end if;
  if n.name = '' or n.name is null or n.date is null then
    raise exception 'An event needs a name and a date' using errcode = '23514';
  end if;
  if n.end_date is not null and n.end_date < n.date then
    raise exception 'The end date can''t be before the start date' using errcode = '23514';
  end if;
  if n.end_time is not null and n.start_time is null then
    raise exception 'An end time needs a start time' using errcode = '23514';
  end if;
  v_old_len := coalesce(e.end_date - e.date, 0);
  v_new_len := coalesce(n.end_date - n.date, 0);
  if not public.event_times_ok(v_new_len, n.start_time, n.end_time) then
    raise exception 'The end time must be after the start time' using errcode = '23514';
  end if;
  v_changed := array_remove(array[
    case when n.name is distinct from e.name then 'name' end,
    case when n.category_id is distinct from e.category_id then 'category_id' end,
    case when n.location is distinct from e.location then 'location' end,
    case when n.notes is distinct from e.notes then 'notes' end,
    case when n.format is distinct from e.format then 'format' end,
    case when n.ticket_url is distinct from e.ticket_url then 'ticket_url' end,
    case when n.date is distinct from e.date then 'date' end,
    case when n.end_date is distinct from e.end_date then 'end_date' end,
    case when n.start_time is distinct from e.start_time then 'start_time' end,
    case when n.end_time is distinct from e.end_time then 'end_time' end
  ]::text[], null);

  -- The rule as it will be.
  v_freq := s.freq;
  v_ends := s.ends_on;
  if p_repeat is not null and p_repeat <> 'null'::jsonb then
    if p_repeat ->> 'freq' = 'none' then
      v_stopped := true;
      v_rule_changed := true;
    else
      v_freq := p_repeat ->> 'freq';
      v_ends := (p_repeat ->> 'ends_on')::date;
      if v_freq is null or v_freq not in ('daily', 'weekly', 'biweekly', 'monthly_date', 'monthly_weekday') then
        raise exception 'Unknown repeat' using errcode = '22023';
      end if;
      v_rule_changed := v_freq is distinct from s.freq or v_ends is distinct from s.ends_on;
    end if;
  end if;
  if not v_stopped then
    if v_new_len > 0 and v_new_len + 1 >= public.series_period_days(v_freq) then
      raise exception 'A multi-day event can only repeat less often than it is long' using errcode = '22023';
    end if;
    if v_ends is not null and v_ends < n.date then
      raise exception 'The series can''t end before it starts' using errcode = '22023';
    end if;
  end if;

  v_prev := public.series_internal_begin();
  v_later := array(select x.id from public.events x
                    where x.series_id = s.id and x.series_date > e.series_date);

  -- The fields that changed move on to the later occurrences that haven't set them themselves. One
  -- occurrence at a time: a time that doesn't fit the occurrence it lands on (an end time with no start
  -- time, or an end that isn't after the start on a one-day occurrence) is dropped, never made up.
  for l in select * from public.events x where x.id = any(v_later) order by x.series_date loop
    m := l;
    if 'name' = any(v_changed) and not coalesce('name' = any(l.series_overrides), false) then
      m.name := n.name;
    end if;
    if 'category_id' = any(v_changed) and not coalesce('category_id' = any(l.series_overrides), false) then
      m.category_id := n.category_id;
    end if;
    if 'location' = any(v_changed) and not coalesce('location' = any(l.series_overrides), false) then
      m.location := n.location;
    end if;
    if 'notes' = any(v_changed) and not coalesce('notes' = any(l.series_overrides), false) then
      m.notes := n.notes;
    end if;
    if 'format' = any(v_changed) and not coalesce('format' = any(l.series_overrides), false) then
      m.format := n.format;
    end if;
    if 'ticket_url' = any(v_changed) and not coalesce('ticket_url' = any(l.series_overrides), false) then
      m.ticket_url := n.ticket_url;
    end if;
    if 'start_time' = any(v_changed) and not coalesce('start_time' = any(l.series_overrides), false) then
      m.start_time := n.start_time;
    end if;
    if 'end_time' = any(v_changed) and not coalesce('end_time' = any(l.series_overrides), false) then
      m.end_time := n.end_time;
    end if;
    if v_new_len <> v_old_len and not coalesce('end_date' = any(l.series_overrides), false) then
      m.end_date := case when v_new_len > 0 then l.date + v_new_len end;
    end if;
    if not public.event_times_ok(coalesce(m.end_date - m.date, 0), m.start_time, m.end_time) then
      m.end_time := null;
    end if;
    update public.events set
      name = m.name, category_id = m.category_id, location = m.location, notes = m.notes,
      format = m.format, ticket_url = m.ticket_url, end_date = m.end_date,
      start_time = m.start_time, end_time = m.end_time
     where id = l.id;
  end loop;

  -- The occurrence itself takes everything and forgets what it had set on its own for those fields.
  update public.events set
    name = n.name, category_id = n.category_id, location = n.location, notes = n.notes,
    format = n.format, ticket_url = n.ticket_url, date = n.date, end_date = n.end_date,
    start_time = n.start_time, end_time = n.end_time,
    series_overrides = nullif(array(select f from unnest(coalesce(e.series_overrides, '{}'::text[])) f
                                     where f <> all(v_changed)), '{}'::text[])
   where id = e.id;

  -- What new occurrences are made from (a time that doesn't fit the new length is dropped here too).
  v_t_start := case when 'start_time' = any(v_changed) then n.start_time else s.start_time end;
  v_t_end := case when 'end_time' = any(v_changed) then n.end_time else s.end_time end;
  if not public.event_times_ok(v_new_len, v_t_start, v_t_end) then
    v_t_end := null;
  end if;
  update public.event_series set
    name = case when 'name' = any(v_changed) then n.name else name end,
    category_id = case when 'category_id' = any(v_changed) then n.category_id else category_id end,
    location = case when 'location' = any(v_changed) then n.location else location end,
    notes = case when 'notes' = any(v_changed) then n.notes else notes end,
    format = case when 'format' = any(v_changed) then n.format else format end,
    ticket_url = case when 'ticket_url' = any(v_changed) then n.ticket_url else ticket_url end,
    start_time = v_t_start, end_time = v_t_end,
    length_days = v_new_len
   where id = s.id;

  v_target := s.id;
  if (n.date is distinct from e.date) or v_rule_changed then
    -- The schedule changed: plan the later occurrences again from this one, on its (new) date.
    v_first := (e.series_date = s.starts_on);
    if v_stopped then
      update public.event_series set ends_on = e.series_date - 1 where id = s.id;
      v_target := null;
    elsif v_first then
      update public.event_series set freq = v_freq, starts_on = n.date, ends_on = v_ends where id = s.id;
    else
      insert into public.event_series
        (workspace_id, created_by, freq, starts_on, ends_on, skipped, name, category_id, location, notes,
         format, ticket_url, start_time, end_time, length_days)
      select t.workspace_id, t.created_by, v_freq, n.date, v_ends,
             array(select d from unnest(t.skipped) d where d >= e.series_date),
             t.name, t.category_id, t.location, t.notes, t.format, t.ticket_url, t.start_time, t.end_time,
             t.length_days
        from public.event_series t where t.id = s.id
      returning id into v_target;
      update public.event_series set ends_on = e.series_date - 1 where id = s.id;
    end if;

    -- Out of their places while they are sorted (the unique index would trip over a date that moves).
    update public.events set series_date = null where id = e.id or id = any(v_later);
    if v_target is not null then
      update public.events set series_id = v_target, series_date = n.date where id = e.id;
      v_taken := array[n.date];
    else
      update public.events set series_id = null, series_date = null, series_overrides = null where id = e.id;
    end if;
    for l in select * from public.events x where x.id = any(v_later) order by x.date, x.id loop
      if v_target is not null and not (l.date = any(v_taken))
         and public.series_is_slot(v_freq, n.date, l.date)
         and (v_ends is null or l.date <= v_ends) then
        -- Still on the new rule: stays in the series, whatever hangs off it.
        update public.events set series_id = v_target, series_date = l.date where id = l.id;
        v_taken := v_taken || l.date;
      elsif coalesce(cardinality(l.series_overrides), 0) = 0
            and not public.event_has_dependents(l.id)
            and coalesce(l.end_date, l.date) >= v_today then
        -- Untouched, empty and still ahead: the new rule makes its own.
        delete from public.events where id = l.id;
        v_removed := v_removed || l.id;
      else
        -- Kept as it is: a single event now.
        update public.events set series_id = null, series_date = null, series_overrides = null where id = l.id;
      end if;
    end loop;
    if v_target is not null then
      perform 1 from public.series_fill(v_target, v_today);
    end if;
  end if;

  v_touched := array[e.id] || v_later;
  perform public.series_internal_end(v_prev);
  return jsonb_build_object(
    'events', coalesce((select jsonb_agg(to_jsonb(x)) from public.events x
                         where x.id = any(v_touched) or x.series_id = v_target), '[]'::jsonb),
    'deleted', to_jsonb(v_removed),
    'series', coalesce((select jsonb_agg(to_jsonb(y)) from public.event_series y
                         where y.id = s.id or y.id = v_target), '[]'::jsonb));
end $$;

-- Grants exactly as in 20261020000100_recurring_events.sql.
revoke execute on function public.events_series_guard() from public, anon, authenticated;
revoke execute on function public.series_fill(text, date) from public, anon, authenticated;
revoke execute on function public.make_event_repeat(text, text, date) from public, anon;
grant execute on function public.make_event_repeat(text, text, date) to authenticated;
revoke execute on function public.update_event_series_following(text, jsonb, jsonb) from public, anon;
grant execute on function public.update_event_series_following(text, jsonb, jsonb) to authenticated;

-- END ORIGINAL 20261030000100_event_times.sql

-- BEGIN ORIGINAL 20261105000100_agent_connector.sql
-- Agent connector, part 1: connections, pairing, audit and the database role
-- the `agent` Edge Function connects as.
--
-- A person presses a button in the app and gets a one-time pairing code
-- (`create_agent_pairing`). Their AI agent sends that code to the Edge
-- Function, which redeems it and hands the agent an opaque connection key
-- (only its SHA-256 is stored). The key means something to that one function
-- only; it is not a JWT and no other Supabase endpoint accepts it.
--
-- The function connects as the NOLOGIN-by-default role `agent_connector`
-- (the password is set per deployment, outside this repository). That role
-- owns nothing and has no table privileges. It can only:
--   1. look a connection up by key hash and touch last_used_at,
--   2. redeem a pairing code and record failed attempts,
--   3. `set role authenticated`, to run one `agent_*` tool as the person.
-- Steps 1 and 2 are SECURITY DEFINER functions in the schema `agent_private`
-- (not exposed by the Data API) executable only by that role. Step 3 is what
-- makes row-level security decide, exactly as it does for the app.
--
-- The tools themselves are in the next migration. The feature stays off until
-- the team's `feature_switches` row 'agents' is on (an app admin may use it
-- earlier as a preview, like the other switched features).

-- ---------------------------------------------------------------------------
-- The feature switch gains a value
-- ---------------------------------------------------------------------------

alter table public.feature_switches drop constraint feature_switches_feature_check;
alter table public.feature_switches add constraint feature_switches_feature_check
  check (feature in ('chats', 'library', 'campaigns', 'agents'));

-- ---------------------------------------------------------------------------
-- The role the Edge Function connects as
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'agent_connector') then
    -- NOINHERIT: membership of `authenticated` only lets it `set role`, it
    -- never gets that role's privileges while it is itself.
    create role agent_connector nologin noinherit nosuperuser nocreatedb nocreaterole noreplication;
  end if;
end $$;
grant authenticated to agent_connector;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.agent_pairings (
  id uuid primary key default gen_random_uuid(),
  -- SHA-256 (hex) of the normalised code; the code itself is never stored.
  code_hash text not null unique check (code_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid not null references auth.users (id) on delete cascade,
  person_id text not null references public.people (id) on delete cascade,
  workspace_id text not null references public.workspaces (id) on delete cascade,
  access text not null check (access in ('read', 'write')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);
comment on table public.agent_pairings is
  'One-time pairing codes (hashed). Created by create_agent_pairing(), redeemed once by the agent Edge Function. No client access.';
create index agent_pairings_user_idx on public.agent_pairings (user_id) where used_at is null;

create table public.agent_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  person_id text not null references public.people (id) on delete cascade,
  workspace_id text not null references public.workspaces (id) on delete cascade,
  label text not null check (char_length(label) between 1 and 80),
  -- SHA-256 (hex) of the connection key; the key itself is never stored and
  -- the column is not granted to any API role.
  key_hash text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
  access text not null check (access in ('read', 'write')),
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);
comment on table public.agent_connections is
  'An AI agent connected for one person. The person reads their own rows (never key_hash) and revokes through revoke_agent_connection().';
create index agent_connections_user_idx on public.agent_connections (user_id);

create table public.agent_audit (
  id bigint generated always as identity primary key,
  connection_id uuid not null references public.agent_connections (id) on delete cascade,
  person_id text not null,
  workspace_id text not null,
  tool text not null,
  arguments jsonb,
  result text,
  old_values jsonb,
  new_values jsonb,
  at timestamptz not null default now()
);
comment on table public.agent_audit is
  'One row per agent call (also refused ones). Holds details of the people the agent touched, so only the connected person reads it.';
create index agent_audit_person_idx on public.agent_audit (person_id, at desc);
create index agent_audit_connection_idx on public.agent_audit (connection_id, at desc);
create index agent_audit_at_idx on public.agent_audit (at);

-- Failed pairing attempts per (hashed) address, for throttling.
create table public.agent_pair_attempts (
  id bigint generated always as identity primary key,
  ip_hash text not null,
  at timestamptz not null default now()
);
comment on table public.agent_pair_attempts is
  'Failed /pair attempts by hashed address (throttle). Written and read only by agent_private functions.';
create index agent_pair_attempts_idx on public.agent_pair_attempts (ip_hash, at);

alter table public.agent_pairings enable row level security;
alter table public.agent_connections enable row level security;
alter table public.agent_audit enable row level security;
alter table public.agent_pair_attempts enable row level security;

-- Supabase hands new public tables (and their sequences) to the API roles by
-- default. Take all of it back, then grant narrowly.
revoke all on public.agent_pairings, public.agent_connections, public.agent_audit, public.agent_pair_attempts
  from public, anon, authenticated, service_role;
revoke all on sequence public.agent_audit_id_seq, public.agent_pair_attempts_id_seq
  from public, anon, authenticated, service_role;

-- A person reads their own connections, never the key hash (a column grant:
-- the app must name the columns, `select *` is refused), and their own audit
-- rows. Nothing is client-writable: connections are made by the Edge
-- Function's redeem function and revoked by revoke_agent_connection().
grant select (id, user_id, person_id, workspace_id, label, access, created_at, last_used_at, revoked_at)
  on public.agent_connections to authenticated;
grant select on public.agent_audit to authenticated;

create policy "read your own agent connections" on public.agent_connections
  for select to authenticated
  using (user_id = (select auth.uid())
         and person_id = (select public.current_person_id())
         and workspace_id = (select public.current_workspace_id()));

create policy "read your own agent audit rows" on public.agent_audit
  for select to authenticated
  using (person_id = (select public.current_person_id())
         and workspace_id = (select public.current_workspace_id()));

-- agent_pairings and agent_pair_attempts: RLS on, no policy, no grant. Only the
-- definer functions below reach them.

-- ---------------------------------------------------------------------------
-- Private schema (not exposed by the Data API)
-- ---------------------------------------------------------------------------

create schema agent_private;
revoke all on schema agent_private from public, anon;
grant usage on schema agent_private to authenticated, agent_connector;

-- Was this session opened by the connector role? session_user is the login
-- role: it survives `set role` and security definer, and an ordinary app
-- session (PostgREST logs in as another role) never has it. Every connector
-- function and the guard ask here, so there is one place to look.
create function agent_private.via_connector() returns boolean
language sql
stable
set search_path = ''
as $$ select session_user = 'agent_connector' $$;
revoke all on function agent_private.via_connector() from public, anon, authenticated, service_role;

-- May this login use the connector right now? Used by pairing, redemption and
-- every tool call. Takes the login explicitly (not auth.uid()) so the
-- redemption, which runs before any role switch, can use it too. Reasons:
--   no_person       the login is not attached to a person record
--   not_registered  not an apprentice or IBO, and not the team's leader/deputy
--   switched_off    the team has not switched agents on (an app admin may
--                   still use it: the preview rule of every switched feature)
create function agent_private.access_for(p_uid uuid)
returns table (person_id text, workspace_id text, allowed boolean, reason text, switch_on boolean, preview boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_person text;
  v_ws text;
  v_registered boolean;
begin
  select m.person_id, m.workspace_id into v_person, v_ws
    from public.members m
   where m.user_id = p_uid
   order by m.joined_at, m.workspace_id
   limit 1;

  person_id := v_person;
  workspace_id := v_ws;
  switch_on := false;
  preview := false;
  allowed := false;

  if v_person is null then
    reason := 'no_person';
    return next;
    return;
  end if;

  select exists (
           select 1
             from public.people p
             join public.members m on m.person_id = p.id and m.workspace_id = v_ws
            where p.id = v_person
              and p.workspace_id = v_ws
              and (m.role = 'leader'
                   or public.effective_biz_class(p.biz_class, p.business_start_date) in ('apprentice', 'ibo')
                   or exists (select 1 from public.deputies d
                               join public.members l on l.person_id = d.leader_id
                                                    and l.workspace_id = d.workspace_id and l.role = 'leader'
                              where d.deputy_id = p.id and d.workspace_id = v_ws)))
    into v_registered;
  if not v_registered then
    reason := 'not_registered';
    return next;
    return;
  end if;

  switch_on := exists (select 1 from public.feature_switches f
                        where f.workspace_id = v_ws and f.feature = 'agents' and f.enabled);
  preview := exists (select 1 from public.app_admins a where a.user_id = p_uid);
  allowed := switch_on or preview;
  reason := case when allowed then null else 'switched_off' end;
  return next;
end
$$;
revoke all on function agent_private.access_for(uuid) from public, anon, authenticated, service_role;

create function agent_private.access_message(p_reason text) returns text
language sql
immutable
set search_path = ''
as $$
  select case p_reason
    when 'no_person' then 'This login is not attached to a person record in a team'
    when 'not_registered' then 'Only registered team members (apprentices and IBOs) and the team''s leader can use an agent'
    when 'switched_off' then 'Agents are not switched on for this team'
    else 'Agents are not available for this login'
  end
$$;
revoke all on function agent_private.access_message(text) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- For the signed-in app
-- ---------------------------------------------------------------------------

-- Whether the caller may add an agent (for the Settings card).
create function public.my_agent_access() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  a record;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  select * into a from agent_private.access_for(auth.uid());
  return jsonb_build_object(
    'allowed', coalesce(a.allowed, false),
    'reason', a.reason,
    'message', case when a.allowed then null else agent_private.access_message(a.reason) end,
    'switch_on', coalesce(a.switch_on, false),
    'preview', coalesce(a.preview and not a.switch_on, false));
end
$$;

-- A one-time pairing code for the caller: 10 minutes, single use.
create function public.create_agent_pairing(p_access text default 'write') returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  a record;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- 32 symbols, no I, O, 0 or 1
  v_bytes bytea;
  v_code text := '';
  v_expires timestamptz := now() + interval '10 minutes';
  i int;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  if p_access is null or p_access not in ('read', 'write') then
    raise exception 'access must be read or write' using errcode = '22023';
  end if;
  select * into a from agent_private.access_for(v_uid);
  if not coalesce(a.allowed, false) then
    raise exception '%', agent_private.access_message(a.reason) using errcode = '42501';
  end if;
  if (select count(*) from public.agent_pairings
       where user_id = v_uid and used_at is null and expires_at > now()) >= 5 then
    raise exception 'Too many unused pairing codes: use them or wait for them to expire' using errcode = '54000';
  end if;
  if (select count(*) from public.agent_connections
       where user_id = v_uid and revoked_at is null) >= 10 then
    raise exception 'Too many connected agents: disconnect one first' using errcode = '54000';
  end if;

  v_bytes := extensions.gen_random_bytes(16);  -- 16 symbols x 5 bits = 80 bits
  for i in 0..15 loop
    v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) & 31) + 1, 1);
  end loop;

  insert into public.agent_pairings (code_hash, user_id, person_id, workspace_id, access, expires_at)
  values (encode(sha256(convert_to(v_code, 'utf8')), 'hex'), v_uid, a.person_id, a.workspace_id, p_access, v_expires);

  return jsonb_build_object(
    'code', substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4) || '-' || substr(v_code, 13, 4),
    'expires_at', v_expires,
    'access', p_access);
end
$$;

-- Disconnect one of the caller's agents. Always allowed for your own
-- connection (also while the team switch is off); no delete, the row stays.
create function public.revoke_agent_connection(p_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  update public.agent_connections c set revoked_at = now()
   where c.id = p_id and c.user_id = auth.uid() and c.revoked_at is null
  returning c.revoked_at into v_at;
  if v_at is null then
    raise exception 'No such connection' using errcode = 'PT404'; -- PostgREST answers 404
  end if;
  return jsonb_build_object('revoked_at', v_at);
end
$$;

revoke all on function public.my_agent_access(), public.create_agent_pairing(text), public.revoke_agent_connection(uuid)
  from public, anon, service_role;
grant execute on function public.my_agent_access(), public.create_agent_pairing(text), public.revoke_agent_connection(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- For the Edge Function (agent_connector only)
-- ---------------------------------------------------------------------------

-- Key hash -> the live connection, and touch last_used_at (at most once a minute).
create function agent_private.connector_lookup(p_key_hash text)
returns table (id uuid, user_id uuid, person_id text, workspace_id text, workspace_name text, label text, access text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not agent_private.via_connector() then
    raise exception 'only the connector role may call this' using errcode = '42501';
  end if;
  update public.agent_connections c set last_used_at = now()
   where c.key_hash = p_key_hash and c.revoked_at is null
     and (c.last_used_at is null or c.last_used_at < now() - interval '1 minute');
  return query
    select c.id, c.user_id, c.person_id, c.workspace_id, w.name, c.label, c.access
      from public.agent_connections c
      join public.workspaces w on w.id = c.workspace_id
     where c.key_hash = p_key_hash and c.revoked_at is null;
end
$$;

-- Redeem a pairing code (by hash) and create the connection, in one
-- transaction. No rows when the code is wrong, used, expired, or its owner may
-- no longer use the connector; the caller cannot tell these apart.
create function agent_private.connector_redeem(p_code_hash text, p_key_hash text, p_label text)
returns table (connection_id uuid, access text, person_name text, workspace_name text, created_at timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v public.agent_pairings;
  a record;
  v_conn public.agent_connections;
begin
  if not agent_private.via_connector() then
    raise exception 'only the connector role may call this' using errcode = '42501';
  end if;
  -- Locked: of two simultaneous redemptions the second waits, then finds the
  -- row used and gets nothing.
  select * into v from public.agent_pairings p
   where p.code_hash = p_code_hash and p.used_at is null and p.expires_at > now()
   for update;
  if not found then
    return;
  end if;
  select * into a from agent_private.access_for(v.user_id);
  if not coalesce(a.allowed, false) or a.person_id is distinct from v.person_id
     or a.workspace_id is distinct from v.workspace_id then
    return;
  end if;
  update public.agent_pairings p set used_at = now() where p.id = v.id;
  insert into public.agent_connections (user_id, person_id, workspace_id, label, key_hash, access)
  values (v.user_id, v.person_id, v.workspace_id, p_label, p_key_hash, v.access)
  returning * into v_conn;
  return query
    select v_conn.id, v_conn.access,
           (select p.name from public.people p where p.id = v_conn.person_id),
           (select w.name from public.workspaces w where w.id = v_conn.workspace_id),
           v_conn.created_at;
end
$$;

-- Throttling of /pair by hashed address: 8 failures per address, 100 in all,
-- in 10 minutes.
create function agent_private.connector_pair_blocked(p_ip_hash text) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mine int;
  v_all int;
begin
  if not agent_private.via_connector() then
    raise exception 'only the connector role may call this' using errcode = '42501';
  end if;
  select count(*) filter (where t.ip_hash = p_ip_hash), count(*) into v_mine, v_all
    from public.agent_pair_attempts t where t.at > now() - interval '10 minutes';
  return v_mine >= 8 or v_all >= 100;
end
$$;

create function agent_private.connector_pair_failed(p_ip_hash text) returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not agent_private.via_connector() then
    raise exception 'only the connector role may call this' using errcode = '42501';
  end if;
  if p_ip_hash is null or char_length(p_ip_hash) not between 8 and 64 then
    raise exception 'bad address hash' using errcode = '22023';
  end if;
  insert into public.agent_pair_attempts (ip_hash) values (p_ip_hash);
end
$$;

-- A tool that raises rolls back its own audit row, so the function records
-- the refusal (or failure) here, in the words it wants the person to read
-- ("refused: ...", "failed: ..."), for any connection that exists, whatever
-- its state.
create function agent_private.connector_refusal(p_conn uuid, p_tool text, p_args jsonb, p_reason text) returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not agent_private.via_connector() then
    raise exception 'only the connector role may call this' using errcode = '42501';
  end if;
  insert into public.agent_audit (connection_id, person_id, workspace_id, tool, arguments, result)
  select c.id, c.person_id, c.workspace_id, left(coalesce(p_tool, '?'), 80), p_args, left(coalesce(p_reason, ''), 500)
    from public.agent_connections c where c.id = p_conn;
end
$$;

revoke all on function
  agent_private.connector_lookup(text), agent_private.connector_redeem(text, text, text),
  agent_private.connector_pair_blocked(text), agent_private.connector_pair_failed(text),
  agent_private.connector_refusal(uuid, text, jsonb, text)
  from public, anon, authenticated, service_role;
grant execute on function
  agent_private.connector_lookup(text), agent_private.connector_redeem(text, text, text),
  agent_private.connector_pair_blocked(text), agent_private.connector_pair_failed(text),
  agent_private.connector_refusal(uuid, text, jsonb, text)
  to agent_connector;

-- ---------------------------------------------------------------------------
-- The guard every agent_* tool starts with
-- ---------------------------------------------------------------------------

-- The Edge Function opens a transaction as agent_connector, sets
-- app.agent_connection_id and request.jwt.claims (the person's login), does
-- `set local role authenticated` and calls one tool. The database re-checks
-- everything itself:
--   * the session was opened by agent_connector (see via_connector()), and the
--     connection id was set,
--   * the connection is unrevoked and belongs to the acting login,
--   * it still matches that login's person and workspace,
--   * the team switch (or the app-admin preview) still allows agents, and the
--     person is still registered,
--   * the connection's access allows the tool (write tools need 'write').
-- So switching the team off, revoking or demoting someone cuts an agent off on
-- its very next call.
create function agent_private.ctx(p_write boolean)
returns table (connection_id uuid, person_id text, workspace_id text, access text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  c public.agent_connections;
  a record;
begin
  if not agent_private.via_connector() then
    raise exception 'agent functions can only be called through the connector' using errcode = '42501';
  end if;
  begin
    v_id := nullif(current_setting('app.agent_connection_id', true), '')::uuid;
  exception when others then
    v_id := null;
  end;
  if v_id is null then
    raise exception 'agent functions can only be called through the connector' using errcode = '42501';
  end if;
  select * into c from public.agent_connections k
   where k.id = v_id and k.user_id = auth.uid() and k.revoked_at is null;
  if not found then
    raise exception 'agent connection is not active' using errcode = '28000';
  end if;
  select * into a from agent_private.access_for(auth.uid());
  if a.person_id is distinct from c.person_id or a.workspace_id is distinct from c.workspace_id then
    raise exception 'agent connection no longer matches this login''s person' using errcode = '42501';
  end if;
  if not coalesce(a.allowed, false) then
    raise exception '%', agent_private.access_message(a.reason) using errcode = '42501';
  end if;
  if p_write and c.access <> 'write' then
    raise exception 'this connection is read-only' using errcode = '42501';
  end if;
  connection_id := c.id;
  person_id := c.person_id;
  workspace_id := c.workspace_id;
  access := c.access;
  return next;
end
$$;

-- One audit row for the call in progress. Only for the connection the
-- transaction was opened for, and only for its own login.
create function agent_private.audit(
  p_conn uuid, p_tool text, p_args jsonb, p_result text,
  p_old jsonb default null, p_new jsonb default null) returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not agent_private.via_connector()
     or p_conn is distinct from nullif(current_setting('app.agent_connection_id', true), '')::uuid then
    raise exception 'audit refused' using errcode = '42501';
  end if;
  insert into public.agent_audit (connection_id, person_id, workspace_id, tool, arguments, result, old_values, new_values)
  select c.id, c.person_id, c.workspace_id, p_tool, p_args, left(p_result, 500), p_old, p_new
    from public.agent_connections c
   where c.id = p_conn and c.user_id = auth.uid();
  if not found then
    raise exception 'audit refused' using errcode = '42501';
  end if;
end
$$;

revoke all on function agent_private.ctx(boolean), agent_private.audit(uuid, text, jsonb, text, jsonb, jsonb)
  from public, anon, service_role;
grant execute on function agent_private.ctx(boolean), agent_private.audit(uuid, text, jsonb, text, jsonb, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Housekeeping: used or expired pairings and old attempts go after a day,
-- audit rows after 180 days.
-- ---------------------------------------------------------------------------

create function public.purge_agent_housekeeping() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pairings int;
  v_attempts int;
  v_audit int;
begin
  delete from public.agent_pairings p
   where coalesce(p.used_at, p.expires_at) < now() - interval '1 day';
  get diagnostics v_pairings = row_count;
  delete from public.agent_pair_attempts t where t.at < now() - interval '1 day';
  get diagnostics v_attempts = row_count;
  delete from public.agent_audit x where x.at < now() - interval '180 days';
  get diagnostics v_audit = row_count;
  return jsonb_build_object('pairings', v_pairings, 'attempts', v_attempts, 'audit', v_audit);
end
$$;
revoke execute on function public.purge_agent_housekeeping() from public, anon, authenticated;
grant execute on function public.purge_agent_housekeeping() to service_role;

-- Nightly with pg_cron when the extension is available (as the chat retention).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    -- Automatic permanent purge disabled for this fork; function retained for explicit use.
    null;
  else
    raise notice 'pg_cron not available: call public.purge_agent_housekeeping() from a scheduler instead';
  end if;
end;
$$;

-- END ORIGINAL 20261105000100_agent_connector.sql

-- BEGIN ORIGINAL 20261105000200_agent_tools.sql
-- Agent connector, part 2: the whitelist. Everything an agent can do is a
-- function named `agent_*` in `public`, and this file is the one place that
-- defines them (each new tool is one function here, one entry in
-- supabase/functions/agent/tools.ts and its tests).
--
-- Every tool is SECURITY INVOKER: the Edge Function runs it as the person
-- (`set local role authenticated`, the person's login in request.jwt.claims),
-- so the existing row-level security decides what they may see and change.
-- Every tool starts with agent_private.ctx(), which refuses unless the call
-- comes through the connector for a live, matching connection that the team
-- switch still allows, and writes exactly one audit row (also when it refuses
-- a request it understood: it returns {"error": "..."} after auditing instead
-- of raising, because a raise would roll the audit row back).
--
-- Never available to an agent: deletes, stage, sponsor, IBO#/LTD#, business
-- start date, chat, anything outside this list.

-- Who the connected person is, and what this connection may do.
create function public.agent_whoami() returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  select jsonb_build_object(
           'person', jsonb_build_object(
             'id', p.id,
             'name', p.name,
             'stage', public.effective_biz_class(p.biz_class, p.business_start_date)),
           'team_role', (select m.role from public.members m
                          where m.user_id = auth.uid() and m.person_id = c.person_id limit 1),
           'team', (select w.name from public.workspaces w where w.id = c.workspace_id),
           'today', public.workspace_today(c.workspace_id),
           'access', c.access)
    into v_out
    from public.people p where p.id = c.person_id;
  perform agent_private.audit(c.connection_id, 'whoami', '{}'::jsonb, 'ok');
  return v_out;
end
$$;

-- Prospects the person can see (their own and their downline's).
create function public.agent_list_prospects(p_limit int default 50) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.name, x.id), '[]'::jsonb) into v_out
    from (select p.id, p.name, p.phone, p.email, p.location, p.notes, p.sponsor_id
            from public.people p
           where p.biz_class = 'prospect'
           order by p.name, p.id
           limit v_limit) x;
  perform agent_private.audit(c.connection_id, 'list_prospects', jsonb_build_object('limit', v_limit),
                              jsonb_array_length(v_out) || ' rows');
  return v_out;
end
$$;

-- Add a prospect under the connected person.
create function public.agent_add_prospect(p_name text, p_phone text default null) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_id text := gen_random_uuid()::text;
  v_args jsonb := jsonb_build_object('name', p_name, 'phone', p_phone);
  v_out jsonb;
begin
  select * into c from agent_private.ctx(true);
  if p_name is null or btrim(p_name) = '' or char_length(p_name) > 120 or char_length(coalesce(p_phone, '')) > 40 then
    perform agent_private.audit(c.connection_id, 'add_prospect', v_args, 'refused: invalid name or phone');
    return jsonb_build_object('error', 'A name of 1 to 120 characters is required (phone at most 40).');
  end if;
  -- A chosen id and no RETURNING: RETURNING must pass the SELECT policy, which
  -- cannot see a row inserted by the same statement.
  insert into public.people (id, name, biz_class, pipeline_stage, sponsor_id, phone, stage_history)
  values (v_id, btrim(p_name), 'prospect', 'prospect', c.person_id, nullif(btrim(coalesce(p_phone, '')), ''),
          jsonb_build_array(jsonb_build_object('stage', 'prospect', 'at', now())));
  select jsonb_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'sponsor_id', p.sponsor_id)
    into v_out from public.people p where p.id = v_id;
  perform agent_private.audit(c.connection_id, 'add_prospect', v_args, 'created ' || v_id, null, v_out);
  return v_out;
end
$$;

-- Change a prospect's name, phone, email, location or notes. Any other key in
-- the patch is rejected, not ignored. RLS decides which prospects the person
-- may change; an invisible one is "not found" and nothing changes.
create function public.agent_update_prospect(p_id text, p_patch jsonb) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_args jsonb := jsonb_build_object('id', p_id, 'patch', p_patch);
  v_old jsonb;
  v_new jsonb;
  v_key text;
  v_max int;
  v_allowed constant text[] := array['name', 'phone', 'email', 'location', 'notes'];
begin
  select * into c from agent_private.ctx(true);
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    perform agent_private.audit(c.connection_id, 'update_prospect', v_args, 'refused: empty patch');
    return jsonb_build_object('error', 'Nothing to change: give at least one of name, phone, email, location, notes.');
  end if;
  for v_key in select jsonb_object_keys(p_patch) loop
    if not (v_key = any (v_allowed)) then
      perform agent_private.audit(c.connection_id, 'update_prospect', v_args, 'refused: field ' || left(v_key, 40) || ' is not allowed');
      return jsonb_build_object('error',
        'Only name, phone, email, location and notes can be changed; "' || left(v_key, 40) || '" cannot. Nothing was changed.');
    end if;
    v_max := case v_key when 'name' then 120 when 'phone' then 40 when 'email' then 200
                        when 'location' then 200 else 4000 end;
    if jsonb_typeof(p_patch -> v_key) not in ('string', 'null')
       or (v_key = 'name' and (jsonb_typeof(p_patch -> 'name') <> 'string' or btrim(p_patch ->> 'name') = ''))
       or char_length(coalesce(p_patch ->> v_key, '')) > v_max then
      perform agent_private.audit(c.connection_id, 'update_prospect', v_args, 'refused: bad value for ' || v_key);
      return jsonb_build_object('error',
        '"' || v_key || '" must be text of at most ' || v_max || ' characters or null (a name cannot be empty or null). Nothing was changed.');
    end if;
  end loop;

  select jsonb_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'email', p.email,
                            'location', p.location, 'notes', p.notes)
    into v_old from public.people p where p.id = p_id and p.biz_class = 'prospect';
  if v_old is null then
    perform agent_private.audit(c.connection_id, 'update_prospect', v_args, 'refused: no such prospect among the visible ones');
    return jsonb_build_object('error', 'No such prospect among the people you can see. Nothing was changed.');
  end if;

  update public.people p set
    name = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else p.name end,
    phone = case when p_patch ? 'phone' then nullif(btrim(p_patch ->> 'phone'), '') else p.phone end,
    email = case when p_patch ? 'email' then nullif(btrim(p_patch ->> 'email'), '') else p.email end,
    location = case when p_patch ? 'location' then nullif(btrim(p_patch ->> 'location'), '') else p.location end,
    notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else p.notes end,
    last_updated_at = now()
   where p.id = p_id and p.biz_class = 'prospect'
  returning jsonb_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'email', p.email,
                               'location', p.location, 'notes', p.notes)
    into v_new;
  if v_new is null then
    perform agent_private.audit(c.connection_id, 'update_prospect', v_args, 'refused: not allowed to change that prospect');
    return jsonb_build_object('error', 'You are not allowed to change that prospect. Nothing was changed.');
  end if;
  perform agent_private.audit(c.connection_id, 'update_prospect', v_args, 'updated ' || p_id, v_old, v_new);
  return v_new;
end
$$;

-- ---------------------------------------------------------------------------
-- Event data, in the shape of the receiving standard: iCalendar (RFC 5545), which Google, Apple and
-- Outlook calendars all accept. Field names and meanings are iCalendar's; the tool descriptions in
-- supabase/functions/agent/tools.ts name them. The helpers below read no table except event_data,
-- which reads as the caller, so row-level security decides what is in it.
-- ---------------------------------------------------------------------------

-- How far a zone is ahead of UTC at an instant, in seconds.
create function agent_private.tz_offset(p_zone text, p_at timestamptz) returns integer
language sql
stable
set search_path = ''
as $$
  select extract(epoch from ((p_at at time zone p_zone) - (p_at at time zone 'UTC')))::integer
$$;

-- An offset as iCalendar writes it: +0530, -0600.
create function agent_private.fmt_offset(p_seconds integer) returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_seconds < 0 then '-' else '+' end
         || lpad((abs(p_seconds) / 3600)::text, 2, '0') || lpad(((abs(p_seconds) % 3600) / 60)::text, 2, '0')
$$;

-- The instant a wall-clock date and time is in a zone, the way the app works it out for its own .ics
-- (src/data/chat/calendar.ts, zonedInstant): a time that happens twice (the clocks go back) is the first
-- one; a time that never happens (the clocks go forward) is moved on by the length of the gap. That is
-- also what RFC 5545 says (3.3.5). It equals `p_local at time zone p_zone` everywhere except in the
-- repeated hour, where Postgres takes the second.
create function agent_private.zoned_instant(p_local timestamp, p_zone text) returns timestamptz
language plpgsql
stable
strict
set search_path = ''
as $$
declare
  v_wall timestamptz := p_local at time zone 'UTC'; -- the wall-clock read as if it were UTC
  v_before integer := agent_private.tz_offset(p_zone, v_wall - interval '24 hours');
  v_after integer := agent_private.tz_offset(p_zone, v_wall + interval '24 hours');
  v_fit integer;
begin
  select max(x.o) into v_fit
    from (select v_before as o union select v_after) x
   where agent_private.tz_offset(p_zone, v_wall - make_interval(secs => x.o)) = x.o;
  return v_wall - make_interval(secs => coalesce(v_fit, v_before));
end
$$;

-- ISO 8601: a local wall-clock time without offset, and a UTC instant.
create function agent_private.fmt_local(p timestamp) returns text
language sql
immutable
set search_path = ''
as $$ select to_char(p, 'YYYY-MM-DD"T"HH24:MI:SS') $$;

create function agent_private.fmt_utc(p timestamptz) returns text
language sql
stable
set search_path = ''
as $$ select to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;

-- The RFC 5545 RRULE (no "RRULE:" prefix) that generates exactly the dates public.series_nth_date()
-- generates for a repeat rule, from the series' first date:
--   daily            FREQ=DAILY
--   weekly           FREQ=WEEKLY
--   biweekly         FREQ=WEEKLY;INTERVAL=2
--   monthly_date     day 1-28: FREQ=MONTHLY;BYMONTHDAY=<day>
--                    day 29:   FREQ=MONTHLY;BYMONTHDAY=28,29;BYSETPOS=-1     (February: the 28th or 29th, the last day)
--                    day 30:   FREQ=MONTHLY;BYMONTHDAY=28,29,30;BYSETPOS=-1  (February: the last day)
--                    day 31:   FREQ=MONTHLY;BYMONTHDAY=-1                    (the app's rule for day 31 IS the last day)
--   monthly_weekday  1st-4th: FREQ=MONTHLY;BYDAY=<n><weekday>
--                    5th:     FREQ=MONTHLY;BYDAY=-1<weekday>   (the app falls back from a fifth weekday to the last
--                             one, so every month gets the last such weekday: the 5th where there is one, else
--                             the 4th, which is the last then)
-- An end date is UNTIL in the form RFC 5545 requires for the series' start: a DATE for an all-day series;
-- for a timed one a UTC date-time, the last second of that day in the team's zone (every occurrence on
-- the end date starts before it, every later one after it). pgTAP 046 checks every form against
-- series_nth_date for the first 24 slots.
create function agent_private.series_rrule(
  p_freq text, p_starts_on date, p_ends_on date, p_timed boolean, p_zone text) returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_day integer := extract(day from p_starts_on)::integer;
  v_ord integer := (v_day - 1) / 7 + 1;
  v_wd text := (array['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'])[extract(dow from p_starts_on)::integer + 1];
  v_rule text;
begin
  v_rule := case p_freq
    when 'daily' then 'FREQ=DAILY'
    when 'weekly' then 'FREQ=WEEKLY'
    when 'biweekly' then 'FREQ=WEEKLY;INTERVAL=2'
    when 'monthly_date' then case
      when v_day <= 28 then 'FREQ=MONTHLY;BYMONTHDAY=' || v_day
      when v_day = 31 then 'FREQ=MONTHLY;BYMONTHDAY=-1'
      when v_day = 30 then 'FREQ=MONTHLY;BYMONTHDAY=28,29,30;BYSETPOS=-1'
      else 'FREQ=MONTHLY;BYMONTHDAY=28,29;BYSETPOS=-1'
    end
    when 'monthly_weekday' then
      'FREQ=MONTHLY;BYDAY=' || case when v_ord = 5 then '-1' else v_ord::text end || v_wd
  end;
  if v_rule is null then
    raise exception 'Unknown repeat: %', p_freq using errcode = '22023';
  end if;
  if p_ends_on is not null then
    v_rule := v_rule || ';UNTIL=' || case
      when p_timed then to_char(
        (agent_private.zoned_instant((p_ends_on + 1)::timestamp, p_zone) - interval '1 second') at time zone 'UTC',
        'YYYYMMDD"T"HH24MISS"Z"')
      else to_char(p_ends_on, 'YYYYMMDD')
    end;
  end if;
  return v_rule;
end
$$;

-- Every change of a zone's offset from Jan 1 of one year to Dec 31 of another, from the database's own
-- time zone data: the offset is read once a week and a week with a different offset at its two ends is
-- bisected to the second. For each change: which one of its year it is (j), its month, weekday, wall-clock
-- time before the change, which weekday of the month it is (n-th, and whether it is the last) and the
-- offsets either side. (Two changes inside one week that cancel out would be missed; they leave a year
-- with fewer changes than the others, which zone_definition refuses.)
create function agent_private.zone_transitions(p_zone text, p_from_year integer, p_to_year integer)
returns table (yr integer, j integer, mon integer, dow integer, tod time, n integer, is_last boolean,
               o0 integer, o1 integer, wall timestamp)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_s bigint := extract(epoch from make_timestamptz(p_from_year, 1, 1, 12, 0, 0, 'UTC'))::bigint;
  v_end bigint := extract(epoch from make_timestamptz(p_to_year, 12, 31, 12, 0, 0, 'UTC'))::bigint;
  v_next bigint;
  v_lo bigint;
  v_hi bigint;
  v_mid bigint;
  v_o0 integer := agent_private.tz_offset(p_zone, to_timestamp(v_s));
  v_o1 integer;
  v_wall timestamp;
  v_last_year integer := 0;
  v_j integer := 0;
begin
  while v_s < v_end loop
    v_next := least(v_s + 604800, v_end);
    v_o1 := agent_private.tz_offset(p_zone, to_timestamp(v_next));
    if v_o1 <> v_o0 then
      v_lo := v_s;
      v_hi := v_next;
      while v_hi - v_lo > 1 loop
        v_mid := (v_lo + v_hi) / 2;
        if agent_private.tz_offset(p_zone, to_timestamp(v_mid)) = v_o1 then
          v_hi := v_mid;
        else
          v_lo := v_mid;
        end if;
      end loop;
      v_wall := (to_timestamp(v_hi) at time zone 'UTC') + make_interval(secs => v_o0);
      yr := extract(year from v_wall)::integer;
      v_j := case when yr = v_last_year then v_j + 1 else 1 end;
      v_last_year := yr;
      j := v_j;
      mon := extract(month from v_wall)::integer;
      dow := extract(dow from v_wall)::integer;
      tod := v_wall::time;
      n := (extract(day from v_wall)::integer - 1) / 7 + 1;
      is_last := extract(day from v_wall)::integer + 7
                 > extract(day from (date_trunc('month', v_wall) + interval '1 month' - interval '1 day'))::integer;
      o0 := v_o0;
      o1 := v_o1;
      wall := v_wall;
      return next;
    end if;
    v_s := v_next;
    v_o0 := v_o1;
  end loop;
end
$$;

-- What an iCalendar VTIMEZONE needs for a zone: the yearly offset changes (daylight saving) as RRULEs, or
-- null when they can not be written as a yearly rule that is right from p_from_year to 31 years later.
-- Every change in that span, read from the database's zone data, must fall on the same month, weekday,
-- "n-th or last" place, wall-clock time and offsets every year; otherwise null, and the caller sends such
-- a series as separate events (a rule that is wrong is never produced). A zone with no change at all gives
-- one observance.
-- {"tzid", "from_year", "observances": [{"kind": STANDARD|DAYLIGHT, "from": "-0500", "to": "-0600",
--   "dtstart": "20251102T020000", "rrule": "FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"}]}
create function agent_private.zone_definition(p_zone text, p_from_year integer) returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_to_year integer := p_from_year + 31;
  v_tr jsonb;
  v_obs jsonb := '[]'::jsonb;
  v_changes integer;
  v_years_with integer;
  v_min integer;
  v_max integer;
  v_const integer;
  v_byday text;
  r record;
begin
  if p_from_year < 1971 or p_from_year > 2200
     or not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_zone) then
    return null;
  end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.wall), '[]'::jsonb) into v_tr
    from agent_private.zone_transitions(p_zone, p_from_year, v_to_year) t;
  select coalesce(sum(x.k), 0), count(*), min(x.k), max(x.k) into v_changes, v_years_with, v_min, v_max
    from (select t.yr, count(*) as k
            from jsonb_to_recordset(v_tr) as t (yr integer) group by t.yr) x;
  if v_changes = 0 then
    select min(agent_private.tz_offset(p_zone, to_timestamp(g.s))) into v_const
      from generate_series(extract(epoch from make_timestamptz(p_from_year, 1, 1, 12, 0, 0, 'UTC'))::bigint,
                           extract(epoch from make_timestamptz(v_to_year, 12, 31, 12, 0, 0, 'UTC'))::bigint,
                           604800) g (s);
    return jsonb_build_object('tzid', p_zone, 'from_year', p_from_year, 'observances', jsonb_build_array(
      jsonb_build_object('kind', 'STANDARD', 'from', agent_private.fmt_offset(v_const),
                         'to', agent_private.fmt_offset(v_const), 'dtstart', '19700101T000000')));
  end if;
  if v_years_with <> v_to_year - p_from_year + 1 or v_min <> v_max or v_max > 4 then
    return null;
  end if;
  for r in
    select t.j, count(distinct (t.mon, t.dow, t.tod, t.o0, t.o1)) as patterns, count(distinct t.n) as ns,
           bool_and(t.is_last) as always_last, min(t.n) as n, min(t.mon) as mon, min(t.dow) as dow,
           min(t.o0) as o0, min(t.o1) as o1, min(t.wall) as first_wall
      from jsonb_to_recordset(v_tr) as t (yr integer, j integer, mon integer, dow integer, tod time, n integer,
                                          is_last boolean, o0 integer, o1 integer, wall timestamp)
     group by t.j order by t.j
  loop
    if r.patterns <> 1 then
      return null;
    end if;
    if r.ns = 1 and r.n <= 4 then
      v_byday := r.n::text;
    elsif r.always_last then
      v_byday := '-1';
    else
      return null;
    end if;
    v_obs := v_obs || jsonb_build_array(jsonb_build_object(
      'kind', case when r.o1 > r.o0 then 'DAYLIGHT' else 'STANDARD' end,
      'from', agent_private.fmt_offset(r.o0), 'to', agent_private.fmt_offset(r.o1),
      'dtstart', to_char(r.first_wall, 'YYYYMMDD"T"HH24MISS'),
      'rrule', 'FREQ=YEARLY;BYMONTH=' || r.mon || ';BYDAY=' || v_byday
               || (array['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'])[r.dow + 1]));
  end loop;
  return jsonb_build_object('tzid', p_zone, 'from_year', p_from_year, 'observances', v_obs);
end
$$;

-- The events and series of the caller's team that fall in a window, as the caller sees them (RLS; the
-- public tools that call it start with the connector guard), in
-- iCalendar's terms. An event is in the window when it overlaps it, or when it is an occurrence of a
-- repeating event whose original slot is in it (so a moved occurrence reaches the receiver as the
-- exception it is). p_changed_since keeps only events changed after it; series are never filtered by it
-- (a deleted occurrence leaves no trace on any event but shows in the series' skipped dates).
--   event:  id (the app's), uid, summary, description, location, category, url, last_modified, all_day,
--           all-day: start_date, end_date_exclusive; timed: start, end, timezone, start_utc, end_utc;
--           my_answer, partstat; occurrence of a series: series_uid, recurrence_id, is_exception
--   series: series_uid, summary, description, location, category, url, all_day, the first occurrence's
--           start in the same two forms, timezone, rrule, exdates, until
create function agent_private.event_data(
  p_person text, p_workspace text, p_from date, p_until date, p_changed_since timestamptz) returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tz text;
  v_events jsonb;
  v_more boolean;
  v_series jsonb;
begin
  select w.timezone into v_tz from public.workspaces w where w.id = p_workspace;

  select coalesce(jsonb_agg(x.j order by x.rn) filter (where x.rn <= 500), '[]'::jsonb),
         coalesce(bool_or(x.rn > 500), false)
    into v_events, v_more
    from (select row_number() over (order by e.date, coalesce(e.start_time, time '00:00'), e.id) as rn,
                 jsonb_strip_nulls(jsonb_build_object(
                   'id', e.id,
                   'uid', e.id || '@events.invalid',
                   'summary', e.name,
                   'description', nullif(e.notes, ''),
                   'location', nullif(e.location, ''),
                   'category', k.name,
                   'url', e.ticket_url,
                   'last_modified', agent_private.fmt_utc(e.updated_at),
                   'all_day', e.start_time is null,
                   'start_date', case when e.start_time is null then e.date end,
                   'end_date_exclusive', case when e.start_time is null then t.last_day + 1 end,
                   'start', agent_private.fmt_local(t.s_loc),
                   'end', agent_private.fmt_local(t.e_loc),
                   'timezone', case when e.start_time is not null then v_tz end,
                   'start_utc', agent_private.fmt_utc(agent_private.zoned_instant(t.s_loc, v_tz)),
                   'end_utc', agent_private.fmt_utc(agent_private.zoned_instant(t.e_loc, v_tz)),
                   'series_uid', case when e.series_id is not null then e.series_id || '@series.invalid' end,
                   'recurrence_id', case when e.series_id is null then null
                                         when s.start_time is null then to_jsonb(e.series_date)
                                         else to_jsonb(agent_private.fmt_local(e.series_date + s.start_time)) end,
                   'is_exception', case when e.series_id is null then null
                     else coalesce(cardinality(e.series_overrides), 0) > 0
                          or e.date is distinct from e.series_date
                          or (e.name, e.notes, e.location, e.ticket_url, e.start_time, e.end_time, e.category_id,
                              coalesce(e.end_date - e.date, 0))
                             is distinct from
                             (s.name, s.notes, s.location, s.ticket_url, s.start_time, s.end_time, s.category_id,
                              s.length_days)
                   end))
                 || jsonb_build_object(
                      'my_answer', a.desire_to_attend,
                      'partstat', case a.desire_to_attend when 'yes' then 'ACCEPTED' when 'no' then 'DECLINED'
                                    when 'maybe' then 'TENTATIVE' else 'NEEDS-ACTION' end) as j
            from public.events e
            left join public.event_categories k on k.id = e.category_id
            left join public.attendances a on a.event_id = e.id and a.person_id = p_person
            left join public.event_series s on s.id = e.series_id
           cross join lateral (
             select coalesce(e.end_date, e.date) as last_day,
                    e.date + e.start_time as s_loc,
                    case when e.start_time is null then null
                         when e.end_time is not null then coalesce(e.end_date, e.date) + e.end_time
                         when coalesce(e.end_date, e.date) > e.date then (coalesce(e.end_date, e.date) + 1)::timestamp
                    end as e_loc) t
           where e.workspace_id = p_workspace
             and ((coalesce(e.end_date, e.date) >= p_from and e.date <= p_until)
                  or (e.series_id is not null and e.series_date between p_from and p_until))
             and (p_changed_since is null or e.updated_at > p_changed_since)
           order by e.date, coalesce(e.start_time, time '00:00'), e.id
           limit 501) x;

  select coalesce(jsonb_agg(y.j order by y.starts_on, y.id), '[]'::jsonb) into v_series
    from (select s.id, s.starts_on,
                 jsonb_strip_nulls(jsonb_build_object(
                   'series_uid', s.id || '@series.invalid',
                   'summary', s.name,
                   'description', nullif(s.notes, ''),
                   'location', nullif(s.location, ''),
                   'category', k.name,
                   'url', s.ticket_url,
                   'all_day', s.start_time is null,
                   'start_date', case when s.start_time is null then s.starts_on end,
                   'end_date_exclusive', case when s.start_time is null then s.starts_on + s.length_days + 1 end,
                   'start', agent_private.fmt_local(t.s_loc),
                   'end', agent_private.fmt_local(t.e_loc),
                   'start_utc', agent_private.fmt_utc(agent_private.zoned_instant(t.s_loc, v_tz)),
                   'end_utc', agent_private.fmt_utc(agent_private.zoned_instant(t.e_loc, v_tz)),
                   'timezone', v_tz,
                   'rrule', agent_private.series_rrule(s.freq, s.starts_on, s.ends_on, s.start_time is not null, v_tz),
                   'until', case when s.ends_on is null then null
                                 when s.start_time is null then to_jsonb(s.ends_on)
                                 else to_jsonb(agent_private.fmt_utc(
                                        agent_private.zoned_instant((s.ends_on + 1)::timestamp, v_tz)
                                        - interval '1 second')) end))
                 || jsonb_build_object('exdates', (
                      select coalesce(jsonb_agg(case when s.start_time is null then to_jsonb(d)
                                                     else to_jsonb(agent_private.fmt_local(d + s.start_time)) end
                                                order by d), '[]'::jsonb)
                        from unnest(s.skipped) d)) as j
            from public.event_series s
            left join public.event_categories k on k.id = s.category_id
           cross join lateral (
             select s.starts_on + s.start_time as s_loc,
                    case when s.start_time is null then null
                         when s.end_time is not null then s.starts_on + s.length_days + s.end_time
                         when s.length_days > 0 then (s.starts_on + s.length_days + 1)::timestamp
                    end as e_loc) t
           where s.workspace_id = p_workspace
             and ((coalesce(s.ends_on, p_from) >= p_from and s.starts_on <= p_until)
                  or exists (select 1 from public.events e
                              where e.series_id = s.id
                                and ((coalesce(e.end_date, e.date) >= p_from and e.date <= p_until)
                                     or e.series_date between p_from and p_until)))) y;

  return jsonb_build_object('timezone', v_tz, 'truncated', v_more, 'events', v_events, 'series', v_series);
end
$$;

-- The window of a call: from (default the team's today), until (default 8 weeks after from, at most 26
-- weeks after it; a later date is cut back and `capped` says so).
create function agent_private.event_window(p_workspace text, p_from date, p_until date)
returns table (w_from date, w_until date, capped boolean, problem text)
language plpgsql
stable
set search_path = ''
as $$
begin
  w_from := coalesce(p_from, public.workspace_today(p_workspace));
  w_until := coalesce(p_until, w_from + 56);
  if w_from < date '2000-01-01' or w_from > date '2100-01-01' then
    problem := 'from must be a date between 2000-01-01 and 2100-01-01.';
  elsif w_until < w_from then
    problem := 'until must not be before from.';
  end if;
  capped := w_until > w_from + 182;
  w_until := least(w_until, w_from + 182);
  return next;
end
$$;

-- The team's events and repeating events in a window, as iCalendar describes them (see the helpers above):
-- from (date, default the team's today), until (date, default 8 weeks after from, at most 26 weeks after
-- it), changed_since (a time: only events changed after it). Result: {from, until, capped, timezone,
-- truncated, events: [...], series: [...]}. Events are cut at 500 (`truncated`).
create function public.agent_list_upcoming_events(
  p_from date default null, p_until date default null, p_changed_since timestamptz default null) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  w record;
  v_args jsonb := jsonb_build_object('from', p_from, 'until', p_until, 'changed_since', p_changed_since);
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  select * into w from agent_private.event_window(c.workspace_id, p_from, p_until);
  if w.problem is not null then
    perform agent_private.audit(c.connection_id, 'list_upcoming_events', v_args, 'refused: ' || w.problem);
    return jsonb_build_object('error', w.problem);
  end if;
  v_out := jsonb_build_object('from', w.w_from, 'until', w.w_until, 'capped', w.capped)
           || agent_private.event_data(c.person_id, c.workspace_id, w.w_from, w.w_until, p_changed_since);
  perform agent_private.audit(c.connection_id, 'list_upcoming_events', v_args,
                              jsonb_array_length(v_out -> 'events') || ' events, '
                              || jsonb_array_length(v_out -> 'series') || ' series');
  return v_out;
end
$$;

-- The same window as an iCalendar file: this function returns the data (the events and series as above,
-- plus the zone's VTIMEZONE rules when a timed repeating series needs them: `timezone_definition`, null
-- when none does or when the zone's rules can not be written as a yearly rule), and the Edge Function
-- writes it out as text (supabase/functions/agent/ics.ts).
create function public.agent_export_events_ics(p_from date default null, p_until date default null) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  w record;
  v_args jsonb := jsonb_build_object('from', p_from, 'until', p_until);
  v_data jsonb;
  v_year integer;
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  select * into w from agent_private.event_window(c.workspace_id, p_from, p_until);
  if w.problem is not null then
    perform agent_private.audit(c.connection_id, 'export_events_ics', v_args, 'refused: ' || w.problem);
    return jsonb_build_object('error', w.problem);
  end if;
  v_data := agent_private.event_data(c.person_id, c.workspace_id, w.w_from, w.w_until, null);
  select min(substr(s ->> 'start', 1, 4)::integer) - 1 into v_year
    from jsonb_array_elements(v_data -> 'series') s
   where (s ->> 'all_day')::boolean = false;
  v_out := jsonb_build_object('from', w.w_from, 'until', w.w_until, 'capped', w.capped)
           || v_data
           || jsonb_build_object('timezone_definition',
                case when v_year is null then null
                     else agent_private.zone_definition(v_data ->> 'timezone', v_year) end);
  perform agent_private.audit(c.connection_id, 'export_events_ics', v_args,
                              jsonb_array_length(v_out -> 'events') || ' events, '
                              || jsonb_array_length(v_out -> 'series') || ' series');
  return v_out;
end
$$;

-- The caller's own answer to an event: yes, no or maybe. Never anyone else's.
create function public.agent_set_event_answer(p_event_id text, p_answer text) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_args jsonb := jsonb_build_object('event_id', p_event_id, 'answer', p_answer);
  v_old jsonb;
  v_new jsonb;
begin
  select * into c from agent_private.ctx(true);
  if p_answer is null or p_answer not in ('yes', 'no', 'maybe') then
    perform agent_private.audit(c.connection_id, 'set_event_answer', v_args, 'refused: answer must be yes, no or maybe');
    return jsonb_build_object('error', 'The answer must be yes, no or maybe.');
  end if;
  if p_event_id is null or not exists (select 1 from public.events e where e.id = p_event_id) then
    perform agent_private.audit(c.connection_id, 'set_event_answer', v_args, 'refused: no such event');
    return jsonb_build_object('error', 'No such event.');
  end if;
  select jsonb_build_object('event_id', a.event_id, 'answer', a.desire_to_attend) into v_old
    from public.attendances a where a.event_id = p_event_id and a.person_id = c.person_id;
  insert into public.attendances (event_id, person_id, desire_to_attend)
  values (p_event_id, c.person_id, p_answer)
  on conflict (event_id, person_id) do update set desire_to_attend = excluded.desire_to_attend;
  select jsonb_build_object('event_id', a.event_id, 'answer', a.desire_to_attend) into v_new
    from public.attendances a where a.event_id = p_event_id and a.person_id = c.person_id;
  perform agent_private.audit(c.connection_id, 'set_event_answer', v_args, 'set ' || p_answer, v_old, v_new);
  return v_new;
end
$$;

-- Only the signed-in role may run them (the connector switches to it), and
-- every one of them is refused by agent_private.ctx() unless it was reached
-- through the connector.
revoke all on function
  public.agent_whoami(), public.agent_list_prospects(int), public.agent_add_prospect(text, text),
  public.agent_update_prospect(text, jsonb), public.agent_list_upcoming_events(date, date, timestamptz),
  public.agent_export_events_ics(date, date), public.agent_set_event_answer(text, text)
  from public, anon, service_role;
grant execute on function
  public.agent_whoami(), public.agent_list_prospects(int), public.agent_add_prospect(text, text),
  public.agent_update_prospect(text, jsonb), public.agent_list_upcoming_events(date, date, timestamptz),
  public.agent_export_events_ics(date, date), public.agent_set_event_answer(text, text)
  to authenticated;

-- The helpers are called by the tools above, which run as the signed-in role. None is reachable from
-- outside: agent_private is not exposed by the Data API, and event_data reads as the caller, so it shows
-- nothing the caller's row-level security would not show them anyway.
revoke all on function
  agent_private.tz_offset(text, timestamptz), agent_private.fmt_offset(integer),
  agent_private.zoned_instant(timestamp, text), agent_private.fmt_local(timestamp),
  agent_private.fmt_utc(timestamptz), agent_private.series_rrule(text, date, date, boolean, text),
  agent_private.zone_transitions(text, integer, integer), agent_private.zone_definition(text, integer),
  agent_private.event_data(text, text, date, date, timestamptz), agent_private.event_window(text, date, date)
  from public, anon, service_role;
grant execute on function
  agent_private.tz_offset(text, timestamptz), agent_private.fmt_offset(integer),
  agent_private.zoned_instant(timestamp, text), agent_private.fmt_local(timestamp),
  agent_private.fmt_utc(timestamptz), agent_private.series_rrule(text, date, date, boolean, text),
  agent_private.zone_transitions(text, integer, integer), agent_private.zone_definition(text, integer),
  agent_private.event_data(text, text, date, date, timestamptz), agent_private.event_window(text, date, date)
  to authenticated;

-- END ORIGINAL 20261105000200_agent_tools.sql

-- BEGIN ORIGINAL 20261106000100_agent_people_tools.sql
-- Agent connector, part 3a: people and personal tools (plan: docs/plans/agent-connector-2026-11-14.md).
--
-- New tools (each one `agent_*` function here, one entry in supabase/functions/agent/tools.ts, tests in
-- pgTAP 047-049 and the vitest files):
--   list_team         the caller's registered downline, with levels and sponsors
--   list_customers    the caller's customers
--   get_person        one person the caller can see
--   update_my_profile the caller's own full_name, phone, email, location
--   log_learning      one learning entry for the caller
--   list_learning     the caller's own entries in a window, with totals per kind
-- Changed tools: list_prospects (search, offset, total, sponsor name, vCard field names, a note when empty;
-- the old one-argument signature is dropped) and whoami (`can`, `team_size`).
--
-- Every tool is SECURITY INVOKER and starts with agent_private.ctx(), like the first seven: they run as the
-- person, so row-level security decides what they see and change. Contact fields use the names of vCard
-- (RFC 6350): full_name (FN), phone (TEL), email (EMAIL), location (ADR locality and region as one text),
-- notes (NOTE). Never read or written by any tool here: IBO#, LTD#. Never written: stage, sponsor, owner,
-- business start date, pipeline stage, stage history, tags, monthly volume. No deletes.

-- ---------------------------------------------------------------------------
-- The caller's registered downline
-- ---------------------------------------------------------------------------

-- Everyone below p_me on the sponsor line whose effective stage is apprentice or IBO: their contact fields,
-- their sponsor and how many steps below p_me they are (1 = sponsored by p_me). It reads public.people as the
-- caller, so a person the caller cannot see (row-level security) is not in it and is not walked through; for
-- a person's own downline that is nobody, since the caller sees their whole downline. Customers have no
-- sponsor and are never on the line. ONE recursive query, however big the team, with the columns carried
-- along so nothing is joined back afterwards (the depth guard only stops corrupt cyclic data).
create function agent_private.team(p_me text)
returns table (id text, level integer, name text, stage text, sponsor_id text, phone text, email text,
               location text, business_start_date date)
language sql
stable
security invoker
set search_path = ''
as $$
  with recursive down (id, level, name, biz_class, business_start_date, sponsor_id, phone, email, location) as (
    select p.id, 1, p.name, p.biz_class, p.business_start_date, p.sponsor_id, p.phone, p.email, p.location
      from public.people p
     where p.sponsor_id = p_me and p.biz_class <> 'customer' and p.id <> p_me
    union all
    select p.id, d.level + 1, p.name, p.biz_class, p.business_start_date, p.sponsor_id, p.phone, p.email, p.location
      from public.people p
      join down d on p.sponsor_id = d.id
     where p.biz_class <> 'customer' and p.id <> p_me and d.level < 100
  )
  select d.id, d.level, d.name, public.effective_biz_class(d.biz_class, d.business_start_date), d.sponsor_id,
         d.phone, d.email, d.location, d.business_start_date
    from down d
   where public.effective_biz_class(d.biz_class, d.business_start_date) in ('apprentice', 'ibo')
$$;

-- Text for an `ilike` that matches the search as plain text (no % or _ wildcards of its own).
create function agent_private.like_pattern(p_search text) returns text
language sql
immutable
set search_path = ''
as $$
  select '%' || replace(replace(replace(p_search, '\', '\\'), '%', '\%'), '_', '\_') || '%'
$$;

-- ---------------------------------------------------------------------------
-- whoami: what this connection can call, and how big the team is
-- ---------------------------------------------------------------------------

create or replace function public.agent_whoami() returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_out jsonb;
  v_read constant text[] := array['whoami', 'list_prospects', 'list_team', 'list_customers', 'get_person',
                                  'list_upcoming_events', 'export_events_ics', 'list_learning'];
  v_write constant text[] := array['add_prospect', 'update_prospect', 'update_my_profile', 'log_learning',
                                   'set_event_answer'];
begin
  select * into c from agent_private.ctx(false);
  select jsonb_build_object(
           'person', jsonb_build_object(
             'id', p.id,
             'name', p.name,
             'stage', public.effective_biz_class(p.biz_class, p.business_start_date)),
           'team_role', (select m.role from public.members m
                          where m.user_id = auth.uid() and m.person_id = c.person_id limit 1),
           'team', (select w.name from public.workspaces w where w.id = c.workspace_id),
           'today', public.workspace_today(c.workspace_id),
           'access', c.access,
           'can', to_jsonb(case when c.access = 'write' then v_read || v_write else v_read end),
           'team_size', (select count(*)::int from agent_private.team(c.person_id)))
    into v_out
    from public.people p where p.id = c.person_id;
  perform agent_private.audit(c.connection_id, 'whoami', '{}'::jsonb, 'ok');
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- list_team
-- ---------------------------------------------------------------------------

-- The caller's DOWNLINE: registered people (effective stage apprentice or IBO) below them that they can see,
-- never the caller. Per person: id, full_name, stage (apprentice or ibo, the effective one), sponsor_id,
-- sponsor_name (null when the caller cannot see the sponsor), level (1 = sponsored by the caller, 2 = their
-- downline, ...), phone, email, location, business_start_date. Ordered by level, then name.
-- Result: {total, limit, offset, team, note?}.
create function public.agent_list_team(
  p_search text default null, p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_args jsonb := jsonb_build_object('search', p_search, 'limit', v_limit, 'offset', v_offset);
  v_res jsonb;
  v_total int;
  v_all int;
  v_note text;
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  if char_length(coalesce(p_search, '')) > 100 then
    perform agent_private.audit(c.connection_id, 'list_team', v_args, 'refused: search is too long');
    return jsonb_build_object('error', 'search must be at most 100 characters.');
  end if;
  with t as (
    select d.id, d.name, d.stage, d.sponsor_id, d.phone, d.email, d.location, d.business_start_date, d.level
      from agent_private.team(c.person_id) d
  ), hits as (
    select * from t where v_search is null or t.name ilike agent_private.like_pattern(v_search)
  ), page as (
    select * from hits order by level, lower(name), name, id limit v_limit offset v_offset
  )
  select jsonb_build_object(
           'total', (select count(*) from hits),
           'all', (select count(*) from t),
           'rows', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', g.id, 'full_name', g.name, 'stage', g.stage,
                      'sponsor_id', s.id, 'sponsor_name', s.name, 'level', g.level,
                      'phone', g.phone, 'email', g.email, 'location', g.location,
                      'business_start_date', g.business_start_date)
                    order by g.level, lower(g.name), g.name, g.id)
               from page g left join public.people s on s.id = g.sponsor_id), '[]'::jsonb))
    into v_res;
  v_total := (v_res ->> 'total')::int;
  v_all := (v_res ->> 'all')::int;
  v_note := case
    when v_all = 0 then 'You have no registered team members under you yet.'
    when v_total = 0 then 'No team member matches that search.'
    when jsonb_array_length(v_res -> 'rows') = 0 then 'offset is past the last team member (total ' || v_total || ').'
  end;
  v_out := jsonb_build_object('total', v_total, 'limit', v_limit, 'offset', v_offset, 'team', v_res -> 'rows')
           || case when v_note is null then '{}'::jsonb else jsonb_build_object('note', v_note) end;
  perform agent_private.audit(c.connection_id, 'list_team', v_args,
                              jsonb_array_length(v_res -> 'rows') || ' of ' || v_total || ' rows');
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- list_prospects (replaced: search, offset, total, sponsor, vCard names, a note when empty)
-- ---------------------------------------------------------------------------

drop function public.agent_list_prospects(int);

-- The prospects (people not registered yet) the caller can see: their own and their downline's. Per
-- prospect: id, full_name, phone, email, location, notes, sponsor_id and sponsor_name (whose prospect it is).
-- Ordered by name. Result: {total, limit, offset, prospects, note?}.
create function public.agent_list_prospects(
  p_limit int default 50, p_search text default null, p_offset int default 0) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_args jsonb := jsonb_build_object('limit', v_limit, 'search', p_search, 'offset', v_offset);
  v_res jsonb;
  v_total int;
  v_all int;
  v_note text;
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  if char_length(coalesce(p_search, '')) > 100 then
    perform agent_private.audit(c.connection_id, 'list_prospects', v_args, 'refused: search is too long');
    return jsonb_build_object('error', 'search must be at most 100 characters.');
  end if;
  with t as (
    select p.id, p.name, p.phone, p.email, p.location, p.notes, p.sponsor_id
      from public.people p where p.biz_class = 'prospect'
  ), hits as (
    select * from t where v_search is null or t.name ilike agent_private.like_pattern(v_search)
  ), page as (
    select * from hits order by lower(name), name, id limit v_limit offset v_offset
  )
  select jsonb_build_object(
           'total', (select count(*) from hits),
           'all', (select count(*) from t),
           'rows', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', g.id, 'full_name', g.name, 'phone', g.phone, 'email', g.email,
                      'location', g.location, 'notes', g.notes,
                      'sponsor_id', s.id, 'sponsor_name', s.name)
                    order by lower(g.name), g.name, g.id)
               from page g left join public.people s on s.id = g.sponsor_id), '[]'::jsonb))
    into v_res;
  v_total := (v_res ->> 'total')::int;
  v_all := (v_res ->> 'all')::int;
  v_note := case
    when v_all = 0 then 'No prospects yet. Use add_prospect to add one; registered team members are in list_team.'
    when v_total = 0 then 'No prospect matches that search.'
    when jsonb_array_length(v_res -> 'rows') = 0 then 'offset is past the last prospect (total ' || v_total || ').'
  end;
  v_out := jsonb_build_object('total', v_total, 'limit', v_limit, 'offset', v_offset, 'prospects', v_res -> 'rows')
           || case when v_note is null then '{}'::jsonb else jsonb_build_object('note', v_note) end;
  perform agent_private.audit(c.connection_id, 'list_prospects', v_args,
                              jsonb_array_length(v_res -> 'rows') || ' of ' || v_total || ' rows');
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- list_customers
-- ---------------------------------------------------------------------------

-- The customers the caller can see. Customers are private to their owner (the app and the database show a
-- person only their own, a leader's included), so that is the caller's own customers; mine_only = false
-- asks for "every customer I can see", which is the same list today and stays right if that ever changes.
-- Per customer: id, full_name, phone, email, location, owner_id, owner_name. Ordered by name.
-- Result: {total, limit, offset, customers, note?}.
create function public.agent_list_customers(
  p_mine_only boolean default true, p_search text default null, p_limit int default 50, p_offset int default 0)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_mine boolean := coalesce(p_mine_only, true);
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_args jsonb := jsonb_build_object('mine_only', v_mine, 'search', p_search, 'limit', v_limit, 'offset', v_offset);
  v_res jsonb;
  v_total int;
  v_all int;
  v_note text;
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  if char_length(coalesce(p_search, '')) > 100 then
    perform agent_private.audit(c.connection_id, 'list_customers', v_args, 'refused: search is too long');
    return jsonb_build_object('error', 'search must be at most 100 characters.');
  end if;
  with t as (
    select p.id, p.name, p.phone, p.email, p.location, p.owner_id
      from public.people p
     where p.biz_class = 'customer' and (not v_mine or p.owner_id = c.person_id)
  ), hits as (
    select * from t where v_search is null or t.name ilike agent_private.like_pattern(v_search)
  ), page as (
    select * from hits order by lower(name), name, id limit v_limit offset v_offset
  )
  select jsonb_build_object(
           'total', (select count(*) from hits),
           'all', (select count(*) from t),
           'rows', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', g.id, 'full_name', g.name, 'phone', g.phone, 'email', g.email,
                      'location', g.location, 'owner_id', o.id, 'owner_name', o.name)
                    order by lower(g.name), g.name, g.id)
               from page g left join public.people o on o.id = g.owner_id), '[]'::jsonb))
    into v_res;
  v_total := (v_res ->> 'total')::int;
  v_all := (v_res ->> 'all')::int;
  v_note := case
    when v_all = 0 then 'No customers yet.'
    when v_total = 0 then 'No customer matches that search.'
    when jsonb_array_length(v_res -> 'rows') = 0 then 'offset is past the last customer (total ' || v_total || ').'
  end;
  v_out := jsonb_build_object('total', v_total, 'limit', v_limit, 'offset', v_offset, 'customers', v_res -> 'rows')
           || case when v_note is null then '{}'::jsonb else jsonb_build_object('note', v_note) end;
  perform agent_private.audit(c.connection_id, 'list_customers', v_args,
                              jsonb_array_length(v_res -> 'rows') || ' of ' || v_total || ' rows');
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- get_person
-- ---------------------------------------------------------------------------

-- One person the caller can see, by id. kind: self, team (registered), prospect or customer. Fields: id,
-- kind, full_name, phone, email, location, notes; for self and team also stage (effective) and
-- business_start_date; for team their level below the caller (when they are in the caller's downline);
-- sponsor {id, name} (customers: owner {id, name}), null when the caller cannot see that person. A person
-- the caller cannot see, or an id that does not exist, gives the same refusal: no hint which.
create function public.agent_get_person(p_id text) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_args jsonb := jsonb_build_object('id', p_id);
  r record;
  v_kind text;
  v_level int;
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  select p.id, p.name, p.phone, p.email, p.location, p.notes, p.biz_class, p.business_start_date,
         public.effective_biz_class(p.biz_class, p.business_start_date) as stage,
         (select jsonb_build_object('id', s.id, 'name', s.name) from public.people s
           where s.id = case when p.biz_class = 'customer' then p.owner_id else p.sponsor_id end) as related
    into r
    from public.people p where p.id = p_id;
  if not found then
    perform agent_private.audit(c.connection_id, 'get_person', v_args, 'refused: no such person among the visible ones');
    return jsonb_build_object('error', 'No such person among the people you can see.');
  end if;
  v_kind := case when r.id = c.person_id then 'self' when r.biz_class = 'prospect' then 'prospect'
                 when r.biz_class = 'customer' then 'customer' else 'team' end;
  v_out := jsonb_build_object('id', r.id, 'kind', v_kind, 'full_name', r.name, 'phone', r.phone,
                              'email', r.email, 'location', r.location, 'notes', r.notes);
  if v_kind in ('self', 'team') then
    v_out := v_out || jsonb_build_object('stage', r.stage, 'business_start_date', r.business_start_date);
  end if;
  if v_kind = 'team' then
    select t.level into v_level from agent_private.team(c.person_id) t where t.id = r.id;
    if v_level is not null then
      v_out := v_out || jsonb_build_object('level', v_level);
    end if;
  end if;
  v_out := v_out || jsonb_build_object(case when v_kind = 'customer' then 'owner' else 'sponsor' end, r.related);
  -- The person looked up, recorded where add_prospect records its person (new_values), so the app's activity
  -- list can show the name.
  perform agent_private.audit(c.connection_id, 'get_person', v_args, 'viewed ' || v_kind, null,
                              jsonb_build_object('id', r.id, 'name', r.name));
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- update_my_profile
-- ---------------------------------------------------------------------------

-- The caller's OWN record: full_name, phone, email, location. Anything else in the patch is refused, naming
-- the field, and nothing changes. The e-mail is contact information and does not change the sign-in address.
create function public.agent_update_my_profile(p_patch jsonb) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_args jsonb := jsonb_build_object('patch', p_patch);
  v_key text;
  v_bad text;
  v_max int;
  v_old jsonb;
  v_new jsonb;
  v_allowed constant text[] := array['full_name', 'phone', 'email', 'location'];
begin
  select * into c from agent_private.ctx(true);
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    perform agent_private.audit(c.connection_id, 'update_my_profile', v_args, 'refused: empty patch');
    return jsonb_build_object('error', 'Nothing to change: give at least one of full_name, phone, email, location.');
  end if;
  select string_agg('"' || left(k, 40) || '"', ', ' order by k) into v_bad
    from jsonb_object_keys(p_patch) k where not (k = any (v_allowed));
  if v_bad is not null then
    perform agent_private.audit(c.connection_id, 'update_my_profile', v_args,
                                left('refused: field ' || v_bad || ' is not allowed', 500));
    return jsonb_build_object('error',
      'Only full_name, phone, email and location can be changed here; ' || v_bad || ' cannot. Nothing was changed.');
  end if;
  for v_key in select jsonb_object_keys(p_patch) loop
    v_max := case v_key when 'full_name' then 120 when 'phone' then 40 else 200 end;
    if jsonb_typeof(p_patch -> v_key) not in ('string', 'null')
       or (v_key = 'full_name' and (jsonb_typeof(p_patch -> 'full_name') <> 'string' or btrim(p_patch ->> 'full_name') = ''))
       or char_length(coalesce(p_patch ->> v_key, '')) > v_max then
      perform agent_private.audit(c.connection_id, 'update_my_profile', v_args, 'refused: bad value for ' || v_key);
      return jsonb_build_object('error',
        '"' || v_key || '" must be text of at most ' || v_max || ' characters or null (full_name cannot be empty or null). Nothing was changed.');
    end if;
  end loop;

  select jsonb_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'email', p.email, 'location', p.location)
    into v_old from public.people p where p.id = c.person_id;
  if v_old is null then
    perform agent_private.audit(c.connection_id, 'update_my_profile', v_args, 'refused: own record not found');
    return jsonb_build_object('error', 'Your record could not be found. Nothing was changed.');
  end if;
  update public.people p set
    name = case when p_patch ? 'full_name' then btrim(p_patch ->> 'full_name') else p.name end,
    phone = case when p_patch ? 'phone' then nullif(btrim(p_patch ->> 'phone'), '') else p.phone end,
    email = case when p_patch ? 'email' then nullif(btrim(p_patch ->> 'email'), '') else p.email end,
    location = case when p_patch ? 'location' then nullif(btrim(p_patch ->> 'location'), '') else p.location end,
    last_updated_at = now()
   where p.id = c.person_id
  returning jsonb_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'email', p.email, 'location', p.location)
    into v_new;
  if v_new is null then
    perform agent_private.audit(c.connection_id, 'update_my_profile', v_args, 'refused: not allowed to change that record');
    return jsonb_build_object('error', 'You are not allowed to change that record. Nothing was changed.');
  end if;
  perform agent_private.audit(c.connection_id, 'update_my_profile', v_args, 'updated own profile', v_old, v_new);
  return jsonb_build_object('id', v_new ->> 'id', 'full_name', v_new ->> 'name', 'phone', v_new ->> 'phone',
                            'email', v_new ->> 'email', 'location', v_new ->> 'location');
end
$$;

-- ---------------------------------------------------------------------------
-- log_learning, list_learning
-- ---------------------------------------------------------------------------

-- One learning entry for the caller, validated the way the app's form and the table do:
--   kind    pages (reading), podcast, workshop or conference;
--   unit    reading: minutes, pages (default) or chapters; podcast: minutes or episodes (default); none for a
--           workshop or conference (the app logs those as one entry: amount is 1 or left out);
--   amount  a whole number from 1 for reading and podcasts (required there);
--   title   optional; empty is stored as 'Unnamed', as the app does;
--   date    default the team's today; not in the future; not before 2000-01-01 (the app's form has no limit,
--           the bound only catches a typo such as a year 0026).
-- Returns the stored entry: {id, kind, title, amount, unit, date, created_at}.
create function public.agent_log_learning(
  p_kind text, p_title text default null, p_amount int default null, p_unit text default null,
  p_date date default null) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_args jsonb := jsonb_build_object('kind', p_kind, 'title', p_title, 'amount', p_amount, 'unit', p_unit, 'date', p_date);
  v_today date;
  v_date date;
  v_title text := coalesce(nullif(btrim(coalesce(p_title, '')), ''), 'Unnamed');
  v_unit text;
  v_amount int;
  v_id text := gen_random_uuid()::text;
  v_out jsonb;
  v_problem text;
begin
  select * into c from agent_private.ctx(true);
  v_today := public.workspace_today(c.workspace_id);
  v_date := coalesce(p_date, v_today);
  if p_kind is null or p_kind not in ('pages', 'podcast', 'workshop', 'conference') then
    v_problem := 'kind must be one of pages (reading), podcast, workshop, conference.';
  elsif char_length(coalesce(p_title, '')) > 200 then
    v_problem := 'title must be at most 200 characters.';
  elsif v_date > v_today then
    v_problem := 'date must not be in the future (the team''s today is ' || v_today || ').';
  elsif v_date < date '2000-01-01' then
    v_problem := 'date must be 2000-01-01 or later.';
  elsif p_kind in ('workshop', 'conference') then
    if p_unit is not null then
      v_problem := 'a ' || p_kind || ' takes no unit.';
    elsif p_amount is not null and p_amount <> 1 then
      v_problem := 'a ' || p_kind || ' is logged as one entry: leave amount out (or 1).';
    end if;
    v_unit := null;
    v_amount := 1;
  else
    v_unit := coalesce(p_unit, case p_kind when 'pages' then 'pages' else 'episodes' end);
    if p_kind = 'pages' and v_unit not in ('minutes', 'pages', 'chapters') then
      v_problem := 'for reading (pages) the unit must be minutes, pages or chapters.';
    elsif p_kind = 'podcast' and v_unit not in ('minutes', 'episodes') then
      v_problem := 'for a podcast the unit must be minutes or episodes.';
    elsif p_amount is null or p_amount < 1 or p_amount > 100000 then
      v_problem := 'amount is required: a whole number of ' || v_unit || ' from 1 to 100000.';
    end if;
    v_amount := p_amount;
  end if;
  if v_problem is not null then
    perform agent_private.audit(c.connection_id, 'log_learning', v_args, left('refused: ' || v_problem, 500));
    return jsonb_build_object('error', v_problem || ' Nothing was logged.');
  end if;
  -- A chosen id and no RETURNING, as add_prospect does.
  insert into public.learning (id, workspace_id, person_id, kind, title, amount, unit, date)
  values (v_id, c.workspace_id, c.person_id, p_kind, v_title, v_amount, v_unit, v_date);
  select jsonb_build_object('id', l.id, 'kind', l.kind, 'title', l.title, 'amount', trim_scale(l.amount),
                            'unit', l.unit, 'date', l.date, 'created_at', l.created_at)
    into v_out from public.learning l where l.id = v_id;
  perform agent_private.audit(c.connection_id, 'log_learning', v_args, 'logged ' || p_kind || ' ' || v_id, null, v_out);
  return v_out;
end
$$;

-- The caller's OWN learning entries (row-level security would also show their downline's) from `from` to
-- `until`, both dates inclusive (default: the last 30 days, ending on the team's today), newest first, with
-- totals per kind and unit over the whole window (units are never added together). An entry that has no unit
-- is shown in the one the app counts it in: pages for reading, episodes for podcasts. Entries are cut at
-- 500 (`truncated`); the totals are not. Result: {from, until, truncated, entries, totals}.
create function public.agent_list_learning(p_from date default null, p_until date default null) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_args jsonb := jsonb_build_object('from', p_from, 'until', p_until);
  v_today date;
  v_until date;
  v_from date;
  v_problem text;
  v_entries jsonb;
  v_more boolean;
  v_totals jsonb;
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  v_today := public.workspace_today(c.workspace_id);
  v_until := coalesce(p_until, case when p_from is null or p_from <= v_today then v_today else p_from end);
  v_from := coalesce(p_from, v_until - 29);
  if v_from < date '2000-01-01' or v_until > date '2100-01-01' then
    v_problem := 'from and until must be dates between 2000-01-01 and 2100-01-01.';
  elsif v_until < v_from then
    v_problem := 'until must not be before from.';
  elsif v_until - v_from > 366 then
    v_problem := 'the window can be at most 367 days.';
  end if;
  if v_problem is not null then
    perform agent_private.audit(c.connection_id, 'list_learning', v_args, 'refused: ' || v_problem);
    return jsonb_build_object('error', v_problem);
  end if;
  select coalesce(jsonb_agg(x.j order by x.rn) filter (where x.rn <= 500), '[]'::jsonb),
         coalesce(bool_or(x.rn > 500), false)
    into v_entries, v_more
    from (select row_number() over (order by l.date desc, l.created_at desc, l.id) as rn,
                 jsonb_build_object(
                   'id', l.id, 'kind', l.kind, 'title', l.title, 'amount', trim_scale(l.amount),
                   'unit', coalesce(l.unit, case l.kind when 'pages' then 'pages' when 'podcast' then 'episodes' end),
                   'date', l.date) as j
            from public.learning l
           where l.person_id = c.person_id and l.date between v_from and v_until
           order by l.date desc, l.created_at desc, l.id
           limit 501) x;
  select coalesce(jsonb_agg(jsonb_build_object('kind', y.kind, 'unit', y.unit, 'entries', y.n, 'amount', trim_scale(y.amount))
                            order by y.kind, y.unit), '[]'::jsonb)
    into v_totals
    from (select l.kind,
                 coalesce(l.unit, case l.kind when 'pages' then 'pages' when 'podcast' then 'episodes' end) as unit,
                 count(*)::int as n, sum(l.amount) as amount
            from public.learning l
           where l.person_id = c.person_id and l.date between v_from and v_until
           group by 1, 2) y;
  v_out := jsonb_build_object('from', v_from, 'until', v_until, 'truncated', v_more,
                              'entries', v_entries, 'totals', v_totals);
  perform agent_private.audit(c.connection_id, 'list_learning', v_args, jsonb_array_length(v_entries) || ' entries');
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- Who may run them: the signed-in role only (the connector switches to it); each is refused by
-- agent_private.ctx() unless reached through the connector.
-- ---------------------------------------------------------------------------

revoke all on function
  public.agent_list_team(text, int, int), public.agent_list_prospects(int, text, int),
  public.agent_list_customers(boolean, text, int, int), public.agent_get_person(text),
  public.agent_update_my_profile(jsonb),
  public.agent_log_learning(text, text, int, text, date), public.agent_list_learning(date, date)
  from public, anon, service_role;
grant execute on function
  public.agent_list_team(text, int, int), public.agent_list_prospects(int, text, int),
  public.agent_list_customers(boolean, text, int, int), public.agent_get_person(text),
  public.agent_update_my_profile(jsonb),
  public.agent_log_learning(text, text, int, text, date), public.agent_list_learning(date, date)
  to authenticated;

revoke all on function agent_private.team(text), agent_private.like_pattern(text) from public, anon, service_role;
grant execute on function agent_private.team(text), agent_private.like_pattern(text) to authenticated;

-- END ORIGINAL 20261106000100_agent_people_tools.sql

-- BEGIN ORIGINAL 20261108000100_card_tasks.sql
-- Pipeline cards: tasks, due dates and notes (part 1 of 2: the database and the agent tools; the app is part 2).
--
-- A card on either pipeline board (the recruiting board: a prospect; the customer board: a name on someone's list)
-- gains a checklist of TASKS and a running log of NOTES. The boards, their columns and moves are not changed, and
-- the cards' own booking columns (next_column, next_step_date, next_step_time) and note column are neither read nor
-- written by anything here. The card's due date is the earliest due date among its open tasks: there is no
-- due-date or assignee column on the cards.
--
-- Rows can also be written with no signed-in person (a migration running as the table owner): created_by, done_by,
-- assignee_id and author_id are nullable, nothing is required from a session, and the guards skip the who-may-do-what
-- checks for any writer that is not `authenticated`.
--
--   card_tasks   id, workspace_id, person_id | entry_id (the card), title, done, done_at, done_by, due_date, due_time,
--                assignee_id, position, created_by, created_at, updated_at
--   card_notes   id, workspace_id, person_id | entry_id (the card), author_id, body, created_at        (never edited)
--
-- HOW A TASK POINTS AT ITS CARD. A card is keyed by the prospect (pipeline_cards.person_id) or by the list name
-- (customer_cards.entry_id), but the board shows a card for EVERY prospect and EVERY list name: one that has never
-- moved has no stored row (the app's implicitCard() / implicitCustomerCard(); add_prospect and the People page leave
-- none), and undoing the move that created a card deletes its row while the prospect stays on the board. A task that
-- pointed at the stored row could not exist for those cards, and would vanish on an undo. So a task points at what
-- the card is about: `person_id` (the prospect, references people, recruiting board) or `entry_id` (the list name,
-- references list_entries, customer board), exactly one of them. Deleting the person, or the name from the list (which
-- also deletes its stored card), deletes the tasks and notes by cascade; the stored card row is not their parent.
--
-- WHO MAY DO WHAT. Exactly what the cards' own policies allow: whoever may read a card reads its tasks and notes;
-- whoever may edit a card adds, changes, ticks and deletes its tasks; whoever may read a card adds a note; an author
-- deletes their own note. The predicates are the cards' (recruiting: the prospect is in visible_person_ids() and the
-- caller is not a candidate; customer: list_entry_visible()), written so a policy tests membership once per
-- statement; pgTAP proves they agree with the stored cards' policies. The assignee, when set, must be the card's
-- owner (a prospect's sponsor; the list's owner) or the caller, and a registered person.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The list names the caller may read: the set form of list_entry_visible().
create function public.card_entry_ids() returns setof text
language sql stable security definer set search_path = ''
as $$
  select e.id
    from public.list_entries e
   where e.workspace_id = public.current_workspace_id()
     and not public.is_candidate()
     and e.owner_id in (select public.visible_person_ids())
$$;

-- A registered person: effective stage apprentice or IBO, or the team's leader.
create function public.card_task_registered(p_person_id text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
     where p.id = p_person_id
       and p.workspace_id = public.current_workspace_id()
       and (public.effective_biz_class(p.biz_class, p.business_start_date) in ('apprentice', 'ibo')
            or exists (select 1 from public.members m
                        where m.person_id = p.id and m.workspace_id = p.workspace_id and m.role = 'leader')))
$$;

-- The people the caller is an upline of: exactly the ids for which is_upline_of() is true, as one set.
create function public.card_upline_ids() returns setof text
language sql stable security definer set search_path = ''
as $$
  select v.id
    from public.visible_person_ids() v (id)
   where v.id is distinct from public.current_person_id()
     and v.id not in (select public.deputy_leader_ids())
     and exists (select 1 from public.people p
                  where p.id = v.id and p.biz_class <> 'customer'
                    and p.workspace_id = public.current_workspace_id())
$$;

-- Who owns a card: a prospect's sponsor, a list's owner.
create function public.card_owner(p_person_id text, p_entry_id text) returns text
language sql stable security definer set search_path = ''
as $$
  select case when p_person_id is not null
              then (select p.sponsor_id from public.people p
                     where p.id = p_person_id and p.id in (select public.visible_person_ids()))
              else (select e.owner_id from public.list_entries e
                     where e.id = p_entry_id and e.id in (select public.card_entry_ids())) end
$$;

revoke all on function
  public.card_entry_ids(), public.card_task_registered(text), public.card_upline_ids(), public.card_owner(text, text)
  from public, anon;
grant execute on function
  public.card_entry_ids(), public.card_task_registered(text), public.card_upline_ids(), public.card_owner(text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.card_tasks (
  id text primary key default gen_random_uuid()::text,
  workspace_id text not null default public.current_workspace_id()
    references public.workspaces (id) on delete cascade,
  -- The card: the prospect on the recruiting board, or the name on the customer board; exactly one.
  person_id text references public.people (id) on delete cascade,
  entry_id text references public.list_entries (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 200),
  done boolean not null default false,
  -- Stamped by a trigger when the task is ticked, cleared when it is unticked.
  done_at timestamptz,
  done_by text references public.people (id) on delete set null,
  -- A date, and a time of day on it: wall clock in the team's time zone (workspaces.timezone), like
  -- events.start_time. A time needs a date. No time means due at the end of that day.
  due_date date,
  due_time time,
  -- Who has to do it: the card's owner or the person who set it (checked by a trigger). Null: whoever owns the card.
  assignee_id text references public.people (id) on delete set null,
  position integer not null default 0 check (position >= 0),
  created_by text default public.current_person_id() references public.people (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint card_tasks_one_card check (num_nonnulls(person_id, entry_id) = 1),
  constraint card_tasks_due_time_needs_date check (due_time is null or due_date is not null),
  constraint card_tasks_done_stamp check (done = (done_at is not null))
);
comment on table public.card_tasks is
  'A checklist item on a pipeline card (recruiting: the prospect; customer: the list name). Read and edited by whoever reads and edits the card.';
comment on column public.card_tasks.due_time is
  'Wall-clock time on due_date in the team''s time zone (workspaces.timezone); null = no time (due at the end of the day).';
create index card_tasks_person_idx on public.card_tasks (person_id, position) where person_id is not null;
create index card_tasks_entry_idx on public.card_tasks (entry_id, position) where entry_id is not null;
create index card_tasks_assignee_idx on public.card_tasks (assignee_id) where assignee_id is not null and not done;
create index card_tasks_workspace_due_idx on public.card_tasks (workspace_id, due_date);

create table public.card_notes (
  id text primary key default gen_random_uuid()::text,
  workspace_id text not null default public.current_workspace_id()
    references public.workspaces (id) on delete cascade,
  person_id text references public.people (id) on delete cascade,
  entry_id text references public.list_entries (id) on delete cascade,
  -- Always the caller on a client write (set by a trigger). Null if the author was removed.
  author_id text default public.current_person_id() references public.people (id) on delete set null,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  constraint card_notes_one_card check (num_nonnulls(person_id, entry_id) = 1)
);
comment on table public.card_notes is 'The running log of a pipeline card, newest last by created_at. Notes are never edited.';
create index card_notes_person_idx on public.card_notes (person_id, created_at desc) where person_id is not null;
create index card_notes_entry_idx on public.card_notes (entry_id, created_at desc) where entry_id is not null;

-- ---------------------------------------------------------------------------
-- Guards and stamps (direct client writes: the app and the agent connector run as `authenticated`; the database's
-- own functions and the seed skip the who-may-do-what checks, like every other guard trigger)
-- ---------------------------------------------------------------------------

create function public.card_tasks_guard() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_me text := public.current_person_id();
  v_client boolean := public.is_client_write();
  v_ws text;
  v_owner text;
  v_biz text;
begin
  new.title := btrim(new.title);
  if new.person_id is not null then
    select p.workspace_id, p.sponsor_id, p.biz_class into v_ws, v_owner, v_biz
      from public.people p where p.id = new.person_id;
  else
    select e.workspace_id, e.owner_id into v_ws, v_owner
      from public.list_entries e where e.id = new.entry_id;
  end if;
  -- A client write to a card that does not exist (or is not readable) is refused. The database's own writes (a
  -- foreign key setting created_by or assignee_id null while the card is being deleted, the migration role) go on.
  if v_ws is null and v_client then
    raise exception 'No such card' using errcode = '42501';
  end if;
  if v_ws is not null and v_ws is distinct from new.workspace_id then
    raise exception 'The card is in another team' using errcode = '23514';
  end if;

  if tg_op = 'INSERT' then
    if v_client then
      if new.person_id is not null and v_biz is distinct from 'prospect' then
        raise exception 'Only a prospect has a card on the recruiting board' using errcode = '23514';
      end if;
      new.created_by := v_me;
      new.created_at := now();
      new.updated_at := now();
    end if;
    -- (the database's own writes, a migration, keep the created_at / updated_at they give)
  elsif v_client and (new.id is distinct from old.id or new.workspace_id is distinct from old.workspace_id
                      or new.person_id is distinct from old.person_id or new.entry_id is distinct from old.entry_id
                      or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at) then
    raise exception 'A task cannot move to another card, and who made it and when cannot change' using errcode = '42501';
  end if;

  -- The assignee: the card's owner or the caller, and registered.
  if v_client and new.assignee_id is not null
     and (tg_op = 'INSERT' or new.assignee_id is distinct from old.assignee_id) then
    if not (new.assignee_id = v_me or new.assignee_id is not distinct from v_owner)
       or not public.card_task_registered(new.assignee_id) then
      raise exception 'A task goes to the card''s owner or to you' using errcode = '42501';
    end if;
  end if;

  -- done_at / done_by: stamped when ticked, cleared when unticked, never taken from the client.
  if tg_op = 'INSERT' then
    if new.done then
      if v_client or new.done_at is null then
        new.done_at := now();
        new.done_by := coalesce(new.done_by, v_me);
      end if;
    else
      new.done_at := null;
      new.done_by := null;
    end if;
  elsif not new.done then
    new.done_at := null;
    new.done_by := null;
  elsif not old.done then
    if v_client or new.done_at is null then
      new.done_at := now();
      new.done_by := case when v_client then v_me else coalesce(new.done_by, v_me) end;
    end if;
  elsif v_client then
    new.done_at := old.done_at;
    new.done_by := old.done_by;
  end if;
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create trigger card_tasks_guard before insert or update on public.card_tasks
  for each row execute function public.card_tasks_guard();

create function public.card_notes_guard() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_ws text;
begin
  new.body := btrim(new.body);
  if new.person_id is not null then
    select p.workspace_id into v_ws from public.people p where p.id = new.person_id;
  else
    select e.workspace_id into v_ws from public.list_entries e where e.id = new.entry_id;
  end if;
  if v_ws is null and public.is_client_write() then
    raise exception 'No such card' using errcode = '42501';
  end if;
  if v_ws is not null and v_ws is distinct from new.workspace_id then
    raise exception 'The card is in another team' using errcode = '23514';
  end if;
  if public.is_client_write() then
    new.author_id := public.current_person_id();
    new.created_at := now();
  end if;
  return new;
end;
$$;

create trigger card_notes_guard before insert on public.card_notes
  for each row execute function public.card_notes_guard();

revoke execute on function public.card_tasks_guard(), public.card_notes_guard() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Row-level security: the cards' own rules
-- ---------------------------------------------------------------------------

alter table public.card_tasks enable row level security;
alter table public.card_notes enable row level security;

revoke all on public.card_tasks, public.card_notes from public, anon, authenticated;
grant select, insert, update, delete on public.card_tasks, public.card_notes to authenticated;

-- Recruiting: "read cards of visible people" / "edit cards of visible people" (pipeline_cards): the prospect is in
-- visible_person_ids() and the caller is not a candidate. Customer: "read customer cards of your team" / "edit
-- customer cards of your team": list_entry_visible(entry_id). Reading and editing are the same people on both boards.
create policy "read tasks of your cards" on public.card_tasks
  for select to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and ((person_id is not null and person_id in (select public.visible_person_ids())
               and not (select public.is_candidate()))
              or (entry_id is not null and entry_id in (select public.card_entry_ids()))));
create policy "add tasks to your cards" on public.card_tasks
  for insert to authenticated
  with check (workspace_id = (select public.current_workspace_id())
              and ((person_id is not null and person_id in (select public.visible_person_ids())
                    and not (select public.is_candidate()))
                   or (entry_id is not null and entry_id in (select public.card_entry_ids()))));
create policy "change tasks of your cards" on public.card_tasks
  for update to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and ((person_id is not null and person_id in (select public.visible_person_ids())
               and not (select public.is_candidate()))
              or (entry_id is not null and entry_id in (select public.card_entry_ids()))));
create policy "remove tasks of your cards" on public.card_tasks
  for delete to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and ((person_id is not null and person_id in (select public.visible_person_ids())
               and not (select public.is_candidate()))
              or (entry_id is not null and entry_id in (select public.card_entry_ids()))));

-- Notes: whoever reads the card reads and adds notes (as themself); the author deletes their own; no edits.
create policy "read notes of your cards" on public.card_notes
  for select to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and ((person_id is not null and person_id in (select public.visible_person_ids())
               and not (select public.is_candidate()))
              or (entry_id is not null and entry_id in (select public.card_entry_ids()))));
create policy "add notes to your cards" on public.card_notes
  for insert to authenticated
  with check (workspace_id = (select public.current_workspace_id())
              and author_id = (select public.current_person_id())
              and ((person_id is not null and person_id in (select public.visible_person_ids())
                    and not (select public.is_candidate()))
                   or (entry_id is not null and entry_id in (select public.card_entry_ids()))));
create policy "authors remove their notes" on public.card_notes
  for delete to authenticated
  using (workspace_id = (select public.current_workspace_id())
         and author_id = (select public.current_person_id())
         and ((person_id is not null and person_id in (select public.visible_person_ids())
               and not (select public.is_candidate()))
              or (entry_id is not null and entry_id in (select public.card_entry_ids()))));

-- ---------------------------------------------------------------------------
-- Agent tools (plan: docs/plans/agent-connector-2026-11-14.md). One `agent_*` function each here and one entry in
-- supabase/functions/agent/tools.ts. They run as the person, so the policies above decide what is seen and changed.
-- A task is a VTODO (iCalendar, RFC 5545): uid, summary, due, status NEEDS-ACTION / COMPLETED, completed, created,
-- last_modified, with the CRM's own fields beside it. No tool creates, moves, books or deletes a card, and none
-- deletes a task or a note. IBO# and LTD# are read by none of them.
-- ---------------------------------------------------------------------------

-- Names for ids, as the caller: people they can read, else the chat directory (an upline who took a task on a
-- downline's card is not a person the downline can read, but is in the directory). The directory is only read
-- when a name is missing.
create function agent_private.card_names(p_ids text[]) returns table (id text, name text)
language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_missing text[];
begin
  return query select p.id, p.name from public.people p where p.id = any (p_ids);
  select array(select x from unnest(p_ids) x where x is not null and not exists (select 1 from public.people p where p.id = x))
    into v_missing;
  if cardinality(v_missing) > 0 then
    return query select d.person_id, d.name from public.chat_directory d where d.person_id = any (v_missing);
  end if;
end
$$;

-- One card as the caller may address it: board 'recruiting' (p_id is a prospect's id) or 'customer' (p_id is the id
-- of a name on a list). Nothing when it does not exist or the caller cannot read it (row-level security).
create function agent_private.card_lookup(p_board text, p_id text)
returns table (board text, card_id text, person_id text, entry_id text, name text, owner_id text,
               workspace_id text, off_board boolean)
language sql stable security invoker set search_path = ''
as $$
  select 'recruiting'::text, p.id, p.id, null::text, p.name, p.sponsor_id, p.workspace_id,
         coalesce(c.dropped_at is not null, false)
    from public.people p
    left join public.pipeline_cards c on c.person_id = p.id
   where p_board = 'recruiting' and p.id = p_id and p.biz_class = 'prospect'
  union all
  select 'customer'::text, e.id, null::text, e.id, e.name, e.owner_id, e.workspace_id, false
    from public.list_entries e
   where p_board = 'customer' and e.id = p_id
$$;

-- The audit row's "what it was about", where add_prospect records its prospect (new_values): the card's person id
-- and name (for the customer board: the list name's id and name) and the board.
create function agent_private.card_stamp(p_board text, p_id text) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select jsonb_build_object('id', k.card_id, 'name', k.name, 'board', k.board)
    from agent_private.card_lookup(p_board, p_id) k
$$;

create function agent_private.task_stamp(p_task_id text) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select jsonb_build_object('task_id', t.id, 'title', t.title, 'done', t.done, 'due_date', t.due_date,
                            'due_time', to_char(t.due_time, 'HH24:MI'), 'assignee_id', t.assignee_id)
    from public.card_tasks t where t.id = p_task_id
$$;

-- Tasks as tool results (VTODO plus the CRM's fields), in the order of p_ids; the ones the caller can read.
create function agent_private.card_task_docs(p_ids text[], p_workspace text) returns setof jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_tz text;
begin
  select w.timezone into v_tz from public.workspaces w where w.id = p_workspace;
  return query
  with ts as (
    select u.n, t.id, t.person_id, t.entry_id, t.title, t.done, t.done_at, t.done_by, t.due_date, t.due_time,
           t.assignee_id, t.position, t.created_at, t.updated_at
      from unnest(p_ids) with ordinality u (id, n)
      join public.card_tasks t on t.id = u.id
  ), nm as (
    select * from agent_private.card_names(array(select x.assignee_id from ts x where x.assignee_id is not null
                                                 union select x.done_by from ts x where x.done_by is not null))
  )
  select jsonb_strip_nulls(jsonb_build_object(
           'id', ts.id,
           'uid', ts.id || '@card-tasks.invalid',
           'summary', ts.title,
           'status', case when ts.done then 'COMPLETED' else 'NEEDS-ACTION' end,
           'done', ts.done,
           'due', case when ts.due_date is null then null
                       when ts.due_time is null then to_jsonb(ts.due_date)
                       else to_jsonb(agent_private.fmt_local(ts.due_date + ts.due_time)) end,
           'due_date', ts.due_date,
           'due_time', to_char(ts.due_time, 'HH24:MI'),
           'timezone', case when ts.due_time is not null then v_tz end,
           'due_utc', case when ts.due_time is not null
                           then agent_private.fmt_utc(agent_private.zoned_instant(ts.due_date + ts.due_time, v_tz)) end,
           'completed', agent_private.fmt_utc(ts.done_at),
           'created', agent_private.fmt_utc(ts.created_at),
           'last_modified', agent_private.fmt_utc(ts.updated_at),
           'completed_by', case when ts.done_by is not null
                                then jsonb_build_object('id', ts.done_by, 'full_name', (select s.name from nm s where s.id = ts.done_by)) end))
         || jsonb_build_object(
              'card', jsonb_build_object(
                'board', case when ts.person_id is not null then 'recruiting' else 'customer' end,
                'person', jsonb_build_object('id', coalesce(ts.person_id, ts.entry_id),
                                             'full_name', coalesce(p.name, e.name))),
              'assignee', case when ts.assignee_id is null then null
                               else jsonb_build_object('id', ts.assignee_id, 'full_name', (select s.name from nm s where s.id = ts.assignee_id)) end,
              'position', ts.position)
    from ts
    left join public.people p on p.id = ts.person_id
    left join public.list_entries e on e.id = ts.entry_id
   order by ts.n;
end
$$;

-- Cards as tool results, in the order of the (board, id) pairs; the ones the caller can read (a recruiting card is a
-- prospect, with the stored card's column and booking if it has one, else Contact made; a customer card is a list
-- name, else Not contacted yet). p_detail 0: the summary; 1: + all the tasks; 2: + the notes (newest first, 100).
-- The column names are the caller's: board_columns() for the owner's board, with a renamed milestone shown as the
-- caller's own stage name (effective_stage_names(), the resolver the app uses). `next_due` (the earliest due among
-- the card's open tasks) is the card's due date. The card's booking columns are not read here.
create function agent_private.card_docs(p_boards text[], p_ids text[], p_caller text, p_workspace text, p_detail int)
returns setof jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_tz text;
begin
  select w.timezone into v_tz from public.workspaces w where w.id = p_workspace;
  return query
  with k as (
    select u.b as board, u.id, u.n from unnest(p_boards, p_ids) with ordinality u (b, id, n)
  ), cards as (
    select k.n, k.board, p.id as card_id, p.id as person_id, null::text as entry_id, p.name, p.sponsor_id as owner_id,
           null::text as customer_id, coalesce(c.column_id, 'contact') as column_id, (c.dropped_at is not null) as off_board
      from k
      join public.people p on k.board = 'recruiting' and p.id = k.id and p.biz_class = 'prospect'
      left join public.pipeline_cards c on c.person_id = p.id
    union all
    select k.n, k.board, e.id, null::text, e.id, e.name, e.owner_id, e.customer_id,
           coalesce(c.column_id, 'not_contacted'), false
      from k
      join public.list_entries e on k.board = 'customer' and e.id = k.id
      left join public.customer_cards c on c.entry_id = e.id
  ), tk as (
    select cd.n,
           count(t.id)::int as total,
           (count(t.id) filter (where t.done))::int as done_n,
           (array_agg(t.due_date order by t.due_date + coalesce(t.due_time, time '23:59:59.999999'))
              filter (where not t.done and t.due_date is not null))[1] as nd,
           (array_agg(t.due_time order by t.due_date + coalesce(t.due_time, time '23:59:59.999999'))
              filter (where not t.done and t.due_date is not null))[1] as nt,
           array_remove(array_agg(distinct t.assignee_id) filter (where not t.done), null) as assignees
      from cards cd
      left join public.card_tasks t on (t.person_id = cd.person_id or t.entry_id = cd.entry_id)
     group by cd.n
  ), nm as (
    select * from agent_private.card_names(array(
      select x.owner_id from cards x where x.owner_id is not null
      union select a from tk, unnest(tk.assignees) a
      union select n.author_id from public.card_notes n
             where p_detail >= 2 and (n.person_id in (select x.person_id from cards x) or n.entry_id in (select x.entry_id from cards x))))
  ), own as (
    select distinct x.board, coalesce(x.owner_id, p_caller) as owner from cards x
  ), cols as (
    select o.board, o.owner, bc.id, bc.label
      from own o cross join lateral public.board_columns(o.board, o.owner) bc
  ), sn as (
    select s.pipeline, s.stage_key, s.name from public.effective_stage_names(true) s
  )
  select jsonb_strip_nulls(jsonb_build_object(
           'board', cd.board,
           'customer_id', cd.customer_id,
           'off_board', case when cd.off_board then true end,
           'next_due', case when tk.nd is null then null
                            when tk.nt is null then to_jsonb(tk.nd)
                            else to_jsonb(agent_private.fmt_local(tk.nd + tk.nt)) end,
           'timezone', case when tk.nt is not null then v_tz end))
         || jsonb_build_object(
              'person', jsonb_build_object('id', cd.card_id, 'full_name', cd.name),
              'owner', case when cd.owner_id is null then null
                            else jsonb_build_object('id', cd.owner_id, 'full_name', (select s.name from nm s where s.id = cd.owner_id)) end,
              'column', jsonb_build_object('id', cd.column_id, 'name', coalesce(
                          (select s.name from sn s where s.pipeline = cd.board and s.stage_key = cd.column_id),
                          (select l.label from cols l where l.board = cd.board and l.owner = coalesce(cd.owner_id, p_caller) and l.id = cd.column_id),
                          'Removed column')),
              'tasks_done', tk.done_n,
              'tasks_total', tk.total,
              'assignees', coalesce((select jsonb_agg(jsonb_build_object('id', a, 'full_name', (select s.name from nm s where s.id = a))
                                                      order by (select s.name from nm s where s.id = a), a)
                                       from unnest(tk.assignees) a), '[]'::jsonb),
              'notes_count', (select count(*)::int from public.card_notes n
                               where n.person_id = cd.person_id or n.entry_id = cd.entry_id))
         || case when p_detail >= 1 then jsonb_build_object('tasks', coalesce((
                   select jsonb_agg(x.d order by x.n)
                     from agent_private.card_task_docs(array(select t.id from public.card_tasks t
                                                              where t.person_id = cd.person_id or t.entry_id = cd.entry_id
                                                              order by t.position, t.created_at, t.id), p_workspace) with ordinality x (d, n)),
                   '[]'::jsonb)) else '{}'::jsonb end
         || case when p_detail >= 2 then jsonb_build_object(
                   'notes', coalesce((select jsonb_agg(jsonb_build_object(
                                'id', q.id,
                                'author', case when q.author_id is null then null
                                               else jsonb_build_object('id', q.author_id, 'full_name', (select s.name from nm s where s.id = q.author_id)) end,
                                'body', q.body, 'created_at', agent_private.fmt_utc(q.created_at)) order by q.created_at desc, q.id desc)
                                from (select n.* from public.card_notes n
                                       where n.person_id = cd.person_id or n.entry_id = cd.entry_id
                                       order by n.created_at desc, n.id desc limit 100) q), '[]'::jsonb),
                   'notes_truncated', (select count(*) from public.card_notes n
                                        where n.person_id = cd.person_id or n.entry_id = cd.entry_id) > 100)
                 else '{}'::jsonb end
    from cards cd
    join tk on tk.n = cd.n
   order by cd.n;
end
$$;

revoke all on function
  agent_private.card_names(text[]), agent_private.card_lookup(text, text), agent_private.card_stamp(text, text),
  agent_private.task_stamp(text), agent_private.card_task_docs(text[], text),
  agent_private.card_docs(text[], text[], text, text, int)
  from public, anon, service_role;
grant execute on function
  agent_private.card_names(text[]), agent_private.card_lookup(text, text), agent_private.card_stamp(text, text),
  agent_private.task_stamp(text), agent_private.card_task_docs(text[], text),
  agent_private.card_docs(text[], text[], text, text, int)
  to authenticated;

-- ---------------------------------------------------------------------------
-- whoami: the new tools in `can`, and open_tasks (open tasks assigned to the caller, or unassigned on the caller's
-- own cards)
-- ---------------------------------------------------------------------------

create or replace function public.agent_whoami() returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_out jsonb;
  v_read constant text[] := array['whoami', 'list_prospects', 'list_team', 'list_customers', 'get_person',
                                  'list_upcoming_events', 'export_events_ics', 'list_learning',
                                  'list_cards', 'get_card', 'list_card_tasks'];
  v_write constant text[] := array['add_prospect', 'update_prospect', 'update_my_profile', 'log_learning',
                                   'set_event_answer', 'add_card_task', 'update_card_task', 'complete_card_task',
                                   'add_card_note'];
begin
  select * into c from agent_private.ctx(false);
  select jsonb_build_object(
           'person', jsonb_build_object(
             'id', p.id,
             'name', p.name,
             'stage', public.effective_biz_class(p.biz_class, p.business_start_date)),
           'team_role', (select m.role from public.members m
                          where m.user_id = auth.uid() and m.person_id = c.person_id limit 1),
           'team', (select w.name from public.workspaces w where w.id = c.workspace_id),
           'today', public.workspace_today(c.workspace_id),
           'access', c.access,
           'can', to_jsonb(case when c.access = 'write' then v_read || v_write else v_read end),
           'team_size', (select count(*)::int from agent_private.team(c.person_id)),
           'open_tasks', (select count(*)::int
                            from public.card_tasks t
                            left join public.people cp on cp.id = t.person_id
                            left join public.list_entries ce on ce.id = t.entry_id
                           where not t.done
                             and (t.assignee_id = c.person_id
                                  or (t.assignee_id is null and coalesce(cp.sponsor_id, ce.owner_id) = c.person_id))))
    into v_out
    from public.people p where p.id = c.person_id;
  perform agent_private.audit(c.connection_id, 'whoami', '{}'::jsonb, 'ok');
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- list_cards
-- ---------------------------------------------------------------------------

-- The cards the caller can read, one per prospect on the recruiting board and per name on the customer board (a card
-- that never moved has no stored row but is on the board all the same). Filters: board (all by default), person_id
-- (the prospect, or on the customer board the name's id or the linked customer's id), mine_only (default true: the
-- cards the caller owns), has_open_tasks (true: at least one open task, false: none), due_from / due_until (the
-- card's next due date: the earliest open task, inclusive), overdue (an open task due before the team's now; a task
-- with no time is due at the end of its day), search (the person's name). Cards with a next due first, by it, then
-- by name. Cards taken off the board are left out. Result: {total, limit, offset, timezone, cards, note?}.
create function public.agent_list_cards(
  p_board text default 'all', p_person_id text default null, p_mine_only boolean default true,
  p_has_open_tasks boolean default null, p_due_from date default null, p_due_until date default null,
  p_overdue boolean default false, p_search text default null, p_limit int default 50, p_offset int default 0)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_board text := coalesce(nullif(btrim(coalesce(p_board, '')), ''), 'all');
  v_mine boolean := coalesce(p_mine_only, true);
  v_overdue boolean := coalesce(p_overdue, false);
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_args jsonb;
  v_problem text;
  v_tz text;
  v_now timestamp;
  v_total int;
  v_all int;
  v_boards text[];
  v_ids text[];
  v_docs jsonb;
  v_filtered boolean;
  v_note text;
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  v_args := jsonb_build_object('board', v_board, 'person_id', p_person_id, 'mine_only', v_mine,
                               'has_open_tasks', p_has_open_tasks, 'due_from', p_due_from, 'due_until', p_due_until,
                               'overdue', v_overdue, 'search', p_search, 'limit', v_limit, 'offset', v_offset);
  if v_board not in ('recruiting', 'customer', 'all') then
    v_problem := 'board must be recruiting, customer or all.';
  elsif p_due_from is not null and p_due_until is not null and p_due_until < p_due_from then
    v_problem := 'due_until must not be before due_from.';
  elsif char_length(coalesce(p_search, '')) > 100 then
    v_problem := 'search must be at most 100 characters.';
  end if;
  if v_problem is not null then
    perform agent_private.audit(c.connection_id, 'list_cards', v_args, 'refused: ' || v_problem);
    return jsonb_build_object('error', v_problem);
  end if;
  select w.timezone into v_tz from public.workspaces w where w.id = c.workspace_id;
  v_now := now() at time zone v_tz;

  with base as (
    select 'recruiting'::text as board, p.id as card_id, p.name, p.sponsor_id as owner_id, null::text as customer_id,
           coalesce(k.dropped_at is not null, false) as off_board
      from public.people p
      left join public.pipeline_cards k on k.person_id = p.id
     where p.biz_class = 'prospect' and p.workspace_id = c.workspace_id
    union all
    select 'customer', e.id, e.name, e.owner_id, e.customer_id, false
      from public.list_entries e
     where e.workspace_id = c.workspace_id
  ), tk as (
    select t.person_id, t.entry_id,
           (count(*) filter (where not t.done))::int as open_n,
           min(t.due_date + coalesce(t.due_time, time '23:59:59.999999'))
             filter (where not t.done and t.due_date is not null) as nd
      from public.card_tasks t
     group by t.person_id, t.entry_id
  ), joined as (
    select b.board, b.card_id, b.name, b.owner_id, b.customer_id, coalesce(tk.open_n, 0) as open_n, tk.nd
      from base b
      left join tk on (b.board = 'recruiting' and tk.person_id = b.card_id)
                   or (b.board = 'customer' and tk.entry_id = b.card_id)
     where not b.off_board
  ), mineable as (
    select j.* from joined j where (not v_mine) or j.owner_id = c.person_id
  ), hits as (
    select m.*
      from mineable m
     where (v_board = 'all' or m.board = v_board)
       and (p_person_id is null or m.card_id = p_person_id or m.customer_id = p_person_id)
       and (p_has_open_tasks is null or (m.open_n > 0) = p_has_open_tasks)
       and (p_due_from is null or m.nd::date >= p_due_from)
       and (p_due_until is null or m.nd::date <= p_due_until)
       and (not v_overdue or m.nd < v_now)
       and (v_search is null or m.name ilike agent_private.like_pattern(v_search))
  ), page as (
    select h.board, h.card_id,
           row_number() over (order by (h.nd is null), h.nd, lower(h.name), h.name, h.board, h.card_id) as rn
      from hits h
     order by rn
     limit v_limit offset v_offset
  )
  select (select count(*)::int from hits), (select count(*)::int from mineable),
         coalesce((select array_agg(g.board order by g.rn) from page g), '{}'::text[]),
         coalesce((select array_agg(g.card_id order by g.rn) from page g), '{}'::text[])
    into v_total, v_all, v_boards, v_ids;

  select coalesce(jsonb_agg(d.doc order by d.n), '[]'::jsonb) into v_docs
    from agent_private.card_docs(v_boards, v_ids, c.person_id, c.workspace_id, 0) with ordinality d (doc, n);

  v_filtered := v_board <> 'all' or p_person_id is not null or p_has_open_tasks is not null or p_due_from is not null
                or p_due_until is not null or v_overdue or v_search is not null;
  v_note := case
    when v_total = 0 and v_all = 0 and v_mine then
      'You own no cards yet: a card is a prospect on the recruiting board or a name on the customer board, and a prospect has one as soon as add_prospect adds them. Use mine_only false to see your team''s cards.'
    when v_total = 0 and v_all = 0 then
      'There are no cards you can see: a card is a prospect on the recruiting board or a name on the customer board. Use add_prospect to add a prospect.'
    when v_total = 0 then
      'No card matches' || case when v_filtered then ' those filters' else '' end
      || case when v_mine then ' among the cards you own; mine_only false looks at your team''s too' else '' end || '.'
    when jsonb_array_length(v_docs) = 0 then 'offset is past the last card (total ' || v_total || ').'
  end;
  v_out := jsonb_build_object('total', v_total, 'limit', v_limit, 'offset', v_offset, 'timezone', v_tz, 'cards', v_docs)
           || case when v_note is null then '{}'::jsonb else jsonb_build_object('note', v_note) end;
  perform agent_private.audit(c.connection_id, 'list_cards', v_args,
                              jsonb_array_length(v_docs) || ' of ' || v_total || ' rows');
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- get_card
-- ---------------------------------------------------------------------------

-- One card with everything: its summary, all its tasks (in position order) and its notes (newest first, the 100
-- newest, `notes_truncated`). A card the caller cannot read, an id that is no card on that board and an id that does
-- not exist all give the same refusal.
create function public.agent_get_card(p_person_id text, p_board text default 'recruiting') returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_board text := coalesce(nullif(btrim(coalesce(p_board, '')), ''), 'recruiting');
  v_args jsonb := jsonb_build_object('person_id', p_person_id, 'board', p_board);
  k record;
  v_doc jsonb;
begin
  select * into c from agent_private.ctx(false);
  if v_board not in ('recruiting', 'customer') then
    perform agent_private.audit(c.connection_id, 'get_card', v_args, 'refused: board must be recruiting or customer');
    return jsonb_build_object('error', 'board must be recruiting or customer.');
  end if;
  select * into k from agent_private.card_lookup(v_board, p_person_id);
  if not found then
    perform agent_private.audit(c.connection_id, 'get_card', v_args, 'refused: no such card among the visible ones');
    return jsonb_build_object('error', 'No such card among the cards you can see on the ' || v_board || ' board.');
  end if;
  select d into v_doc from agent_private.card_docs(array[v_board], array[k.card_id], c.person_id, c.workspace_id, 2) d;
  perform agent_private.audit(c.connection_id, 'get_card', v_args, 'viewed card', null,
                              agent_private.card_stamp(v_board, k.card_id));
  return v_doc;
end
$$;

-- ---------------------------------------------------------------------------
-- list_card_tasks
-- ---------------------------------------------------------------------------

-- Tasks across the cards the caller can read. status (open by default, done, all); due_from / due_until (the due
-- date, inclusive); overdue (open and due before the team's now); assigned: me (default: assigned to the caller, or
-- unassigned on a card the caller owns), team (assigned to a person the caller is an upline of, or unassigned on a
-- card such a person owns), all (every task visible); person_id (the card: a prospect, or a list name's id or the
-- linked customer's); changed_since. Dated tasks first by due date and time (no time: end of the day), then the
-- undated by position. Result: {total, limit, offset, timezone, tasks, note?}.
create function public.agent_list_card_tasks(
  p_status text default 'open', p_due_from date default null, p_due_until date default null,
  p_overdue boolean default false, p_assigned text default 'me', p_person_id text default null,
  p_changed_since timestamptz default null, p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_status text := coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'open');
  v_assigned text := coalesce(nullif(btrim(coalesce(p_assigned, '')), ''), 'me');
  v_overdue boolean := coalesce(p_overdue, false);
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_args jsonb;
  v_problem text;
  v_tz text;
  v_now timestamp;
  v_total int;
  v_ids text[];
  v_docs jsonb;
  v_filtered boolean;
  v_note text;
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  v_args := jsonb_build_object('status', v_status, 'due_from', p_due_from, 'due_until', p_due_until,
                               'overdue', v_overdue, 'assigned', v_assigned, 'person_id', p_person_id,
                               'changed_since', p_changed_since, 'limit', v_limit, 'offset', v_offset);
  if v_status not in ('open', 'done', 'all') then
    v_problem := 'status must be open, done or all.';
  elsif v_assigned not in ('me', 'team', 'all') then
    v_problem := 'assigned must be me, team or all.';
  elsif v_overdue and v_status = 'done' then
    v_problem := 'overdue means open and past due: use status open (the default) or all, or leave overdue out.';
  elsif p_due_from is not null and p_due_until is not null and p_due_until < p_due_from then
    v_problem := 'due_until must not be before due_from.';
  end if;
  if v_problem is not null then
    perform agent_private.audit(c.connection_id, 'list_card_tasks', v_args, 'refused: ' || v_problem);
    return jsonb_build_object('error', v_problem);
  end if;
  select w.timezone into v_tz from public.workspaces w where w.id = c.workspace_id;
  v_now := now() at time zone v_tz;

  with tx as (
    select t.id, t.done, t.due_date, t.due_time, t.assignee_id, t.position, t.created_at, t.updated_at,
           coalesce(t.person_id, t.entry_id) as card_id, t.person_id, t.entry_id,
           coalesce(cp.sponsor_id, ce.owner_id) as owner_id, ce.customer_id,
           t.due_date + coalesce(t.due_time, time '23:59:59.999999') as due_at
      from public.card_tasks t
      left join public.people cp on cp.id = t.person_id
      left join public.list_entries ce on ce.id = t.entry_id
     where t.workspace_id = c.workspace_id
  ), hits as (
    select x.*
      from tx x
     where (v_status = 'all' or (v_status = 'open' and not x.done) or (v_status = 'done' and x.done))
       and (p_due_from is null or x.due_date >= p_due_from)
       and (p_due_until is null or x.due_date <= p_due_until)
       and (not v_overdue or (not x.done and x.due_at < v_now))
       and (v_assigned = 'all'
            or (v_assigned = 'me' and (x.assignee_id = c.person_id or (x.assignee_id is null and x.owner_id = c.person_id)))
            or (v_assigned = 'team'
                and ((x.assignee_id is not null and x.assignee_id <> c.person_id
                      and x.assignee_id in (select public.card_upline_ids()))
                     or (x.assignee_id is null and x.owner_id in (select public.card_upline_ids())))))
       and (p_person_id is null or x.card_id = p_person_id or x.customer_id = p_person_id)
       and (p_changed_since is null or x.updated_at > p_changed_since)
  ), page as (
    select h.id,
           row_number() over (order by (h.due_date is null), h.due_at, h.position, h.created_at, h.id) as rn
      from hits h
     order by rn
     limit v_limit offset v_offset
  )
  select (select count(*)::int from hits), coalesce((select array_agg(g.id order by g.rn) from page g), '{}'::text[])
    into v_total, v_ids;

  select coalesce(jsonb_agg(d.doc order by d.n), '[]'::jsonb) into v_docs
    from agent_private.card_task_docs(v_ids, c.workspace_id) with ordinality d (doc, n);

  v_filtered := p_due_from is not null or p_due_until is not null or v_overdue or p_person_id is not null
                or p_changed_since is not null;
  v_note := case
    when v_total = 0 then
      'No ' || case v_status when 'open' then 'open ' when 'done' then 'done ' else '' end || 'tasks'
      || case v_assigned when 'team' then ' for your team' when 'all' then '' else ' for you' end
      || case when v_filtered then ' match those filters' else '' end || '. '
      || case when v_filtered or v_status <> 'open' or v_assigned <> 'me'
              then 'Try status all, assigned all or fewer filters. ' else '' end
      || 'Use add_card_task to add one to a card (list_cards shows the cards).'
    when jsonb_array_length(v_docs) = 0 then 'offset is past the last task (total ' || v_total || ').'
  end;
  v_out := jsonb_build_object('total', v_total, 'limit', v_limit, 'offset', v_offset, 'timezone', v_tz, 'tasks', v_docs)
           || case when v_note is null then '{}'::jsonb else jsonb_build_object('note', v_note) end;
  perform agent_private.audit(c.connection_id, 'list_card_tasks', v_args,
                              jsonb_array_length(v_docs) || ' of ' || v_total || ' rows');
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- add_card_task
-- ---------------------------------------------------------------------------

-- One more task at the end of a card's checklist (at most 100 in all): title, optional due_date and due_time (a time
-- needs a date), optional assignee_id (the card's owner or the caller; none: whoever owns the card). Returns the
-- card with its tasks and the new task as `task`.
create function public.agent_add_card_task(
  p_person_id text, p_title text, p_board text default 'recruiting', p_due_date date default null,
  p_due_time time default null, p_assignee_id text default null) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_board text := coalesce(nullif(btrim(coalesce(p_board, '')), ''), 'recruiting');
  v_args jsonb := jsonb_build_object('person_id', p_person_id, 'board', p_board, 'title', p_title,
                                     'due_date', p_due_date, 'due_time', p_due_time, 'assignee_id', p_assignee_id);
  v_title text := btrim(coalesce(p_title, ''));
  v_assignee text := nullif(btrim(coalesce(p_assignee_id, '')), '');
  v_id text := gen_random_uuid()::text;
  k record;
  v_problem text;
  v_doc jsonb;
begin
  select * into c from agent_private.ctx(true);
  if v_board not in ('recruiting', 'customer') then
    v_problem := 'board must be recruiting or customer.';
  elsif char_length(v_title) not between 1 and 200 then
    v_problem := 'title must be 1 to 200 characters.';
  elsif p_due_time is not null and p_due_date is null then
    v_problem := 'due_time needs a due_date: a time of day belongs to a day.';
  elsif p_due_date is not null and p_due_date not between date '2000-01-01' and date '2100-01-01' then
    v_problem := 'due_date must be between 2000-01-01 and 2100-01-01.';
  elsif p_due_time is not null and extract(second from p_due_time) <> 0 then
    v_problem := 'due_time must be a time of day to the minute, HH:MM.';
  end if;
  if v_problem is null then
    select * into k from agent_private.card_lookup(v_board, p_person_id);
    if not found then
      v_problem := 'No such card among the cards you can see on the ' || v_board || ' board.';
    elsif v_assignee is not null
          and (not (v_assignee = c.person_id or v_assignee is not distinct from k.owner_id)
               or not public.card_task_registered(v_assignee)) then
      v_problem := 'assignee_id must be the card''s owner' || coalesce(' (' || (select o.name from agent_private.card_names(array[k.owner_id]) o limit 1) || ')', '')
                   || ' or you.';
    elsif (select count(*) from public.card_tasks t where t.person_id = k.person_id or t.entry_id = k.entry_id) >= 100 then
      v_problem := 'A card holds at most 100 tasks.';
    end if;
  end if;
  if v_problem is not null then
    perform agent_private.audit(c.connection_id, 'add_card_task', v_args, left('refused: ' || v_problem, 500));
    return jsonb_build_object('error', v_problem || ' Nothing was added.');
  end if;
  insert into public.card_tasks (id, workspace_id, person_id, entry_id, title, due_date, due_time, assignee_id, position)
  values (v_id, c.workspace_id, k.person_id, k.entry_id, v_title, p_due_date, p_due_time, v_assignee,
          coalesce((select max(t.position) + 1 from public.card_tasks t
                     where t.person_id = k.person_id or t.entry_id = k.entry_id), 0));
  select d into v_doc from agent_private.card_docs(array[v_board], array[k.card_id], c.person_id, c.workspace_id, 1) d;
  perform agent_private.audit(c.connection_id, 'add_card_task', v_args, 'added task ' || v_id, null,
                              agent_private.card_stamp(v_board, k.card_id) || agent_private.task_stamp(v_id));
  return v_doc || jsonb_build_object('task', (select e from jsonb_array_elements(v_doc -> 'tasks') e where e ->> 'id' = v_id));
end
$$;

-- ---------------------------------------------------------------------------
-- update_card_task
-- ---------------------------------------------------------------------------

-- Change a task's title, due_date, due_time (null clears) or assignee_id (null clears; otherwise the card's owner or
-- the caller). Anything else in the patch is refused by name and nothing changes. Ticking is complete_card_task.
create function public.agent_update_card_task(p_task_id text, p_patch jsonb) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_args jsonb := jsonb_build_object('task_id', p_task_id, 'patch', p_patch);
  v_allowed constant text[] := array['title', 'due_date', 'due_time', 'assignee_id'];
  v_bad text;
  v_problem text;
  t record;
  v_title text;
  v_date date;
  v_time time;
  v_assignee text;
  v_owner text;
  v_old jsonb;
  v_rows int;
  v_board text;
  v_card text;
  v_doc jsonb;
begin
  select * into c from agent_private.ctx(true);
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    perform agent_private.audit(c.connection_id, 'update_card_task', v_args, 'refused: empty patch');
    return jsonb_build_object('error', 'Nothing to change: give at least one of title, due_date, due_time, assignee_id.');
  end if;
  select string_agg('"' || left(k, 40) || '"', ', ' order by k) into v_bad
    from jsonb_object_keys(p_patch) k where not (k = any (v_allowed));
  if v_bad is not null then
    perform agent_private.audit(c.connection_id, 'update_card_task', v_args,
                                left('refused: field ' || v_bad || ' is not allowed', 500));
    return jsonb_build_object('error',
      'Only title, due_date, due_time and assignee_id can be changed here; ' || v_bad || ' cannot (complete_card_task ticks a task). Nothing was changed.');
  end if;

  if p_patch ? 'title' and (jsonb_typeof(p_patch -> 'title') <> 'string'
                            or char_length(btrim(p_patch ->> 'title')) not between 1 and 200) then
    v_problem := 'title must be text of 1 to 200 characters.';
  elsif p_patch ? 'assignee_id' and jsonb_typeof(p_patch -> 'assignee_id') not in ('string', 'null') then
    v_problem := 'assignee_id must be the id of a person, or null.';
  elsif p_patch ? 'due_date' and jsonb_typeof(p_patch -> 'due_date') not in ('string', 'null') then
    v_problem := 'due_date must be a date, YYYY-MM-DD, or null.';
  elsif p_patch ? 'due_time' and jsonb_typeof(p_patch -> 'due_time') not in ('string', 'null') then
    v_problem := 'due_time must be a time, HH:MM, or null.';
  end if;
  if v_problem is null and jsonb_typeof(p_patch -> 'due_date') = 'string' then
    if (p_patch ->> 'due_date') !~ '^\d{4}-\d{2}-\d{2}$' then
      v_problem := 'due_date must be a date, YYYY-MM-DD, or null.';
    else
      begin
        v_date := (p_patch ->> 'due_date')::date;
        if v_date not between date '2000-01-01' and date '2100-01-01' then
          v_problem := 'due_date must be between 2000-01-01 and 2100-01-01.';
        end if;
      exception when others then
        v_problem := 'due_date must be a real date, YYYY-MM-DD, or null.';
      end;
    end if;
  end if;
  if v_problem is null and jsonb_typeof(p_patch -> 'due_time') = 'string' then
    if (p_patch ->> 'due_time') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      v_problem := 'due_time must be a time of day, HH:MM (24 hours), or null.';
    else
      v_time := (p_patch ->> 'due_time')::time;
    end if;
  end if;
  if v_problem is not null then
    perform agent_private.audit(c.connection_id, 'update_card_task', v_args, left('refused: ' || v_problem, 500));
    return jsonb_build_object('error', v_problem || ' Nothing was changed.');
  end if;

  select x.id, x.person_id, x.entry_id, x.title, x.due_date, x.due_time, x.assignee_id
    into t from public.card_tasks x where x.id = p_task_id;
  if not found then
    perform agent_private.audit(c.connection_id, 'update_card_task', v_args, 'refused: no such task among the visible ones');
    return jsonb_build_object('error', 'No such task among the cards you can see. Nothing was changed.');
  end if;
  v_board := case when t.person_id is not null then 'recruiting' else 'customer' end;
  v_card := coalesce(t.person_id, t.entry_id);
  v_owner := public.card_owner(t.person_id, t.entry_id);
  v_old := agent_private.task_stamp(p_task_id);

  v_title := case when p_patch ? 'title' then btrim(p_patch ->> 'title') else t.title end;
  v_date := case when not (p_patch ? 'due_date') then t.due_date
                 when jsonb_typeof(p_patch -> 'due_date') = 'null' then null else v_date end;
  v_time := case when not (p_patch ? 'due_time') then t.due_time
                 when jsonb_typeof(p_patch -> 'due_time') = 'null' then null else v_time end;
  v_assignee := case when not (p_patch ? 'assignee_id') then t.assignee_id
                     when jsonb_typeof(p_patch -> 'assignee_id') = 'null' then null
                     else nullif(btrim(p_patch ->> 'assignee_id'), '') end;

  if v_time is not null and v_date is null then
    v_problem := 'due_time needs a due_date. To remove the due date, send due_date and due_time both as null.';
  elsif v_assignee is not null and v_assignee is distinct from t.assignee_id
        and (not (v_assignee = c.person_id or v_assignee is not distinct from v_owner)
             or not public.card_task_registered(v_assignee)) then
    v_problem := 'assignee_id must be the card''s owner' || coalesce(' (' || (select o.name from agent_private.card_names(array[v_owner]) o limit 1) || ')', '')
                 || ' or you.';
  end if;
  if v_problem is not null then
    perform agent_private.audit(c.connection_id, 'update_card_task', v_args, left('refused: ' || v_problem, 500));
    return jsonb_build_object('error', v_problem || ' Nothing was changed.');
  end if;

  if (v_title, v_date, v_time, v_assignee) is not distinct from (t.title, t.due_date, t.due_time, t.assignee_id) then
    select d into v_doc from agent_private.card_docs(array[v_board], array[v_card], c.person_id, c.workspace_id, 1) d;
    perform agent_private.audit(c.connection_id, 'update_card_task', v_args, 'nothing to change',
                                agent_private.card_stamp(v_board, v_card) || v_old, agent_private.card_stamp(v_board, v_card) || v_old);
    return v_doc || jsonb_build_object('note', 'Nothing changed: the task already has those values.');
  end if;

  update public.card_tasks x
     set title = v_title, due_date = v_date, due_time = v_time, assignee_id = v_assignee
   where x.id = p_task_id;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    perform agent_private.audit(c.connection_id, 'update_card_task', v_args, 'refused: not allowed to change that task');
    return jsonb_build_object('error', 'You are not allowed to change that task. Nothing was changed.');
  end if;
  select d into v_doc from agent_private.card_docs(array[v_board], array[v_card], c.person_id, c.workspace_id, 1) d;
  perform agent_private.audit(c.connection_id, 'update_card_task', v_args, 'updated task ' || p_task_id,
                              agent_private.card_stamp(v_board, v_card) || v_old,
                              agent_private.card_stamp(v_board, v_card) || agent_private.task_stamp(p_task_id));
  return v_doc;
end
$$;

-- ---------------------------------------------------------------------------
-- complete_card_task
-- ---------------------------------------------------------------------------

-- Tick a task (done true, the default) or untick it (false). Returns the card with its tasks and the task as `task`.
create function public.agent_complete_card_task(p_task_id text, p_done boolean default true) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_done boolean := coalesce(p_done, true);
  v_args jsonb := jsonb_build_object('task_id', p_task_id, 'done', v_done);
  t record;
  v_board text;
  v_card text;
  v_note text;
  v_doc jsonb;
begin
  select * into c from agent_private.ctx(true);
  select x.id, x.person_id, x.entry_id, x.done into t from public.card_tasks x where x.id = p_task_id;
  if not found then
    perform agent_private.audit(c.connection_id, 'complete_card_task', v_args, 'refused: no such task among the visible ones');
    return jsonb_build_object('error', 'No such task among the cards you can see. Nothing was changed.');
  end if;
  v_board := case when t.person_id is not null then 'recruiting' else 'customer' end;
  v_card := coalesce(t.person_id, t.entry_id);
  if t.done is distinct from v_done then
    update public.card_tasks x set done = v_done where x.id = p_task_id;
  else
    v_note := 'That task was already ' || case when v_done then 'done' else 'open' end || '.';
  end if;
  select d into v_doc from agent_private.card_docs(array[v_board], array[v_card], c.person_id, c.workspace_id, 1) d;
  perform agent_private.audit(c.connection_id, 'complete_card_task', v_args,
                              case when t.done is not distinct from v_done
                                   then 'task already ' || case when v_done then 'done' else 'open' end
                                   else case when v_done then 'ticked' else 'unticked' end || ' task ' || p_task_id end,
                              null,
                              agent_private.card_stamp(v_board, v_card) || agent_private.task_stamp(p_task_id));
  return v_doc
         || jsonb_build_object('task', (select e from jsonb_array_elements(v_doc -> 'tasks') e where e ->> 'id' = p_task_id))
         || case when v_note is null then '{}'::jsonb else jsonb_build_object('note', v_note) end;
end
$$;

-- ---------------------------------------------------------------------------
-- add_card_note
-- ---------------------------------------------------------------------------

-- A note at the end of a card's log, as the caller. Returns the note and the card's notes_count.
create function public.agent_add_card_note(p_person_id text, p_body text, p_board text default 'recruiting') returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_board text := coalesce(nullif(btrim(coalesce(p_board, '')), ''), 'recruiting');
  v_args jsonb := jsonb_build_object('person_id', p_person_id, 'board', p_board, 'body', p_body);
  v_body text := btrim(coalesce(p_body, ''));
  v_id text := gen_random_uuid()::text;
  k record;
  v_problem text;
  v_name text;
  v_at timestamptz;
  v_count int;
begin
  select * into c from agent_private.ctx(true);
  if v_board not in ('recruiting', 'customer') then
    v_problem := 'board must be recruiting or customer.';
  elsif char_length(v_body) not between 1 and 2000 then
    v_problem := 'body must be 1 to 2000 characters.';
  else
    select * into k from agent_private.card_lookup(v_board, p_person_id);
    if not found then
      v_problem := 'No such card among the cards you can see on the ' || v_board || ' board.';
    end if;
  end if;
  if v_problem is not null then
    perform agent_private.audit(c.connection_id, 'add_card_note', v_args, left('refused: ' || v_problem, 500));
    return jsonb_build_object('error', v_problem || ' Nothing was added.');
  end if;
  insert into public.card_notes (id, workspace_id, person_id, entry_id, body)
  values (v_id, c.workspace_id, k.person_id, k.entry_id, v_body);
  select n.created_at into v_at from public.card_notes n where n.id = v_id;
  select p.name into v_name from public.people p where p.id = c.person_id;
  select count(*)::int into v_count from public.card_notes n where n.person_id = k.person_id or n.entry_id = k.entry_id;
  perform agent_private.audit(c.connection_id, 'add_card_note', v_args, 'added note ' || v_id, null,
                              agent_private.card_stamp(v_board, k.card_id) || jsonb_build_object('note_id', v_id));
  return jsonb_build_object(
    'card', jsonb_build_object('board', v_board, 'person', jsonb_build_object('id', k.card_id, 'full_name', k.name)),
    'note', jsonb_build_object('id', v_id, 'author', jsonb_build_object('id', c.person_id, 'full_name', v_name),
                               'body', v_body, 'created_at', agent_private.fmt_utc(v_at)),
    'notes_count', v_count);
end
$$;

-- Only the signed-in role may run the tools (the connector switches to it); each is refused by agent_private.ctx()
-- unless it was reached through the connector.
revoke all on function
  public.agent_list_cards(text, text, boolean, boolean, date, date, boolean, text, int, int),
  public.agent_get_card(text, text),
  public.agent_list_card_tasks(text, date, date, boolean, text, text, timestamptz, int, int),
  public.agent_add_card_task(text, text, text, date, time, text),
  public.agent_update_card_task(text, jsonb),
  public.agent_complete_card_task(text, boolean),
  public.agent_add_card_note(text, text, text)
  from public, anon, service_role;
grant execute on function
  public.agent_list_cards(text, text, boolean, boolean, date, date, boolean, text, int, int),
  public.agent_get_card(text, text),
  public.agent_list_card_tasks(text, date, date, boolean, text, text, timestamptz, int, int),
  public.agent_add_card_task(text, text, text, date, time, text),
  public.agent_update_card_task(text, jsonb),
  public.agent_complete_card_task(text, boolean),
  public.agent_add_card_note(text, text, text)
  to authenticated;

-- END ORIGINAL 20261108000100_card_tasks.sql

-- BEGIN ORIGINAL 20261109000100_card_followups_conversion.sql
-- The app no longer books a "next step" on a card or keeps a single note: a card has tasks and a notes
-- log (migration 20261108000100_card_tasks). This converts what is already stored, so nothing is lost:
--
--   * every card (recruiting or customer) with a booked next step becomes ONE open task on that card:
--     title = the booked column's name on the card owner's board (board_columns(); a step that is hidden
--     for the owner is still named by its step row; a column that no longer exists is 'Next step'),
--     due_date and due_time from the booking (a booking without a day is a task without a due date),
--     assignee = the card's owner (the prospect's sponsor, the list entry's owner), created_at = the
--     card's updated_at;
--   * every card with a non-empty note becomes ONE note: body = the note, author = the card's owner,
--     created_at = the card's updated_at.
--
-- Nothing is deleted or altered in pipeline_cards / customer_cards / pipeline_step_cancellations: the
-- columns stay (the app just stops reading and writing them; the move functions keep their booking
-- parameters and keep or clear a stored booking by the same rule as before). The conversion is a function
-- so the pgTAP tests can run it a second time: it never makes a task or a note that the card already has
-- with the same content, so a second run creates nothing. It is safe on a database with no bookings and no
-- notes (it creates nothing). It runs once, here.

create function public.convert_card_followups() returns jsonb
language plpgsql set search_path = ''
as $$
declare
  v_tasks integer := 0;
  v_notes integer := 0;
  n integer;
begin
  -- Recruiting board: the prospect's card; the owner is the sponsor.
  with t as (
    select c.workspace_id, c.person_id, p.sponsor_id, c.updated_at, c.next_step_date,
           case when c.next_step_date is not null then c.next_step_time end as next_step_time,
           left(btrim(coalesce(
             (select b.label from public.board_columns('recruiting', coalesce(p.sponsor_id, p.id)) b
               where b.id = c.next_column),
             (select s.label from public.pipeline_steps s where s.id = c.next_column),
             'Next step')), 200) as title
      from public.pipeline_cards c
      join public.people p on p.id = c.person_id
     where nullif(btrim(c.next_column), '') is not null
  ), ins as (
    insert into public.card_tasks (workspace_id, person_id, title, due_date, due_time, assignee_id,
                                   position, created_at, updated_at)
    select t.workspace_id, t.person_id, t.title, t.next_step_date, t.next_step_time, t.sponsor_id,
           (select coalesce(max(x.position) + 1, 0) from public.card_tasks x where x.person_id = t.person_id),
           t.updated_at, t.updated_at
      from t
     where not exists (
       select 1 from public.card_tasks x
        where x.person_id = t.person_id and x.title = t.title
          and x.due_date is not distinct from t.next_step_date
          and x.due_time is not distinct from t.next_step_time)
    returning 1
  )
  select count(*) into n from ins;
  v_tasks := v_tasks + n;

  -- Customer board: the list name's card; the owner is the list's owner.
  with t as (
    select c.workspace_id, c.entry_id, e.owner_id, c.updated_at, c.next_step_date,
           case when c.next_step_date is not null then c.next_step_time end as next_step_time,
           left(btrim(coalesce(
             (select b.label from public.board_columns('customer', e.owner_id) b where b.id = c.next_column),
             (select s.label from public.customer_steps s where s.id = c.next_column),
             'Next step')), 200) as title
      from public.customer_cards c
      join public.list_entries e on e.id = c.entry_id
     where nullif(btrim(c.next_column), '') is not null
  ), ins as (
    insert into public.card_tasks (workspace_id, entry_id, title, due_date, due_time, assignee_id,
                                   position, created_at, updated_at)
    select t.workspace_id, t.entry_id, t.title, t.next_step_date, t.next_step_time, t.owner_id,
           (select coalesce(max(x.position) + 1, 0) from public.card_tasks x where x.entry_id = t.entry_id),
           t.updated_at, t.updated_at
      from t
     where not exists (
       select 1 from public.card_tasks x
        where x.entry_id = t.entry_id and x.title = t.title
          and x.due_date is not distinct from t.next_step_date
          and x.due_time is not distinct from t.next_step_time)
    returning 1
  )
  select count(*) into n from ins;
  v_tasks := v_tasks + n;

  -- Notes.
  with t as (
    select c.workspace_id, c.person_id, p.sponsor_id, c.updated_at, left(btrim(c.note), 2000) as body
      from public.pipeline_cards c
      join public.people p on p.id = c.person_id
     where nullif(btrim(c.note), '') is not null
  ), ins as (
    insert into public.card_notes (workspace_id, person_id, author_id, body, created_at)
    select t.workspace_id, t.person_id, t.sponsor_id, t.body, t.updated_at
      from t
     where not exists (select 1 from public.card_notes x where x.person_id = t.person_id and x.body = t.body)
    returning 1
  )
  select count(*) into n from ins;
  v_notes := v_notes + n;

  with t as (
    select c.workspace_id, c.entry_id, e.owner_id, c.updated_at, left(btrim(c.note), 2000) as body
      from public.customer_cards c
      join public.list_entries e on e.id = c.entry_id
     where nullif(btrim(c.note), '') is not null
  ), ins as (
    insert into public.card_notes (workspace_id, entry_id, author_id, body, created_at)
    select t.workspace_id, t.entry_id, t.owner_id, t.body, t.updated_at
      from t
     where not exists (select 1 from public.card_notes x where x.entry_id = t.entry_id and x.body = t.body)
    returning 1
  )
  select count(*) into n from ins;
  v_notes := v_notes + n;

  return jsonb_build_object('tasks', v_tasks, 'notes', v_notes);
end;
$$;
comment on function public.convert_card_followups() is
  'One-time conversion of booked next steps and card notes into card tasks and card notes (never makes a duplicate); the old columns are left untouched.';

-- Only the database's own roles run it (the migration, tests); never a client.
revoke execute on function public.convert_card_followups() from public, anon, authenticated;

select public.convert_card_followups();

-- END ORIGINAL 20261109000100_card_followups_conversion.sql

-- BEGIN ORIGINAL 20261110000100_agents_on_by_default.sql
-- AI agents are on by default: a team with no `feature_switches` row for `agents` has the
-- feature on. An explicit row decides: `enabled = false` keeps it off (and flipping the switch
-- writes the row as before); every other feature is still off without a row.
--
-- The only reader of the `agents` switch is agent_private.access_for(). Everything else asks
-- it: my_agent_access() (the Settings card), create_agent_pairing(), the pairing redemption
-- and the guard of every tool call, so redefining that one function is the whole change. It is
-- the 20261105000100_agent_connector.sql body with one expression changed: `switch_on` is the
-- stored value, and true when there is no row. The owner, `security definer`, the empty
-- search_path and the revoked grants are what they were (create or replace keeps the owner and
-- the privileges; the revoke is repeated so this file states them).
--
-- Switching the feature off for a team (an explicit `false` row) still refuses a non-admin on
-- their next call and still lets an app admin through as a preview, exactly as before.

create or replace function agent_private.access_for(p_uid uuid)
returns table (person_id text, workspace_id text, allowed boolean, reason text, switch_on boolean, preview boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_person text;
  v_ws text;
  v_registered boolean;
begin
  select m.person_id, m.workspace_id into v_person, v_ws
    from public.members m
   where m.user_id = p_uid
   order by m.joined_at, m.workspace_id
   limit 1;

  person_id := v_person;
  workspace_id := v_ws;
  switch_on := false;
  preview := false;
  allowed := false;

  if v_person is null then
    reason := 'no_person';
    return next;
    return;
  end if;

  select exists (
           select 1
             from public.people p
             join public.members m on m.person_id = p.id and m.workspace_id = v_ws
            where p.id = v_person
              and p.workspace_id = v_ws
              and (m.role = 'leader'
                   or public.effective_biz_class(p.biz_class, p.business_start_date) in ('apprentice', 'ibo')
                   or exists (select 1 from public.deputies d
                               join public.members l on l.person_id = d.leader_id
                                                    and l.workspace_id = d.workspace_id and l.role = 'leader'
                              where d.deputy_id = p.id and d.workspace_id = v_ws)))
    into v_registered;
  if not v_registered then
    reason := 'not_registered';
    return next;
    return;
  end if;

  switch_on := coalesce((select f.enabled from public.feature_switches f
                          where f.workspace_id = v_ws and f.feature = 'agents'), true);
  preview := exists (select 1 from public.app_admins a where a.user_id = p_uid);
  allowed := switch_on or preview;
  reason := case when allowed then null else 'switched_off' end;
  return next;
end
$$;
revoke all on function agent_private.access_for(uuid) from public, anon, authenticated, service_role;

-- END ORIGINAL 20261110000100_agents_on_by_default.sql

-- BEGIN ORIGINAL 20261112000100_pipeline_steps_after_registered.sql
-- Pipeline steps after Registered (part 1: the database).
--
-- A leader may add steps in a band after the Registered milestone (band 'registered', recruiting board only; the
-- customer board gets nothing). A registered person (apprentice or IBO) may have a card in Registered or in one of
-- those steps and move it between them, and nothing else. What changes, and nothing more:
--
--  * pipeline_steps.band accepts 'registered' (a step's id, label, owner, order, hides and deletes are unchanged:
--    deleting one still sends its cards to its band's milestone, here Registered).
--  * move_pipeline_card(): a registered person's card moves only between 'registered' and the steps of the registered
--    band, in either direction; it never changes their class, stage history or start date, and logs no registration.
--    A prospect still registers by moving into 'registered', and reaches the steps after it only that way.
--  * pipeline_moves_after_delete(): undoing a move into 'registered' un-registers the person only when it is the move
--    that registered them (their earliest move into the registered band), not a later move back from a step.
--  * pipeline_registered_card_column(person) / pipeline_registered_in_progress(person): the column a registered person's
--    card is in on their sponsor's board, or null (and false) when it is not in progress there (mirror of
--    src/data/pipeline/afterRegistered.ts). Only a board with at least one registered-band step has any.
--  * card_tasks_guard(): a task may be added to the card of a registered person while it is in progress.
--  * pipeline_cards: a registered person's card that has no stored row can be created (in Registered) so it can be
--    taken off the board and put back; cards are otherwise created and moved only by move_pipeline_card().
--  * agent_private.card_lookup() / card_docs() and agent_list_cards(): the connector reads, and works the tasks and
--    notes of, the cards of registered people in progress, with their column id and name. Agents still cannot move,
--    create or delete a card.
--
-- Functions are redefined with create or replace: owner, security setting, search_path and grants are those they have.

-- ---------------------------------------------------------------------------
-- The band
-- ---------------------------------------------------------------------------

alter table public.pipeline_steps drop constraint pipeline_steps_band_check;
alter table public.pipeline_steps add constraint pipeline_steps_band_check
  check (band in ('contact', 'first_meeting', 'first_plan', 'registered'));

-- ---------------------------------------------------------------------------
-- Is a registered person's card in progress?
--
-- On the board of the person's sponsor (its columns: board_columns('recruiting', sponsor), hidden steps left out):
--  * no step in the registered band: no (nothing after Registered exists, as before);
--  * the card is taken off the board: no;
--  * the cutoff is the first day, in the team's time zone, of the month in which the board's earliest registered-band
--    step was created;
--  * a card in one of the steps is in progress, except one in the board's LAST registered-band step (the finishing
--    column) that entered it before the current month: that one is finished;
--  * a person with no stored card, or a card in Registered (or in a column the board does not have: a step that is
--    hidden or deleted), is in progress when they registered on or after the cutoff. They registered on the day of
--    their earliest move into the registered band, else on their business start date.
-- ---------------------------------------------------------------------------

-- The board's steps after Registered are read from the sponsor line directly (as move_pipeline_card() reads them), not
-- through board_columns(), which shows a line only to people who can see its sponsor: the registered person themselves
-- cannot see theirs.
create function public.pipeline_registered_card_column(p_person_id text) returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_p public.people;
  v_tz text;
  v_steps text[];
  v_first timestamptz;
  v_cutoff date;
  v_card public.pipeline_cards;
  v_has_card boolean;
  v_col text;
  v_reg date;
begin
  select * into v_p from public.people p where p.id = p_person_id;
  if not found or v_p.biz_class not in ('apprentice', 'ibo') or v_p.sponsor_id is null
     or v_p.workspace_id is distinct from public.current_workspace_id()
     or p_person_id not in (select public.visible_person_ids()) then
    return null;
  end if;
  with recursive up (id, sponsor, d) as (
    select p.id, p.sponsor_id, 0 from public.people p where p.id = v_p.sponsor_id
    union all
    select s.id, s.sponsor_id, up.d + 1 from public.people s join up on s.id = up.sponsor where up.d < 100
  ), chain as (
    select up.id, (max(up.d) over () - up.d) as depth from up
  ), st as (
    select s.id, s.position, s.created_at, c.depth
      from public.pipeline_steps s join chain c on c.id = s.owner_id
     where s.band = 'registered' and s.workspace_id = v_p.workspace_id
       and not exists (select 1 from public.pipeline_step_hides h join chain c2 on c2.id = h.person_id
                        where h.step_id = s.id)
  )
  select array_agg(st.id order by st.depth, st.position, st.created_at, st.id), min(st.created_at)
    into v_steps, v_first from st;
  if v_steps is null then
    return null;
  end if;
  select * into v_card from public.pipeline_cards c where c.person_id = p_person_id;
  v_has_card := found;
  if v_has_card and v_card.dropped_at is not null then
    return null;
  end if;
  select w.timezone into v_tz from public.workspaces w where w.id = v_p.workspace_id;
  v_cutoff := date_trunc('month', v_first at time zone v_tz)::date;
  v_col := case when v_has_card and v_card.column_id = any (v_steps) then v_card.column_id else 'registered' end;
  if v_col = 'registered' then
    v_reg := coalesce((select min((m.moved_at at time zone v_tz)::date) from public.pipeline_moves m
                        where m.person_id = p_person_id and m.milestone = 'registered'),
                      v_p.business_start_date);
    return case when v_reg is not null and v_reg >= v_cutoff then 'registered' end;
  end if;
  if v_col = v_steps[array_length(v_steps, 1)]
     and to_char(v_card.entered_at at time zone v_tz, 'YYYY-MM')
         <> to_char(public.workspace_today(v_p.workspace_id), 'YYYY-MM') then
    return null;
  end if;
  return v_col;
end $$;

create function public.pipeline_registered_in_progress(p_person_id text) returns boolean
language sql stable security definer set search_path = ''
as $$ select public.pipeline_registered_card_column(p_person_id) is not null $$;

revoke execute on function public.pipeline_registered_card_column(text) from public, anon;
grant execute on function public.pipeline_registered_card_column(text) to authenticated;
revoke execute on function public.pipeline_registered_in_progress(text) from public, anon;
grant execute on function public.pipeline_registered_in_progress(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Moves: as in 20261016001500_referral_source.sql, with registered people.
-- ---------------------------------------------------------------------------

create or replace function public.move_pipeline_card(
  p_person_id text,
  p_to text,
  p_move_id text default null,
  p_next_column text default null,
  p_next_step_date date default null,
  p_next_step_time time default null,
  p_source text default null,
  p_hot boolean default null,
  p_rating text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_me text := public.current_person_id();
  v_ws text := public.current_workspace_id();
  v_p public.people;
  v_card public.pipeline_cards;
  v_had_card boolean;
  v_registered boolean := false;
  v_band text;
  v_owner text;
  v_next text;
  v_date date;
  v_time time;
  v_move public.pipeline_moves;
begin
  if v_me is null or public.is_candidate() then
    raise exception 'Candidates don''t have a pipeline yet' using errcode = '42501';
  end if;
  select * into v_p from public.people p where p.id = p_person_id for update;
  if not found or v_p.workspace_id is distinct from v_ws or not public.can_see_person(p_person_id) then
    raise exception 'Person not found' using errcode = 'P0002';
  end if;
  if v_p.biz_class in ('apprentice', 'ibo') then
    v_registered := true;
  elsif v_p.biz_class <> 'prospect' then
    raise exception 'Only prospects move on the board' using errcode = '22023';
  end if;
  v_owner := coalesce(v_p.sponsor_id, v_me);

  v_band := case
    when p_to in ('contact', 'first_meeting', 'first_plan', 'registered') then p_to
    when p_to = 'not_contacted' then 'start'
    when p_to in ('referral_source', 'not_interested', 'do_not_contact') then 'out'
  end;
  if v_band is null then
    select s.band into v_band from public.pipeline_steps s
     where s.id = p_to and s.workspace_id = v_ws
       and (s.owner_id in (select c.person_id from public.sponsor_chain(v_owner) c)
            or s.owner_id in (select public.my_chain_ids()));
  end if;
  if v_band is null then
    raise exception 'That column isn''t on this board' using errcode = '22023';
  end if;
  -- A registered person's card stays in Registered or the steps after it; a prospect reaches those only by registering.
  if v_registered and v_band <> 'registered' then
    raise exception 'A registered person moves only between Registered and the steps after it' using errcode = '22023';
  end if;
  if not v_registered and v_band = 'registered' and p_to <> 'registered' then
    raise exception 'A prospect registers first, then moves through the steps after Registered' using errcode = '22023';
  end if;

  select * into v_card from public.pipeline_cards c where c.person_id = p_person_id for update;
  v_had_card := found;
  if v_had_card and v_card.dropped_at is not null then
    raise exception 'That card is off the board' using errcode = '22023';
  end if;
  if (v_had_card and v_card.column_id = p_to) or (v_registered and not v_had_card and p_to = 'registered') then
    raise exception 'Already there' using errcode = '22023';
  end if;

  -- The booking after the move.
  if nullif(trim(p_next_column), '') is not null and p_next_column <> p_to then
    v_next := p_next_column;
    v_date := p_next_step_date;
    v_time := case when p_next_step_date is not null then p_next_step_time end;
  elsif v_had_card and public.booking_kept('recruiting', v_owner, v_card.next_column, p_to) then
    v_next := v_card.next_column;
    v_date := v_card.next_step_date;
    v_time := v_card.next_step_time;
  end if;

  insert into public.pipeline_moves (id, workspace_id, person_id, owner_id, from_column, to_column,
                                     milestone, moved_at, moved_by, booking_before)
  values (coalesce(nullif(trim(p_move_id), ''), gen_random_uuid()::text), v_ws, p_person_id,
          v_owner, case when v_had_card then v_card.column_id end, p_to,
          v_band, now(), v_me,
          jsonb_build_object('next_column', v_card.next_column,
                             'next_step_date', v_card.next_step_date,
                             'next_step_time', v_card.next_step_time))
  returning * into v_move;

  insert into public.pipeline_cards (person_id, workspace_id, column_id, entered_at, next_column,
                                     next_step_date, next_step_time, hot, rating, source,
                                     dropped_at, updated_at)
  values (p_person_id, v_ws, p_to, v_move.moved_at, v_next, v_date, v_time,
          coalesce(p_hot, false), p_rating, nullif(trim(p_source), ''), null, now())
  on conflict (person_id) do update
     set column_id = excluded.column_id,
         entered_at = excluded.entered_at,
         next_column = excluded.next_column,
         next_step_date = excluded.next_step_date,
         next_step_time = excluded.next_step_time,
         hot = coalesce(p_hot, public.pipeline_cards.hot),
         rating = coalesce(p_rating, public.pipeline_cards.rating),
         source = coalesce(nullif(trim(p_source), ''), public.pipeline_cards.source),
         updated_at = now()
  returning * into v_card;

  if p_to = 'registered' and not v_registered then
    update public.people
       set biz_class = 'apprentice',
           pipeline_stage = 'apprentice',
           business_start_date = public.workspace_today(v_ws),
           stage_history = stage_history || jsonb_build_array(jsonb_build_object(
             'stage', 'apprentice',
             'at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')))
     where id = p_person_id;
    insert into public.activity (workspace_id, actor_name, actor_id, entity_type, entity_id,
                                 related_person_id, kind, summary, meta)
    values (v_ws, coalesce((select p.name from public.people p where p.id = v_me), 'Someone'), v_me,
            'person', p_person_id, p_person_id, 'stage_changed', 'Pipeline → apprentice',
            jsonb_build_object('from', 'prospect', 'to', 'apprentice'));
  end if;

  return jsonb_build_object('move', to_jsonb(v_move), 'card', to_jsonb(v_card));
end $$;

-- Undoing a move: as in 20261014005000_pipeline_next_steps.sql, but only the move that registered the person
-- (their earliest move into the registered band) un-registers them.
create or replace function public.pipeline_moves_after_delete() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_actor text := public.current_person_id();
begin
  if old.from_column is null then
    delete from public.pipeline_cards c
     where c.person_id = old.person_id and c.column_id = old.to_column;
  else
    update public.pipeline_cards c
       set column_id = old.from_column,
           entered_at = coalesce((select max(m.moved_at) from public.pipeline_moves m
                                  where m.person_id = old.person_id), c.entered_at),
           next_column = case when old.booking_before is null then c.next_column
                              else old.booking_before ->> 'next_column' end,
           next_step_date = case when old.booking_before is null then c.next_step_date
                                 else (old.booking_before ->> 'next_step_date')::date end,
           next_step_time = case when old.booking_before is null then c.next_step_time
                                 else (old.booking_before ->> 'next_step_time')::time end,
           updated_at = now()
     where c.person_id = old.person_id and c.column_id = old.to_column;
  end if;

  if old.to_column = 'registered'
     and not exists (select 1 from public.pipeline_moves m
                      where m.person_id = old.person_id and m.milestone = 'registered'
                        and (m.moved_at, m.id) < (old.moved_at, old.id)) then
    update public.people p
       set biz_class = 'prospect',
           pipeline_stage = 'prospect',
           business_start_date = null,
           stage_history = coalesce(p.stage_history, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
             'stage', 'prospect',
             'at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')))
     where p.id = old.person_id and p.biz_class = 'apprentice';
    if found then
      insert into public.activity (workspace_id, actor_name, actor_id, entity_type, entity_id,
                                   related_person_id, kind, summary, meta)
      values (old.workspace_id,
              coalesce((select p.name from public.people p where p.id = v_actor), 'Someone'), v_actor,
              'person', old.person_id, old.person_id, 'stage_changed', 'Pipeline → prospect',
              jsonb_build_object('from', 'apprentice', 'to', 'prospect'));
    end if;
  end if;
  return old;
end $$;

-- A registered person's card with no stored row (they registered without the board, or before steps existed) is
-- created in Registered, so it can be taken off the board and put back. Nothing else creates a card but a move.
create policy "add the card of a registered person" on public.pipeline_cards
  for insert to authenticated
  with check (
    workspace_id = (select public.current_workspace_id())
    and person_id in (select public.visible_person_ids())
    and not (select public.is_candidate())
    and column_id = 'registered'
    and exists (select 1 from public.people p
                 where p.id = person_id and p.biz_class in ('apprentice', 'ibo'))
  );

-- ---------------------------------------------------------------------------
-- Tasks: as in 20261108000100_card_tasks.sql, and the card of a registered person in progress takes them.
-- ---------------------------------------------------------------------------

create or replace function public.card_tasks_guard() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_me text := public.current_person_id();
  v_client boolean := public.is_client_write();
  v_ws text;
  v_owner text;
  v_biz text;
begin
  new.title := btrim(new.title);
  if new.person_id is not null then
    select p.workspace_id, p.sponsor_id, p.biz_class into v_ws, v_owner, v_biz
      from public.people p where p.id = new.person_id;
  else
    select e.workspace_id, e.owner_id into v_ws, v_owner
      from public.list_entries e where e.id = new.entry_id;
  end if;
  -- A client write to a card that does not exist (or is not readable) is refused. The database's own writes (a
  -- foreign key setting created_by or assignee_id null while the card is being deleted, the migration role) go on.
  if v_ws is null and v_client then
    raise exception 'No such card' using errcode = '42501';
  end if;
  if v_ws is not null and v_ws is distinct from new.workspace_id then
    raise exception 'The card is in another team' using errcode = '23514';
  end if;

  if tg_op = 'INSERT' then
    if v_client then
      if new.person_id is not null and v_biz is distinct from 'prospect'
         and not (coalesce(v_biz in ('apprentice', 'ibo'), false)
                  and public.pipeline_registered_in_progress(new.person_id)) then
        raise exception 'Only a prospect has a card on the recruiting board' using errcode = '23514';
      end if;
      new.created_by := v_me;
      new.created_at := now();
      new.updated_at := now();
    end if;
    -- (the database's own writes, a migration, keep the created_at / updated_at they give)
  elsif v_client and (new.id is distinct from old.id or new.workspace_id is distinct from old.workspace_id
                      or new.person_id is distinct from old.person_id or new.entry_id is distinct from old.entry_id
                      or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at) then
    raise exception 'A task cannot move to another card, and who made it and when cannot change' using errcode = '42501';
  end if;

  -- The assignee: the card's owner or the caller, and registered.
  if v_client and new.assignee_id is not null
     and (tg_op = 'INSERT' or new.assignee_id is distinct from old.assignee_id) then
    if not (new.assignee_id = v_me or new.assignee_id is not distinct from v_owner)
       or not public.card_task_registered(new.assignee_id) then
      raise exception 'A task goes to the card''s owner or to you' using errcode = '42501';
    end if;
  end if;

  -- done_at / done_by: stamped when ticked, cleared when unticked, never taken from the client.
  if tg_op = 'INSERT' then
    if new.done then
      if v_client or new.done_at is null then
        new.done_at := now();
        new.done_by := coalesce(new.done_by, v_me);
      end if;
    else
      new.done_at := null;
      new.done_by := null;
    end if;
  elsif not new.done then
    new.done_at := null;
    new.done_by := null;
  elsif not old.done then
    if v_client or new.done_at is null then
      new.done_at := now();
      new.done_by := case when v_client then v_me else coalesce(new.done_by, v_me) end;
    end if;
  elsif v_client then
    new.done_at := old.done_at;
    new.done_by := old.done_by;
  end if;
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- The agent connector: cards of registered people in progress (as in 20261108000100_card_tasks.sql)
-- ---------------------------------------------------------------------------

create or replace function agent_private.card_lookup(p_board text, p_id text)
returns table (board text, card_id text, person_id text, entry_id text, name text, owner_id text,
               workspace_id text, off_board boolean)
language sql stable security invoker set search_path = ''
as $$
  select 'recruiting'::text, p.id, p.id, null::text, p.name, p.sponsor_id, p.workspace_id,
         coalesce(c.dropped_at is not null, false)
    from public.people p
    left join public.pipeline_cards c on c.person_id = p.id
   where p_board = 'recruiting' and p.id = p_id
     and (p.biz_class = 'prospect'
          or (p.biz_class in ('apprentice', 'ibo') and public.pipeline_registered_in_progress(p.id)))
  union all
  select 'customer'::text, e.id, null::text, e.id, e.name, e.owner_id, e.workspace_id, false
    from public.list_entries e
   where p_board = 'customer' and e.id = p_id
$$;

create or replace function agent_private.card_docs(p_boards text[], p_ids text[], p_caller text, p_workspace text, p_detail int)
returns setof jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_tz text;
begin
  select w.timezone into v_tz from public.workspaces w where w.id = p_workspace;
  return query
  with k as (
    select u.b as board, u.id, u.n from unnest(p_boards, p_ids) with ordinality u (b, id, n)
  ), cards as (
    select k.n, k.board, p.id as card_id, p.id as person_id, null::text as entry_id, p.name, p.sponsor_id as owner_id,
           null::text as customer_id,
           case when p.biz_class = 'prospect' then coalesce(c.column_id, 'contact')
                else public.pipeline_registered_card_column(p.id) end as column_id,
           (c.dropped_at is not null) as off_board
      from k
      join public.people p on k.board = 'recruiting' and p.id = k.id
           and (p.biz_class = 'prospect'
                or (p.biz_class in ('apprentice', 'ibo') and public.pipeline_registered_in_progress(p.id)))
      left join public.pipeline_cards c on c.person_id = p.id
    union all
    select k.n, k.board, e.id, null::text, e.id, e.name, e.owner_id, e.customer_id,
           coalesce(c.column_id, 'not_contacted'), false
      from k
      join public.list_entries e on k.board = 'customer' and e.id = k.id
      left join public.customer_cards c on c.entry_id = e.id
  ), tk as (
    select cd.n,
           count(t.id)::int as total,
           (count(t.id) filter (where t.done))::int as done_n,
           (array_agg(t.due_date order by t.due_date + coalesce(t.due_time, time '23:59:59.999999'))
              filter (where not t.done and t.due_date is not null))[1] as nd,
           (array_agg(t.due_time order by t.due_date + coalesce(t.due_time, time '23:59:59.999999'))
              filter (where not t.done and t.due_date is not null))[1] as nt,
           array_remove(array_agg(distinct t.assignee_id) filter (where not t.done), null) as assignees
      from cards cd
      left join public.card_tasks t on (t.person_id = cd.person_id or t.entry_id = cd.entry_id)
     group by cd.n
  ), nm as (
    select * from agent_private.card_names(array(
      select x.owner_id from cards x where x.owner_id is not null
      union select a from tk, unnest(tk.assignees) a
      union select n.author_id from public.card_notes n
             where p_detail >= 2 and (n.person_id in (select x.person_id from cards x) or n.entry_id in (select x.entry_id from cards x))))
  ), own as (
    select distinct x.board, coalesce(x.owner_id, p_caller) as owner from cards x
  ), cols as (
    select o.board, o.owner, bc.id, bc.label
      from own o cross join lateral public.board_columns(o.board, o.owner) bc
  ), sn as (
    select s.pipeline, s.stage_key, s.name from public.effective_stage_names(true) s
  )
  select jsonb_strip_nulls(jsonb_build_object(
           'board', cd.board,
           'customer_id', cd.customer_id,
           'off_board', case when cd.off_board then true end,
           'next_due', case when tk.nd is null then null
                            when tk.nt is null then to_jsonb(tk.nd)
                            else to_jsonb(agent_private.fmt_local(tk.nd + tk.nt)) end,
           'timezone', case when tk.nt is not null then v_tz end))
         || jsonb_build_object(
              'person', jsonb_build_object('id', cd.card_id, 'full_name', cd.name),
              'owner', case when cd.owner_id is null then null
                            else jsonb_build_object('id', cd.owner_id, 'full_name', (select s.name from nm s where s.id = cd.owner_id)) end,
              'column', jsonb_build_object('id', cd.column_id, 'name', coalesce(
                          (select s.name from sn s where s.pipeline = cd.board and s.stage_key = cd.column_id),
                          (select l.label from cols l where l.board = cd.board and l.owner = coalesce(cd.owner_id, p_caller) and l.id = cd.column_id),
                          'Removed column')),
              'tasks_done', tk.done_n,
              'tasks_total', tk.total,
              'assignees', coalesce((select jsonb_agg(jsonb_build_object('id', a, 'full_name', (select s.name from nm s where s.id = a))
                                                      order by (select s.name from nm s where s.id = a), a)
                                       from unnest(tk.assignees) a), '[]'::jsonb),
              'notes_count', (select count(*)::int from public.card_notes n
                               where n.person_id = cd.person_id or n.entry_id = cd.entry_id))
         || case when p_detail >= 1 then jsonb_build_object('tasks', coalesce((
                   select jsonb_agg(x.d order by x.n)
                     from agent_private.card_task_docs(array(select t.id from public.card_tasks t
                                                              where t.person_id = cd.person_id or t.entry_id = cd.entry_id
                                                              order by t.position, t.created_at, t.id), p_workspace) with ordinality x (d, n)),
                   '[]'::jsonb)) else '{}'::jsonb end
         || case when p_detail >= 2 then jsonb_build_object(
                   'notes', coalesce((select jsonb_agg(jsonb_build_object(
                                'id', q.id,
                                'author', case when q.author_id is null then null
                                               else jsonb_build_object('id', q.author_id, 'full_name', (select s.name from nm s where s.id = q.author_id)) end,
                                'body', q.body, 'created_at', agent_private.fmt_utc(q.created_at)) order by q.created_at desc, q.id desc)
                                from (select n.* from public.card_notes n
                                       where n.person_id = cd.person_id or n.entry_id = cd.entry_id
                                       order by n.created_at desc, n.id desc limit 100) q), '[]'::jsonb),
                   'notes_truncated', (select count(*) from public.card_notes n
                                        where n.person_id = cd.person_id or n.entry_id = cd.entry_id) > 100)
                 else '{}'::jsonb end
    from cards cd
    join tk on tk.n = cd.n
   order by cd.n;
end
$$;

create or replace function public.agent_list_cards(
  p_board text default 'all', p_person_id text default null, p_mine_only boolean default true,
  p_has_open_tasks boolean default null, p_due_from date default null, p_due_until date default null,
  p_overdue boolean default false, p_search text default null, p_limit int default 50, p_offset int default 0)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c record;
  v_board text := coalesce(nullif(btrim(coalesce(p_board, '')), ''), 'all');
  v_mine boolean := coalesce(p_mine_only, true);
  v_overdue boolean := coalesce(p_overdue, false);
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_args jsonb;
  v_problem text;
  v_tz text;
  v_now timestamp;
  v_post boolean;
  v_total int;
  v_all int;
  v_boards text[];
  v_ids text[];
  v_docs jsonb;
  v_filtered boolean;
  v_note text;
  v_out jsonb;
begin
  select * into c from agent_private.ctx(false);
  v_args := jsonb_build_object('board', v_board, 'person_id', p_person_id, 'mine_only', v_mine,
                               'has_open_tasks', p_has_open_tasks, 'due_from', p_due_from, 'due_until', p_due_until,
                               'overdue', v_overdue, 'search', p_search, 'limit', v_limit, 'offset', v_offset);
  if v_board not in ('recruiting', 'customer', 'all') then
    v_problem := 'board must be recruiting, customer or all.';
  elsif p_due_from is not null and p_due_until is not null and p_due_until < p_due_from then
    v_problem := 'due_until must not be before due_from.';
  elsif char_length(coalesce(p_search, '')) > 100 then
    v_problem := 'search must be at most 100 characters.';
  end if;
  if v_problem is not null then
    perform agent_private.audit(c.connection_id, 'list_cards', v_args, 'refused: ' || v_problem);
    return jsonb_build_object('error', v_problem);
  end if;
  select w.timezone into v_tz from public.workspaces w where w.id = c.workspace_id;
  v_now := now() at time zone v_tz;
  -- Registered people have cards only where a step after Registered exists (nothing is looked up otherwise).
  v_post := exists (select 1 from public.pipeline_steps s where s.band = 'registered' and s.workspace_id = c.workspace_id);

  with base as (
    select 'recruiting'::text as board, p.id as card_id, p.name, p.sponsor_id as owner_id, null::text as customer_id,
           coalesce(k.dropped_at is not null, false) as off_board
      from public.people p
      left join public.pipeline_cards k on k.person_id = p.id
     where (p.biz_class = 'prospect'
            or (v_post and p.biz_class in ('apprentice', 'ibo') and public.pipeline_registered_in_progress(p.id)))
       and p.workspace_id = c.workspace_id
    union all
    select 'customer', e.id, e.name, e.owner_id, e.customer_id, false
      from public.list_entries e
     where e.workspace_id = c.workspace_id
  ), tk as (
    select t.person_id, t.entry_id,
           (count(*) filter (where not t.done))::int as open_n,
           min(t.due_date + coalesce(t.due_time, time '23:59:59.999999'))
             filter (where not t.done and t.due_date is not null) as nd
      from public.card_tasks t
     group by t.person_id, t.entry_id
  ), joined as (
    select b.board, b.card_id, b.name, b.owner_id, b.customer_id, coalesce(tk.open_n, 0) as open_n, tk.nd
      from base b
      left join tk on (b.board = 'recruiting' and tk.person_id = b.card_id)
                   or (b.board = 'customer' and tk.entry_id = b.card_id)
     where not b.off_board
  ), mineable as (
    select j.* from joined j where (not v_mine) or j.owner_id = c.person_id
  ), hits as (
    select m.*
      from mineable m
     where (v_board = 'all' or m.board = v_board)
       and (p_person_id is null or m.card_id = p_person_id or m.customer_id = p_person_id)
       and (p_has_open_tasks is null or (m.open_n > 0) = p_has_open_tasks)
       and (p_due_from is null or m.nd::date >= p_due_from)
       and (p_due_until is null or m.nd::date <= p_due_until)
       and (not v_overdue or m.nd < v_now)
       and (v_search is null or m.name ilike agent_private.like_pattern(v_search))
  ), page as (
    select h.board, h.card_id,
           row_number() over (order by (h.nd is null), h.nd, lower(h.name), h.name, h.board, h.card_id) as rn
      from hits h
     order by rn
     limit v_limit offset v_offset
  )
  select (select count(*)::int from hits), (select count(*)::int from mineable),
         coalesce((select array_agg(g.board order by g.rn) from page g), '{}'::text[]),
         coalesce((select array_agg(g.card_id order by g.rn) from page g), '{}'::text[])
    into v_total, v_all, v_boards, v_ids;

  select coalesce(jsonb_agg(d.doc order by d.n), '[]'::jsonb) into v_docs
    from agent_private.card_docs(v_boards, v_ids, c.person_id, c.workspace_id, 0) with ordinality d (doc, n);

  v_filtered := v_board <> 'all' or p_person_id is not null or p_has_open_tasks is not null or p_due_from is not null
                or p_due_until is not null or v_overdue or v_search is not null;
  v_note := case
    when v_total = 0 and v_all = 0 and v_mine then
      'You own no cards yet: a card is a prospect on the recruiting board or a name on the customer board, and a prospect has one as soon as add_prospect adds them. Use mine_only false to see your team''s cards.'
    when v_total = 0 and v_all = 0 then
      'There are no cards you can see: a card is a prospect on the recruiting board or a name on the customer board. Use add_prospect to add a prospect.'
    when v_total = 0 then
      'No card matches' || case when v_filtered then ' those filters' else '' end
      || case when v_mine then ' among the cards you own; mine_only false looks at your team''s too' else '' end || '.'
    when jsonb_array_length(v_docs) = 0 then 'offset is past the last card (total ' || v_total || ').'
  end;
  v_out := jsonb_build_object('total', v_total, 'limit', v_limit, 'offset', v_offset, 'timezone', v_tz, 'cards', v_docs)
           || case when v_note is null then '{}'::jsonb else jsonb_build_object('note', v_note) end;
  perform agent_private.audit(c.connection_id, 'list_cards', v_args,
                              jsonb_array_length(v_docs) || ' of ' || v_total || ' rows');
  return v_out;
end
$$;

-- END ORIGINAL 20261112000100_pipeline_steps_after_registered.sql
