-- Ultima conexion de cada psicologo.
--
-- El dato vive en auth.users, que el cliente no puede consultar ni debe:
-- ahi estan los correos y tokens de todos. Se expone solo lo necesario y
-- solo al admin, por funcion.
--
-- No es "conectado ahora": eso requeriria presencia en vivo. Es cuando
-- entro por ultima vez, que para decidir a quien hay que llamarle sirve
-- mas que un semaforo verde.

DROP FUNCTION IF EXISTS public.psicologos_con_actividad();
CREATE FUNCTION public.psicologos_con_actividad()
  RETURNS TABLE (
    id                uuid,
    nombre            text,
    correo            text,
    estado            text,
    especialidad      text,
    creado_en         timestamptz,
    consultorio       text,
    rol_consultorio   text,
    pacientes         bigint,
    citas             bigint,
    notas             bigint,
    cobrado           numeric,
    ultima_actividad  timestamptz,
    ultima_conexion   timestamptz,
    plan_suscripcion  text,
    estado_suscripcion text,
    cobros_en_linea   boolean
  )
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'auth'
  AS $function$
  select p.id, p.nombre, p.correo, p.estado, p.especialidad, p.creado_en,
         c.nombre, p.rol_consultorio,
         (select count(*) from pacientes    where psicologo_id = p.id),
         (select count(*) from citas        where psicologo_id = p.id),
         (select count(*) from notas_sesion where psicologo_id = p.id),
         (select coalesce(sum(monto),0) from pagos where psicologo_id = p.id),
         greatest(
           (select max(creado_en) from citas        where psicologo_id = p.id),
           (select max(creado_en) from notas_sesion where psicologo_id = p.id),
           (select max(creado_en) from pacientes    where psicologo_id = p.id)
         ),
         u.last_sign_in_at,
         pl.nombre, s.estado, p.stripe_cobros_activos
    from psicologos p
    left join auth.users u     on u.id = p.id
    left join consultorios c   on c.id = p.consultorio_id
    left join suscripciones s  on s.titular_id = p.id
    left join planes pl        on pl.id = s.plan_id
   where public.es_admin()
   order by u.last_sign_in_at desc nulls last;
$function$;

REVOKE ALL ON FUNCTION public.psicologos_con_actividad() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.psicologos_con_actividad() TO authenticated;

-- Los consultorios con su gente, para verlos por nombre y no solo contarlos.
CREATE OR REPLACE FUNCTION public.consultorios_con_equipo()
  RETURNS TABLE (
    id            uuid,
    nombre        text,
    responsable   text,
    correo        text,
    psicologos    bigint,
    pacientes     bigint,
    creado_en     timestamptz
  )
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select c.id, c.nombre, d.nombre, d.correo,
         (select count(*) from psicologos where consultorio_id = c.id),
         (select count(*) from pacientes pa
            join psicologos ps on ps.id = pa.psicologo_id
           where ps.consultorio_id = c.id),
         c.creado_en
    from consultorios c
    join psicologos d on d.id = c.dueno_id
   where public.es_admin()
   order by c.creado_en desc;
$function$;

REVOKE ALL ON FUNCTION public.consultorios_con_equipo() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consultorios_con_equipo() TO authenticated;
