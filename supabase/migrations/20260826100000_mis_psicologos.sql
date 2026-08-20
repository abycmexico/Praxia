-- MIS PSICOLOGOS
--
-- El responsable de un consultorio ya veia a su equipo, pero le faltaba lo
-- que de verdad usa para dirigirlo: si alguien lleva semanas sin entrar, si
-- tiene sesiones proximas, como contactarlo, y poder taparle el acceso el
-- dia que se va.
--
-- Todo esto se resuelve en una sola funcion en vez de cinco consultas desde
-- el navegador, por dos razones. La ultima conexion vive en auth.users, que
-- el cliente no puede leer ni debe -ahi estan los correos y tokens de todos-,
-- asi que necesita SECURITY DEFINER de todos modos. Y con una funcion, el
-- limite de lo que el responsable puede ver queda escrito en un solo lugar,
-- que es donde conviene defenderlo.
--
-- Lo que NO devuelve, y no es olvido: nombres de pacientes, notas de sesion,
-- expedientes. El responsable dirige un consultorio, no atiende a los
-- pacientes de su equipo. Para eso existe el permiso de expedientes, que
-- cada psicologo concede por su cuenta.

-- ---------------------------------------------------------------------------
-- Primero: dejar que 'suspendido' sea un estado posible de verdad
-- ---------------------------------------------------------------------------
--
-- La tabla arrastraba DOS reglas sobre la misma columna. Una vieja, que solo
-- admite pendiente/aprobado/rechazado, y otra mas nueva que ya contemplaba
-- suspendido. Como las dos se aplican a la vez, mandaba la vieja: guardar
-- 'suspendido' reventaba, aunque el resto del sistema ya lo daba por bueno.
--
-- Se quita la vieja y queda una sola regla, con los cuatro estados. Salio al
-- probar la suspension en local, no en produccion.

ALTER TABLE public.psicologos DROP CONSTRAINT IF EXISTS psicologos_estado_check;
ALTER TABLE public.psicologos DROP CONSTRAINT IF EXISTS psicologos_estado_valido;
ALTER TABLE public.psicologos ADD CONSTRAINT psicologos_estado_valido
  CHECK (estado IN ('pendiente','aprobado','rechazado','suspendido'));

-- ---------------------------------------------------------------------------
-- El equipo con todo lo que el responsable puede ver
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.equipo_de_mi_consultorio();
CREATE FUNCTION public.equipo_de_mi_consultorio()
  RETURNS TABLE (
    id                   uuid,
    nombre               text,
    correo               text,
    telefono             text,
    edad                 integer,
    especialidad         text,
    cedula_profesional   text,
    foto_url             text,
    ciudad               text,
    estado               text,
    rol_consultorio      text,
    comparte_expedientes boolean,
    creado_en            timestamptz,
    ultima_conexion      timestamptz,
    pacientes_activos    bigint,
    sesiones_mes         bigint,
    cobrado_mes          numeric,
    proxima_sesion       timestamptz,
    sesiones_proximas    bigint
  )
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'auth'
  AS $function$
  with yo as (
    select consultorio_id, rol_consultorio
      from psicologos
     where id = auth.uid()
  ),
  -- El mes corre desde el dia 1, que es como se lee un consultorio: "cuantas
  -- sesiones llevamos este mes", no "en los ultimos treinta dias".
  mes as (select date_trunc('month', now()) as inicio)
  select p.id, p.nombre, p.correo, p.telefono, p.edad, p.especialidad,
         p.cedula_profesional, p.foto_url, p.ciudad, p.estado,
         p.rol_consultorio, coalesce(p.comparte_expedientes, false), p.creado_en,
         u.last_sign_in_at,
         (select count(*) from pacientes pa
           where pa.psicologo_id = p.id and pa.estado = 'activo'),
         (select count(*) from citas c, mes
           where c.psicologo_id = p.id
             and c.fecha_hora >= mes.inicio
             and c.estado <> 'cancelada'),
         (select coalesce(sum(c.precio), 0) from citas c, mes
           where c.psicologo_id = p.id
             and c.fecha_hora >= mes.inicio
             and c.estado = 'completada'),
         (select min(c.fecha_hora) from citas c
           where c.psicologo_id = p.id
             and c.fecha_hora > now()
             and c.estado <> 'cancelada'),
         (select count(*) from citas c
           where c.psicologo_id = p.id
             and c.fecha_hora > now()
             and c.estado <> 'cancelada')
    from psicologos p
    join yo on yo.consultorio_id is not null
             and p.consultorio_id = yo.consultorio_id
    left join auth.users u on u.id = p.id
   -- Solo el responsable ve al equipo entero. Un colaborador que llamara a
   -- esta funcion no obtiene filas, no un error: no tiene por que enterarse
   -- de que existe una funcion que le estan negando.
   where yo.rol_consultorio = 'dueno'
   order by (p.rol_consultorio = 'dueno') desc, p.nombre;
$function$;

REVOKE ALL ON FUNCTION public.equipo_de_mi_consultorio() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.equipo_de_mi_consultorio() FROM anon;
GRANT EXECUTE ON FUNCTION public.equipo_de_mi_consultorio() TO authenticated;

-- ---------------------------------------------------------------------------
-- Taparle el acceso a alguien del equipo
-- ---------------------------------------------------------------------------
--
-- Se hace con el estado 'suspendido', que el panel ya rechaza al entrar. No
-- se borra nada: sus pacientes, sus notas y su historial quedan intactos. Es
-- una llave que se quita, no un expediente que se destruye, y por NOM-004
-- esos registros tienen que seguir existiendo aunque la persona ya no
-- trabaje ahi.
--
-- Reversible a proposito: el caso comun no es un despido, es alguien de
-- incapacidad o de vacaciones.

DROP FUNCTION IF EXISTS public.suspender_acceso_psicologo(uuid, boolean);
CREATE FUNCTION public.suspender_acceso_psicologo(
  p_psicologo_id uuid,
  p_suspender    boolean
) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_consultorio uuid;
  v_rol         text;
  v_estado      text;
begin
  select consultorio_id, rol_consultorio into v_consultorio, v_rol
    from psicologos where id = auth.uid();

  if v_rol is distinct from 'dueno' or v_consultorio is null then
    raise exception 'Solo el responsable del consultorio puede hacer esto.';
  end if;

  if p_psicologo_id = auth.uid() then
    raise exception 'No puedes quitarte el acceso a ti mismo.';
  end if;

  select estado into v_estado
    from psicologos
   where id = p_psicologo_id
     and consultorio_id = v_consultorio
     and rol_consultorio is distinct from 'dueno';

  if v_estado is null then
    raise exception 'Esa persona no está en tu consultorio.';
  end if;

  -- Solo se toca el par aprobado <-> suspendido. Si el admin lo dejo en
  -- 'pendiente' o 'rechazado', esa decision es de la plataforma y el
  -- responsable de un consultorio no la puede pisar desde aqui.
  if p_suspender then
    if v_estado = 'aprobado' then
      update psicologos set estado = 'suspendido' where id = p_psicologo_id;
    end if;
  else
    if v_estado = 'suspendido' then
      update psicologos set estado = 'aprobado' where id = p_psicologo_id;
    end if;
  end if;
end;
$function$;

REVOKE ALL ON FUNCTION public.suspender_acceso_psicologo(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.suspender_acceso_psicologo(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.suspender_acceso_psicologo(uuid, boolean) TO authenticated;
