-- vincular_cuenta_paciente hacia `update pacientes set auth_user_id = auth.uid()`
-- sin verificar que hubiera sesion. Sin sesion, auth.uid() es null: el UPDATE
-- corria, dejaba auth_user_id en null (o sea, sin vincular nada) y la funcion
-- devolvia igual 'Cuenta vinculada correctamente.'. El cliente lo tomaba como
-- exito y mandaba al paciente al panel con un expediente que nunca quedo suyo.
--
-- Tambien faltaba impedir que una misma cuenta reclamara un segundo expediente:
-- mi_paciente_id() hace `select id from pacientes where auth_user_id = auth.uid()`
-- y con dos filas revienta con "more than one row returned by a subquery",
-- lo que tumbaria todas las policies de RLS que dependen de ella.

CREATE OR REPLACE FUNCTION public.vincular_cuenta_paciente (
  p_paciente_id uuid
)
  RETURNS TABLE (
    ok      boolean,
    mensaje text
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_paciente pacientes%rowtype;
  v_uid uuid := auth.uid();
  v_ya_tiene uuid;
begin
  if v_uid is null then
    return query select false, 'Necesitas haber iniciado sesion para conectar tu expediente.';
    return;
  end if;

  select * into v_paciente from pacientes where id = p_paciente_id;
  if not found then
    return query select false, 'Ese expediente no existe.';
    return;
  end if;

  if v_paciente.auth_user_id is not null then
    -- Reintento de la misma persona (por ejemplo, recargo la pagina): no es error.
    if v_paciente.auth_user_id = v_uid then
      return query select true, 'Tu cuenta ya estaba vinculada a este expediente.';
    else
      return query select false, 'Ese paciente ya tiene una cuenta vinculada.';
    end if;
    return;
  end if;

  select id into v_ya_tiene from pacientes where auth_user_id = v_uid limit 1;
  if v_ya_tiene is not null then
    return query select false, 'Esta cuenta ya esta vinculada a otro expediente.';
    return;
  end if;

  update pacientes set auth_user_id = v_uid where id = p_paciente_id;
  return query select true, 'Cuenta vinculada correctamente.';
end $function$;

-- anon nunca puede vincular nada (auth.uid() es null por definicion), asi que
-- el grant solo servia para invitar llamadas que fallan.
-- Ojo: revocar solo de anon no basta — Postgres otorga EXECUTE a PUBLIC por
-- defecto y anon lo hereda de ahi. Hay que quitarselo a PUBLIC y volver a
-- otorgarlo explicitamente a quien si lo necesita.
REVOKE ALL ON FUNCTION public.vincular_cuenta_paciente(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vincular_cuenta_paciente(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.vincular_cuenta_paciente(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vincular_cuenta_paciente(uuid) TO service_role;

-- Blindaje a nivel de datos: un usuario = un expediente como maximo.
-- Parcial, porque auth_user_id es null para todos los pacientes sin cuenta.
CREATE UNIQUE INDEX IF NOT EXISTS pacientes_auth_user_id_unico
  ON public.pacientes (auth_user_id)
  WHERE auth_user_id IS NOT NULL;
