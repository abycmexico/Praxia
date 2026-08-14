-- PANORAMA PARA EL ADMINISTRADOR DE PRAXIA
--
-- Saber quien esta usando la plataforma de verdad, no solo quien se
-- registro. Un psicologo aprobado que nunca subio un paciente es una alta
-- que no se convirtio, y sin verlo no hay forma de notarlo.

-- El admin necesita ver los consultorios; hasta ahora solo veia psicologos.
DROP POLICY IF EXISTS "el admin ve los consultorios" ON public.consultorios;
CREATE POLICY "el admin ve los consultorios" ON public.consultorios
  FOR SELECT TO authenticated
  USING (public.es_admin());

-- Cifras generales de la plataforma.
CREATE OR REPLACE FUNCTION public.panorama_praxia()
  RETURNS TABLE (
    psicologos_total      bigint,
    psicologos_aprobados  bigint,
    psicologos_pendientes bigint,
    psicologos_con_pacientes bigint,
    psicologos_activos_7d bigint,
    consultorios          bigint,
    pacientes             bigint,
    pacientes_activos     bigint,
    citas_total           bigint,
    citas_7d              bigint,
    notas_sesion          bigint,
    cobrado_total         numeric,
    suscripciones_pagadas bigint
  )
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select
    (select count(*) from psicologos),
    (select count(*) from psicologos where estado = 'aprobado'),
    (select count(*) from psicologos where estado = 'pendiente'),
    (select count(distinct psicologo_id) from pacientes),
    -- "Activo" es haber tenido movimiento real, no haber iniciado sesion:
    -- una cita o una nota en los ultimos siete dias.
    (select count(distinct psicologo_id) from (
       select psicologo_id from citas where creado_en > now() - interval '7 days'
       union
       select psicologo_id from notas_sesion where creado_en > now() - interval '7 days'
     ) m),
    (select count(*) from consultorios),
    (select count(*) from pacientes),
    (select count(*) from pacientes where estado = 'activo'),
    (select count(*) from citas),
    (select count(*) from citas where creado_en > now() - interval '7 days'),
    (select count(*) from notas_sesion),
    (select coalesce(sum(monto),0) from pagos),
    (select count(*) from suscripciones where estado in ('activa','cancelada') and fin_periodo > now())
  where public.es_admin();
$function$;

-- Cada psicologo con lo que ha hecho. Sirve para ver de un vistazo quien
-- arranco y quien se quedo en el registro.
CREATE OR REPLACE FUNCTION public.psicologos_con_actividad()
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
    plan_suscripcion  text,
    estado_suscripcion text,
    cobros_en_linea   boolean
  )
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
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
         pl.nombre, s.estado, p.stripe_cobros_activos
    from psicologos p
    left join consultorios c   on c.id = p.consultorio_id
    left join suscripciones s  on s.titular_id = p.id
    left join planes pl        on pl.id = s.plan_id
   where public.es_admin()
   order by p.creado_en desc;
$function$;

REVOKE ALL ON FUNCTION public.panorama_praxia() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.psicologos_con_actividad() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.panorama_praxia() TO authenticated;
GRANT EXECUTE ON FUNCTION public.psicologos_con_actividad() TO authenticated;
