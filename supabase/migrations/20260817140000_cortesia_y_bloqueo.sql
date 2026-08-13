-- ACCESO DE CORTESIA
--
-- Quien ya estaba usando Praxia sigue usandola sin pagar. Se les pone un
-- estado propio, 'cortesia', en vez de una fecha lejana: asi queda escrito
-- por que tienen acceso, y no aparece un "vence en 2099" que nadie sabria
-- explicar dentro de dos años.
--
-- Es tambien lo correcto: entraron cuando el acceso era gratis y no se les
-- puede cambiar la regla despues.

ALTER TABLE public.suscripciones DROP CONSTRAINT IF EXISTS suscripciones_estado_check;
ALTER TABLE public.suscripciones ADD CONSTRAINT suscripciones_estado_check
  CHECK (estado IN ('prueba','activa','cancelada','vencida','impago','cortesia'));

-- La cortesia no caduca: no depende de fin_periodo.
CREATE OR REPLACE FUNCTION public.suscripcion_vigente()
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select exists(
    select 1 from suscripciones
     where titular_id = public.titular_de_mi_suscripcion()
       and (
         estado = 'cortesia'
         or (estado in ('prueba','activa','cancelada') and fin_periodo > now())
       )
  );
$function$;

DROP FUNCTION IF EXISTS public.mi_suscripcion();
CREATE FUNCTION public.mi_suscripcion()
  RETURNS TABLE (
    plan_id           text,
    plan_nombre       text,
    precio_mensual    numeric,
    permite_equipo    boolean,
    limite_psicologos int,
    estado            text,
    fin_periodo       timestamptz,
    renovacion_automatica boolean,
    vigente           boolean,
    soy_titular       boolean
  )
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select pl.id, pl.nombre, pl.precio_mensual, pl.permite_equipo, pl.limite_psicologos,
         s.estado, s.fin_periodo, s.renovacion_automatica,
         (s.estado = 'cortesia'
          or (s.estado in ('prueba','activa','cancelada') and s.fin_periodo > now())),
         (s.titular_id = auth.uid())
    from suscripciones s
    join planes pl on pl.id = s.plan_id
   where s.titular_id = public.titular_de_mi_suscripcion();
$function$;

REVOKE ALL ON FUNCTION public.mi_suscripcion() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mi_suscripcion() TO authenticated;

-- Todos los psicologos que existen al aplicar esta migracion pasan a
-- cortesia. Los que se registren despues entran sin acceso y tendran que
-- contratar o canjear un codigo.
UPDATE public.suscripciones
   SET estado = 'cortesia',
       plan_id = 'consultorio',
       renovacion_automatica = false,
       actualizado_en = now()
 WHERE titular_id IN (SELECT id FROM public.psicologos);

COMMENT ON COLUMN public.suscripciones.estado IS
  'prueba, activa, cancelada (con acceso hasta fin_periodo), vencida, impago, y cortesia para quienes ya usaban Praxia antes de que se cobrara.';
