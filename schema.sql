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

-- Dispositivos autorizados para fichar (iPad del local, celular del dueño...).
create table if not exists dispositivos (
  token uuid primary key default gen_random_uuid(),
  nombre text not null default '',
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now()
);

-- Registro de cambios: qué dueño hizo qué y cuándo.
create table if not exists registro (
  id bigserial primary key,
  ts timestamptz not null default now(),
  dueno text not null default '',
  accion text not null,
  detalle jsonb
);
alter table dispositivos add column if not exists autorizado_por text not null default '';

-- Nadie accede a las tablas directamente: todo pasa por las funciones de abajo,
-- que verifican los PIN. (RLS activo sin políticas = acceso denegado.)
alter table app_config enable row level security;
alter table turnos enable row level security;
alter table ajustes_mes enable row level security;
alter table fotos enable row level security;
alter table dispositivos enable row level security;
alter table registro enable row level security;
revoke all on app_config, turnos, ajustes_mes, fotos, dispositivos, registro from anon, authenticated;

-- ---------- helpers internos ----------
create or replace function _cfg() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce((select data from app_config where id = 1), '{}'::jsonb)
$$;

drop function if exists _admin_pin();

-- Devuelve el dueño ({id,nombre,pin}) cuyo PIN coincide, o null.
create or replace function _admin_of(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c jsonb := _cfg(); d jsonb; pin text := coalesce(p->>'pin','');
begin
  if pin = '' then return null; end if;
  if jsonb_typeof(c->'duenos') = 'array' and jsonb_array_length(c->'duenos') > 0 then
    select x into d from jsonb_array_elements(c->'duenos') x where coalesce(x->>'pin','') <> '' and x->>'pin' = pin limit 1;
    return d;
  end if;
  if pin = coalesce(nullif(c->>'pinAdmin',''), '1234') then return jsonb_build_object('id','d1','nombre','Dueño'); end if;
  return null;
end $$;

create or replace function _is_admin(p jsonb) returns boolean
language sql security definer set search_path = public as $$
  select _admin_of(p) is not null
$$;

create or replace function _admin_name(p jsonb) returns text
language sql security definer set search_path = public as $$
  select coalesce(nullif(_admin_of(p)->>'nombre',''), 'Dueño')
$$;

-- ¿Este dueño puede editar fichajes? Por defecto solo el primero (d1).
create or replace function _puede_fichajes(p jsonb) returns boolean
language sql security definer set search_path = public as $$
  select case when _admin_of(p) is null then false
    else coalesce((_admin_of(p)->>'editaFichajes')::boolean, coalesce(_admin_of(p)->>'id','') = 'd1') end
$$;

-- Largo mínimo y máximo de los PIN de dueño (para el teclado de la pantalla de fichaje).
create or replace function _admin_pin_lens() returns jsonb
language plpgsql security definer set search_path = public as $$
declare c jsonb := _cfg(); mn int; mx int;
begin
  if jsonb_typeof(c->'duenos') = 'array' then
    select min(length(x->>'pin')), max(length(x->>'pin')) into mn, mx from jsonb_array_elements(c->'duenos') x where coalesce(x->>'pin','') <> '';
  end if;
  if mn is null then mn := length(coalesce(nullif(c->>'pinAdmin',''), '1234')); mx := mn; end if;
  return jsonb_build_object('min', mn, 'max', mx);
end $$;

create or replace function _log(p jsonb, accion text, detalle jsonb) returns void
language sql security definer set search_path = public as $$
  insert into registro (dueno, accion, detalle) values (_admin_name(p), accion, detalle)
$$;

create or replace function _emp_pin(p_emp text) returns text
language sql security definer set search_path = public as $$
  select coalesce((select e->>'pin' from jsonb_array_elements(coalesce(_cfg()->'empleados','[]'::jsonb)) e where e->>'id' = p_emp limit 1), '')
$$;

-- ¿El token pertenece a un dispositivo autorizado? (y anota la última vez que se usó)
create or replace function _device_ok(p jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare t uuid; ok boolean;
begin
  begin t := (p->>'token')::uuid; exception when others then return false; end;
  update dispositivos set last_seen = now() where token = t;
  get diagnostics ok = row_count;
  return ok;
end $$;

create or replace function _clean_entry(e jsonb) returns jsonb
language sql immutable as $$
  select case when e is null or e = 'null'::jsonb then null else jsonb_strip_nulls(e) end
$$;

-- ---------- funciones públicas (las llama la página) ----------
create or replace function ping(p jsonb default '{}'::jsonb) returns jsonb
language sql as $$ select jsonb_build_object('ok', true, 'data', 'pong') $$;

create or replace function check_admin(p jsonb) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object('ok', true, 'data', jsonb_build_object('ok', _is_admin(p), 'len', _admin_pin_lens()->'min', 'max', _admin_pin_lens()->'max', 'nombre', case when _is_admin(p) then _admin_name(p) else null end, 'editaFichajes', _puede_fichajes(p)))
$$;

create or replace function check_pin(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _device_ok(p) then return jsonb_build_object('ok', false, 'code', 'device', 'error', 'Dispositivo no autorizado'); end if;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('ok',
    _emp_pin(p->>'emp') = '' or _emp_pin(p->>'emp') = coalesce(p->>'pin','')));
end $$;

-- Autorizar el dispositivo desde el que se llama (requiere PIN del dueño). Devuelve el token que la página guarda.
create or replace function authorize_device(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  insert into dispositivos (nombre, autorizado_por) values (left(coalesce(p->>'nombre',''), 60), _admin_name(p)) returning token into t;
  perform _log(p, 'dispositivo_alta', jsonb_build_object('nombre', left(coalesce(p->>'nombre',''), 60)));
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('token', t::text));
end $$;

create or replace function list_devices(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  return jsonb_build_object('ok', true, 'data', (select coalesce(jsonb_agg(jsonb_build_object(
    'token', token::text, 'nombre', nombre, 'por', autorizado_por, 'creado', to_char(created_at at time zone 'Europe/Madrid','DD/MM/YYYY HH24:MI'), 'visto', to_char(last_seen at time zone 'Europe/Madrid','DD/MM/YYYY HH24:MI')) order by created_at), '[]'::jsonb) from dispositivos));
end $$;

create or replace function revoke_device(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  perform _log(p, 'dispositivo_baja', jsonb_build_object('nombre', (select nombre from dispositivos where token = (p->>'token')::uuid)));
  delete from dispositivos where token = (p->>'token')::uuid;
  return jsonb_build_object('ok', true, 'data', true);
end $$;

-- Datos que necesita la pantalla de fichaje (solo dispositivos autorizados): nombres, roles, horarios y los fichajes de hoy.
create or replace function kiosk_data(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c jsonb := _cfg(); f date := coalesce((p->>'fecha')::date, current_date);
begin
  if not _device_ok(p) then return jsonb_build_object('ok', false, 'code', 'device', 'error', 'Dispositivo no autorizado'); end if;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'empleados', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e->>'id', 'nombre', coalesce(e->>'nombre',''), 'rol', coalesce(e->>'rol','camarero'),
        'activo', coalesce((e->>'activo')::boolean, true), 'pinLen', length(coalesce(e->>'pin',''))) order by ord), '[]'::jsonb)
      from jsonb_array_elements(coalesce(c->'empleados','[]'::jsonb)) with ordinality as t(e, ord)),
    'turnos', c->'turnos',
    'fotos', coalesce((c->>'fotos')::boolean, true),
    'feriados', coalesce(c->'feriados','{}'::jsonb),
    'alarmas', c->'alarmas',
    'adminPinLen', _admin_pin_lens()->'min', 'adminPinMax', _admin_pin_lens()->'max',
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
  if not _puede_fichajes(p) and jsonb_typeof(_cfg()->'duenos') = 'array' and (p->'config'->'duenos') is distinct from (_cfg()->'duenos') then
    return jsonb_build_object('ok', false, 'code', 'perm', 'error', 'Solo un dueño con permiso para editar fichajes puede cambiar los dueños');
  end if;
  perform _log(p, 'config', jsonb_build_object('cambios', (select coalesce(jsonb_agg(k), '[]'::jsonb) from (select key k from jsonb_each(p->'config') union select key from jsonb_each(_cfg())) x where (p->'config')->k is distinct from _cfg()->k)));
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
  if not _puede_fichajes(p) and exists (select 1 from turnos where fecha = (p->>'fecha')::date and emp = p->>'emp' and shift = p->>'shift' and entry->>'in' is not null) then
    return jsonb_build_object('ok', false, 'code', 'perm', 'error', 'No tenés permiso para modificar un fichaje');
  end if;
  perform _upsert_turno((p->>'fecha')::date, p->>'emp', p->>'shift', case when _clean_entry(p->'entry') is null then null else _clean_entry(p->'entry') || jsonb_build_object('por', _admin_name(p)) end);
  perform _log(p, 'turno', jsonb_build_object('fecha', p->>'fecha', 'emp', p->>'emp', 'turno', p->>'shift', 'entry', _clean_entry(p->'entry')));
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
        if not _puede_fichajes(p) and exists (select 1 from turnos where fecha = d.key::date and emp = e.key and shift = s.key and entry->>'in' is not null) then continue; end if;
        perform _upsert_turno(d.key::date, e.key, s.key, case when _clean_entry(s.value) is null then null else _clean_entry(s.value) || jsonb_build_object('por', _admin_name(p)) end); n := n + 1;
      end loop;
    end loop;
  end loop;
  perform _log(p, 'turnos_lote', jsonb_build_object('n', n, 'desde', (select min(key) from jsonb_each(coalesce(p->'changes','{}'::jsonb))), 'hasta', (select max(key) from jsonb_each(coalesce(p->'changes','{}'::jsonb)))));
  return jsonb_build_object('ok', true, 'data', n);
end $$;

create or replace function set_ajuste(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  insert into ajustes_mes (mes, emp, min, extra, nota)
    values (p->>'key', p->>'emp', coalesce((p->'data'->>'min')::int, 0), coalesce((p->'data'->>'extra')::numeric, 0), coalesce(p->'data'->>'nota',''))
    on conflict (mes, emp) do update set min = excluded.min, extra = excluded.extra, nota = excluded.nota;
  perform _log(p, 'ajuste_sueldo', jsonb_build_object('mes', p->>'key', 'emp', p->>'emp', 'min', p->'data'->'min', 'extra', p->'data'->'extra'));
  return jsonb_build_object('ok', true, 'data', true);
end $$;

-- Fichaje de un empleado (verifica SU pin). tipo = 'in' | 'out'. foto = jpeg en base64 (opcional).
create or replace function fichar(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e text := p->>'emp'; f date := (p->>'fecha')::date; s text := p->>'shift'; h text := p->>'hora'; t text := p->>'tipo';
  pin text := _emp_pin(e); actual jsonb; nuevo jsonb; fid uuid; mins int;
begin
  if not _device_ok(p) then return jsonb_build_object('ok', false, 'code', 'device', 'error', 'Dispositivo no autorizado'); end if;
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

-- Cierre automático: ficha la salida a la hora indicada a todos los que siguen "dentro" en ese turno (lo llama el modo fichaje).
create or replace function auto_close(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f date := (p->>'fecha')::date; s text := p->>'shift'; h text := p->>'hora'; r record; mins int; n int := 0;
begin
  if not _device_ok(p) then return jsonb_build_object('ok', false, 'code', 'device', 'error', 'Dispositivo no autorizado'); end if;
  if f is null or s not in ('m','n') or h !~ '^\d{2}:\d{2}$' then return jsonb_build_object('ok', false, 'code', 'bad', 'error', 'Datos incompletos'); end if;
  for r in select emp, entry from turnos where fecha = f and shift = s and entry->>'in' is not null and coalesce(entry->>'out','') = '' loop
    mins := ((extract(epoch from (h::time - (r.entry->>'in')::time)) / 60)::int + 1440) % 1440;
    perform _upsert_turno(f, r.emp, s, r.entry || jsonb_build_object('src', 'fichaje', 'out', h, 'min', mins, 'auto', true));
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('cerrados', n));
end $$;

-- Corregir, agregar o borrar un fichaje. Requiere un dueño con permiso "editaFichajes".
create or replace function edit_fichaje(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f date := (p->>'fecha')::date; e text := p->>'emp'; s text := p->>'shift'; hin text := coalesce(p->>'in',''); hout text := coalesce(p->>'out','');
  actual jsonb; nuevo jsonb; mins int;
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  if not _puede_fichajes(p) then return jsonb_build_object('ok', false, 'code', 'perm', 'error', 'No tenés permiso para editar fichajes'); end if;
  if f is null or coalesce(e,'') = '' or s not in ('m','n') then return jsonb_build_object('ok', false, 'code', 'bad', 'error', 'Datos incompletos'); end if;
  select entry into actual from turnos where fecha = f and emp = e and shift = s;
  if coalesce((p->>'borrar')::boolean, false) then
    perform _log(p, 'fichaje_borrado', jsonb_build_object('fecha', p->>'fecha', 'emp', e, 'turno', s, 'antes', jsonb_build_object('in', actual->>'in', 'out', actual->>'out')));
    delete from turnos where fecha = f and emp = e and shift = s;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('entry', null));
  end if;
  if hin !~ '^\d{2}:\d{2}$' or (hout <> '' and hout !~ '^\d{2}:\d{2}$') then return jsonb_build_object('ok', false, 'code', 'bad', 'error', 'Hora inválida'); end if;
  nuevo := (coalesce(actual, '{}'::jsonb) - 'out' - 'min' - 'auto') || jsonb_build_object('src', 'fichaje', 'in', hin, 'edit', _admin_name(p));
  if hout <> '' then
    mins := ((extract(epoch from (hout::time - hin::time)) / 60)::int + 1440) % 1440;
    nuevo := nuevo || jsonb_build_object('out', hout, 'min', mins);
  end if;
  perform _upsert_turno(f, e, s, nuevo);
  perform _log(p, 'fichaje_edit', jsonb_build_object('fecha', p->>'fecha', 'emp', e, 'turno', s, 'antes', jsonb_build_object('in', actual->>'in', 'out', actual->>'out'), 'despues', jsonb_build_object('in', hin, 'out', nullif(hout,''))));
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('entry', nuevo));
end $$;

-- Registro de cambios (últimos N). Requiere PIN del dueño.
create or replace function get_log(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lim int := least(greatest(coalesce((p->>'limit')::int, 100), 1), 500);
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  return jsonb_build_object('ok', true, 'data', (select coalesce(jsonb_agg(jsonb_build_object('ts', to_char(ts at time zone 'Europe/Madrid','DD/MM/YYYY HH24:MI'), 'dueno', dueno, 'accion', accion, 'detalle', detalle) order by id desc), '[]'::jsonb)
    from (select * from registro order by id desc limit lim) r));
end $$;

-- Importar una foto existente (migración). Requiere PIN del dueño.
create or replace function import_foto(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare fid uuid;
begin
  if not _is_admin(p) then return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'PIN incorrecto'); end if;
  insert into fotos (data) values (p->>'b64') returning id into fid;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('id', fid::text));
end $$;

-- ---------- permisos ----------
revoke execute on function _cfg(), _admin_of(jsonb), _is_admin(jsonb), _admin_name(jsonb), _puede_fichajes(jsonb), _admin_pin_lens(), _log(jsonb,text,jsonb), _emp_pin(text), _device_ok(jsonb), _upsert_turno(date,text,text,jsonb) from public, anon, authenticated;
grant execute on function ping(jsonb), check_admin(jsonb), check_pin(jsonb), kiosk_data(jsonb), load_all(jsonb), save_config(jsonb),
  set_turno(jsonb), set_turnos(jsonb), set_ajuste(jsonb), fichar(jsonb), get_foto(jsonb), import_foto(jsonb), auto_close(jsonb),
  authorize_device(jsonb), list_devices(jsonb), revoke_device(jsonb), get_log(jsonb), edit_fichaje(jsonb) to anon, authenticated;

-- Para que PostgREST vea las funciones nuevas enseguida
notify pgrst, 'reload schema';
