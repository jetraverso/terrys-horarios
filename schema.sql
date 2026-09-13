-- =====================================================================
--  Terry's Horarios · esquema para Supabase
--  Pegar TODO este archivo en el SQL Editor de Supabase y ejecutarlo.
--  Se puede volver a ejecutar sin problema (no borra datos).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- tablas ----------
create table if not exists app_config (
  id int primary key default 1 check (id = 1),
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists turnos (
  fecha date not null,
  emp text not null,
  shift text not null check (shift in ('m','n')),
  entry jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (fecha, emp, shift)
);

create table if not exists ajustes_mes (
  mes text not null,
  emp text not null,
  min int not null default 0,
  extra numeric not null default 0,
  nota text not null default '',
  primary key (mes, emp)
);

create table if not exists fotos (
  id uuid primary key default gen_random_uuid(),
  data text not null,
  created_at timestamptz not null default now()
);

-- Nadie accede a las tablas directamente: todo pasa por las funciones de abajo,
-- que verifican los PIN. (RLS activo sin políticas = acceso denegado.)
alter table app_config enable row level security;
alter table turnos enable row level security;
alter table ajustes_mes enable row level security;
alter table fotos enable row level security;
revoke all on app_config, turnos, ajustes_mes, fotos from anon, authenticated;

-- ---------- helpers internos ----------
create or replace function _cfg() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce((select data from app_config where id = 1), '{}'::jsonb)
$$;

create or replace function _admin_pin() returns text
language sql security definer set search_path = public as $$
  select coalesce(nullif(_cfg()->>'pinAdmin',''), '1234')
$$;

create or replace function _is_admin(p jsonb) returns boolean
language sql security definer set search_path = public as $$
  select coalesce(p->>'pin','') = _admin_pin()
$$;

create or replace function _emp_pin(p_emp text) returns text
language sql security definer set search_path = public as $$
  select coalesce((select e->>'pin' from jsonb_array_elements(coalesce(_cfg()->'empleados','[]'::jsonb)) e where e->>'id' = p_emp limit 1), '')
$$;

create or replace function _clean_entry(e jsonb) returns jsonb
language sql immutable as $$
  select case when e is null or e = 'null'::jsonb then null else jsonb_strip_nulls(e) end
$$;

-- ---------- funciones públicas (las llama la página) ----------
create or replace function ping(p jsonb default '{}'::jsonb) returns jsonb
language sql as $$ select jsonb_build_object('ok', true, 'data', 'pong') $$;

create or replace function check_admin(p jsonb) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object('ok', true, 'data', jsonb_build_object('ok', _is_admin(p), 'len', length(_admin_pin())))
$$;

create or replace function check_pin(p jsonb) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object('ok', true, 'data', jsonb_build_object('ok',
    _emp_pin(p->>'emp') = '' or _emp_pin(p->>'emp') = coalesce(p->>'pin','')))
$$;

-- Datos que necesita la pantalla de fichaje (sin PIN): nombres, roles, horarios y los fichajes de hoy.
create or replace function kiosk_data(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c jsonb := _cfg(); f date := coalesce((p->>'fecha')::date, current_date);
begin
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'empleados', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e->>'id', 'nombre', coalesce(e->>'nombre',''), 'rol', coalesce(e->>'rol','camarero'),
        'activo', coalesce((e->>'activo')::boolean, true), 'pinLen', length(coalesce(e->>'pin',''))) order by ord), '[]'::jsonb)
      from jsonb_array_elements(coalesce(c->'empleados','[]'::jsonb)) with ordinality as t(e, ord)),
    'turnos', c->'turnos',
    'fotos', coalesce((c->>'fotos')::boolean, true),
    'feriados', coalesce(c->'feriados','{}'::jsonb),
    'adminPinLen', length(_admin_pin()),
    'fecha', to_char(f,'YYYY-MM-DD'),
    'entradas', (select coalesce(jsonb_object_agg(emp, ent), '{}'::jsonb)
                 from (select emp, jsonb_object_agg(shift, entry) ent from turnos where fecha = f group by emp) x)
  ));
end $$;

-- Todo (config con PINs y sueldos, turnos de los últimos 15 meses, ajustes). Requiere PIN del dueño.
create or replace function load_all(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'config', _cfg(),
    'turnos', (select coalesce(jsonb_agg(jsonb_build_object('fecha', to_char(fecha,'YYYY-MM-DD'), 'emp', emp, 'shift', shift, 'entry', entry)), '[]'::jsonb)
               from turnos where fecha >= (current_date - interval '15 months')),
    'ajustes', (select coalesce(jsonb_agg(jsonb_build_object('key', mes, 'emp', emp, 'min', min, 'extra', extra, 'nota', nota)), '[]'::jsonb) from ajustes_mes)
  ));
end $$;

create or replace function save_config(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  if jsonb_typeof(p->'config') <> 'object' then return jsonb_build_object('ok', false, 'code', 'bad', 'error', 'Config inválida'); end if;
  insert into app_config (id, data) values (1, p->'config')
    on conflict (id) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true, 'data', true);
end $$;

create or replace function _upsert_turno(f date, e text, s text, en jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if _clean_entry(en) is null then
    delete from turnos where fecha = f and emp = e and shift = s;
  else
    insert into turnos (fecha, emp, shift, entry) values (f, e, s, _clean_entry(en))
      on conflict (fecha, emp, shift) do update set entry = excluded.entry, updated_at = now();
  end if;
end $$;

create or replace function set_turno(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  perform _upsert_turno((p->>'fecha')::date, p->>'emp', p->>'shift', p->'entry');
  return jsonb_build_object('ok', true, 'data', true);
end $$;

-- changes = { "2026-09-13": { "e1": { "m": entry|null, "n": entry|null } } }
create or replace function set_turnos(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d record; e record; s record; n int := 0;
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  for d in select * from jsonb_each(coalesce(p->'changes','{}'::jsonb)) loop
    for e in select * from jsonb_each(d.value) loop
      for s in select * from jsonb_each(e.value) loop
        perform _upsert_turno(d.key::date, e.key, s.key, s.value); n := n + 1;
      end loop;
    end loop;
  end loop;
  return jsonb_build_object('ok', true, 'data', n);
end $$;

create or replace function set_ajuste(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  insert into ajustes_mes (mes, emp, min, extra, nota)
    values (p->>'key', p->>'emp', coalesce((p->'data'->>'min')::int, 0), coalesce((p->'data'->>'extra')::numeric, 0), coalesce(p->'data'->>'nota',''))
    on conflict (mes, emp) do update set min = excluded.min, extra = excluded.extra, nota = excluded.nota;
  return jsonb_build_object('ok', true, 'data', true);
end $$;

-- Fichaje de un empleado (verifica SU pin). tipo = 'in' | 'out'. foto = jpeg en base64 (opcional).
create or replace function fichar(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e text := p->>'emp'; f date := (p->>'fecha')::date; s text := p->>'shift'; h text := p->>'hora'; t text := p->>'tipo';
  pin text := _emp_pin(e); actual jsonb; nuevo jsonb; fid uuid; mins int;
begin
  if e is null or f is null or s not in ('m','n') or h !~ '^\d{2}:\d{2}$' then
    return jsonb_build_object('ok', false, 'code', 'bad', 'error', 'Datos incompletos');
  end if;
  if pin <> '' and pin <> coalesce(p->>'pin','') then
    return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto');
  end if;
  if coalesce(p->>'foto','') <> '' then
    insert into fotos (data) values (p->>'foto') returning id into fid;
  end if;
  select entry into actual from turnos where fecha = f and emp = e and shift = s;
  if t = 'in' then
    nuevo := jsonb_build_object('src', 'fichaje', 'in', h) || case when fid is null then '{}'::jsonb else jsonb_build_object('fin', fid::text) end;
  elsif t = 'out' then
    if actual is null or actual->>'in' is null then
      return jsonb_build_object('ok', false, 'code', 'bad', 'error', 'No hay entrada fichada para este turno');
    end if;
    mins := ((extract(epoch from (h::time - (actual->>'in')::time)) / 60)::int + 1440) % 1440;
    nuevo := actual || jsonb_build_object('src', 'fichaje', 'out', h, 'min', mins) || case when fid is null then '{}'::jsonb else jsonb_build_object('fout', fid::text) end;
  else
    return jsonb_build_object('ok', false, 'code', 'bad', 'error', 'Tipo inválido');
  end if;
  perform _upsert_turno(f, e, s, nuevo);
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('entry', nuevo));
end $$;

create or replace function get_foto(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b text;
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  select data into b from fotos where id = (p->>'id')::uuid;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('b64', b));
end $$;

-- ---------- permisos ----------
revoke execute on function _cfg(), _admin_pin(), _is_admin(jsonb), _emp_pin(text), _upsert_turno(date,text,text,jsonb) from public, anon, authenticated;
grant execute on function ping(jsonb), check_admin(jsonb), check_pin(jsonb), kiosk_data(jsonb), load_all(jsonb), save_config(jsonb),
  set_turno(jsonb), set_turnos(jsonb), set_ajuste(jsonb), fichar(jsonb), get_foto(jsonb) to anon, authenticated;

-- Para que PostgREST vea las funciones nuevas enseguida
notify pgrst, 'reload schema';
