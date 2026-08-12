-- LIMPIEZA PARA ARRANCAR EL PILOTO
--
-- Deja la base vacia de datos y conserva UNICAMENTE la cuenta maestra
-- abycmexico@gmail.com (su login y su perfil de psicologo aprobado).
-- Todo lo demas se borra: cuentas de prueba, la de Cristian Gonzalez, los
-- otros correos propios, y todos los pacientes, citas y expedientes.
--
-- ESTO NO SE PUEDE DESHACER. Antes de correrlo debe existir un respaldo
-- (supabase db dump --data-only -f respaldo.sql).
--
-- Las llaves foraneas son NO ACTION, asi que el orden importa: primero los
-- hijos, luego los padres.

begin;

do $$
declare
  v_admin uuid;
  v_borrados int;
begin
  select id into v_admin from auth.users where email = 'abycmexico@gmail.com';
  if v_admin is null then
    raise exception 'No existe la cuenta abycmexico@gmail.com. Se aborta para no dejar la base sin acceso.';
  end if;
  raise notice 'Cuenta maestra conservada: %', v_admin;

  -- 1) Lo que cuelga de citas
  delete from notas_sesion;
  delete from notificaciones;

  -- 2) Citas
  delete from citas;

  -- 3) Lo que cuelga de pacientes
  delete from consentimientos;
  delete from documentos;
  delete from evaluaciones_psicologicas;
  delete from medicamentos;
  delete from objetivos_terapeuticos;
  delete from reportes_pacientes;

  -- 4) Pacientes (todos: se arranca de cero)
  delete from pacientes;

  -- 5) Lo que cuelga de psicologos, solo de los que se van
  delete from aceptaciones_terminos where psicologo_id <> v_admin;
  delete from configuracion          where psicologo_id <> v_admin;
  delete from disponibilidad         where psicologo_id <> v_admin;
  delete from google_calendar_tokens where psicologo_id <> v_admin;
  delete from google_oauth_estados   where psicologo_id <> v_admin;

  -- 6) Psicologos, salvo la cuenta maestra
  delete from psicologos where id <> v_admin;
  get diagnostics v_borrados = row_count;
  raise notice 'Psicologos borrados: %', v_borrados;

  -- 7) Cuentas de acceso, salvo la maestra. Cascadea a identities,
  --    sessions y refresh_tokens.
  delete from auth.users where id <> v_admin;
  get diagnostics v_borrados = row_count;
  raise notice 'Cuentas de acceso borradas: %', v_borrados;

  -- 8) La cuenta maestra queda aprobada y lista para entrar
  update psicologos set estado = 'aprobado' where id = v_admin;
end $$;

-- Revision antes de confirmar
select 'auth.users'  as tabla, count(*) from auth.users
union all select 'psicologos',    count(*) from psicologos
union all select 'pacientes',     count(*) from pacientes
union all select 'citas',         count(*) from citas
union all select 'notas_sesion',  count(*) from notas_sesion
union all select 'documentos',    count(*) from documentos
order by 1;

-- Esta version CONFIRMA los cambios.
-- No hay vuelta atras: el respaldo es la unica forma de recuperar.
commit;
