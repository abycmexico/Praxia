-- Estado de la cuenta conectada de cada psicologo.
--
-- Tener stripe_account_id no significa poder cobrar: la cuenta existe desde
-- que empieza el alta, pero Stripe solo habilita los cobros cuando termina
-- de verificar identidad y datos bancarios. Guardar las dos cosas por
-- separado evita ofrecerle "pagar con tarjeta" a un paciente cuyo psicologo
-- dejo el tramite a medias.

ALTER TABLE public.psicologos
  ADD COLUMN IF NOT EXISTS stripe_cobros_activos boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS stripe_alta_completa  boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.psicologos.stripe_cobros_activos IS
  'charges_enabled de Stripe: si puede recibir pagos de sus pacientes.';
COMMENT ON COLUMN public.psicologos.stripe_alta_completa IS
  'details_submitted de Stripe: si termino de entregar sus datos.';

-- Lo que el panel necesita saber para decidir que ofrecerle.
CREATE OR REPLACE FUNCTION public.mi_estado_cobros()
  RETURNS TABLE (
    tiene_cuenta   boolean,
    alta_completa  boolean,
    cobros_activos boolean
  )
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select (stripe_account_id is not null), stripe_alta_completa, stripe_cobros_activos
    from psicologos where id = auth.uid();
$function$;

REVOKE ALL ON FUNCTION public.mi_estado_cobros() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mi_estado_cobros() TO authenticated;

-- El paciente necesita saber si su psicologo ya puede cobrarle en linea,
-- sin que eso le exponga el identificador de la cuenta de Stripe.
CREATE OR REPLACE FUNCTION public.mi_psicologo_cobra_en_linea()
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select coalesce(
    (select ps.stripe_cobros_activos
       from pacientes p join psicologos ps on ps.id = p.psicologo_id
      where p.id = public.mi_paciente_id()),
    false);
$function$;

REVOKE ALL ON FUNCTION public.mi_psicologo_cobra_en_linea() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mi_psicologo_cobra_en_linea() TO authenticated;
