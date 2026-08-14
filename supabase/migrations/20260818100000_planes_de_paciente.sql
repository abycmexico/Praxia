-- COBRO AL PACIENTE
--
-- Dos formas, y el psicologo pone los precios de las dos:
--   por sesion  -> configuracion.precio_sesion, que ya existia
--   mensualidad -> un plan con un numero fijo de sesiones incluidas
--
-- Las sesiones incluidas no se acumulan: al cerrar el periodo el contador
-- vuelve a cero. Asi funciona una iguala, y acumularlas le crearia al
-- psicologo una deuda de sesiones que arrastra sin control.
--
-- El dinero es del psicologo, no de Praxia. Cuando entre el cobro en linea
-- va por Stripe Connect: el paciente le paga directo a su cuenta y Praxia
-- solo toma su comision. Por eso la cuenta conectada se guarda aqui desde
-- ahora, y no cuando se construya la pasarela.

ALTER TABLE public.psicologos
  ADD COLUMN IF NOT EXISTS stripe_account_id text;

COMMENT ON COLUMN public.psicologos.stripe_account_id IS
  'Cuenta conectada de Stripe. El dinero de sus pacientes llega ahi, nunca a Praxia.';

-- Comision de Praxia sobre lo cobrado en linea. Vive en configuracion para
-- poder cambiarla sin desplegar, y para dejar por escrito cuanto se cobra.
ALTER TABLE public.config_plataforma
  ADD COLUMN IF NOT EXISTS comision_porcentaje numeric(5,2) NOT NULL DEFAULT 5.00
    CHECK (comision_porcentaje >= 0 AND comision_porcentaje <= 100);

-- ---------------------------------------------------------------------
-- Planes que cada psicologo ofrece a sus pacientes
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.planes_paciente (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  psicologo_id       uuid NOT NULL REFERENCES public.psicologos(id),
  nombre             text NOT NULL,
  precio             numeric(10,2) NOT NULL CHECK (precio > 0),
  moneda             text NOT NULL DEFAULT 'MXN',
  sesiones_incluidas int NOT NULL CHECK (sesiones_incluidas > 0),
  descripcion        text,
  activo             boolean NOT NULL DEFAULT true,
  stripe_price_id    text,
  creado_en          timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS planes_paciente_por_psicologo
  ON public.planes_paciente (psicologo_id, activo);

ALTER TABLE public.planes_paciente ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "psicologo administra sus planes" ON public.planes_paciente;
CREATE POLICY "psicologo administra sus planes" ON public.planes_paciente
  FOR ALL TO authenticated
  USING (psicologo_id = auth.uid()) WITH CHECK (psicologo_id = auth.uid());

-- El paciente ve los planes de SU psicologo, para poder elegir uno.
DROP POLICY IF EXISTS "paciente ve los planes de su psicologo" ON public.planes_paciente;
CREATE POLICY "paciente ve los planes de su psicologo" ON public.planes_paciente
  FOR SELECT TO authenticated
  USING (
    activo
    AND psicologo_id = (select psicologo_id from pacientes where id = public.mi_paciente_id())
  );

-- ---------------------------------------------------------------------
-- Mensualidad de un paciente
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.suscripciones_paciente (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  paciente_id       uuid NOT NULL UNIQUE REFERENCES public.pacientes(id),
  psicologo_id      uuid NOT NULL REFERENCES public.psicologos(id),
  plan_id           uuid NOT NULL REFERENCES public.planes_paciente(id),
  estado            text NOT NULL DEFAULT 'activa'
                    CHECK (estado IN ('activa','cancelada','vencida','impago')),
  periodo_inicio    timestamptz NOT NULL DEFAULT now(),
  periodo_fin       timestamptz NOT NULL,
  -- Se reinicia cada periodo: las sesiones no usadas no se acumulan.
  sesiones_usadas   int NOT NULL DEFAULT 0 CHECK (sesiones_usadas >= 0),
  renovacion_automatica boolean NOT NULL DEFAULT true,
  stripe_subscription_id text,
  creado_en         timestamptz DEFAULT now(),
  actualizado_en    timestamptz DEFAULT now()
);

ALTER TABLE public.suscripciones_paciente ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "psicologo administra las mensualidades de sus pacientes" ON public.suscripciones_paciente;
CREATE POLICY "psicologo administra las mensualidades de sus pacientes" ON public.suscripciones_paciente
  FOR ALL TO authenticated
  USING (psicologo_id = auth.uid()) WITH CHECK (psicologo_id = auth.uid());

DROP POLICY IF EXISTS "paciente ve su mensualidad" ON public.suscripciones_paciente;
CREATE POLICY "paciente ve su mensualidad" ON public.suscripciones_paciente
  FOR SELECT TO authenticated
  USING (paciente_id = public.mi_paciente_id());

-- ---------------------------------------------------------------------
-- Cuanto le toca pagar a un paciente por su proxima sesion
-- ---------------------------------------------------------------------
-- Devuelve si la sesion ya viene cubierta por su mensualidad o si se cobra
-- aparte. Es lo que decide el panel al agendar.
CREATE OR REPLACE FUNCTION public.cobro_de_la_sesion(p_paciente_id uuid)
  RETURNS TABLE (
    cubierta_por_plan  boolean,
    sesiones_restantes int,
    monto              numeric,
    detalle            text
  )
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_psi uuid;
  v_s   suscripciones_paciente%rowtype;
  v_plan planes_paciente%rowtype;
  v_precio numeric;
  v_restantes int;
begin
  select psicologo_id into v_psi from pacientes where id = p_paciente_id;
  if v_psi is null then
    return query select false, 0, 0::numeric, 'Ese paciente no existe.'; return;
  end if;

  select * into v_s from suscripciones_paciente
   where paciente_id = p_paciente_id and estado = 'activa' and periodo_fin > now();

  if found then
    select * into v_plan from planes_paciente where id = v_s.plan_id;
    v_restantes := greatest(0, v_plan.sesiones_incluidas - v_s.sesiones_usadas);

    if v_restantes > 0 then
      return query select true, v_restantes, 0::numeric,
        'Incluida en su mensualidad. Le quedan ' || v_restantes || ' de ' || v_plan.sesiones_incluidas || '.';
      return;
    end if;

    -- Agoto las incluidas: la sesion extra se cobra al precio normal.
    select precio_sesion into v_precio from configuracion where psicologo_id = v_psi;
    return query select false, 0, coalesce(v_precio, 0),
      'Ya usó las ' || v_plan.sesiones_incluidas || ' sesiones de su mensualidad. Esta se cobra aparte.';
    return;
  end if;

  select precio_sesion into v_precio from configuracion where psicologo_id = v_psi;
  return query select false, 0, coalesce(v_precio, 0), 'Se cobra por sesión.';
end $function$;

REVOKE ALL ON FUNCTION public.cobro_de_la_sesion(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cobro_de_la_sesion(uuid) TO authenticated;

-- Descuenta una sesion de la mensualidad. Se llama cuando la sesion se da
-- por realizada, no al agendarla: una cita cancelada no deberia gastar una
-- sesion que el paciente ya pago.
CREATE OR REPLACE FUNCTION public.consumir_sesion_de_plan(p_cita_id uuid)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_cita citas%rowtype;
  v_s suscripciones_paciente%rowtype;
  v_plan planes_paciente%rowtype;
begin
  select * into v_cita from citas where id = p_cita_id and psicologo_id = auth.uid();
  if not found then
    return query select false, 'Esa cita no existe o no es tuya.'; return;
  end if;

  select * into v_s from suscripciones_paciente
   where paciente_id = v_cita.paciente_id and estado = 'activa' and periodo_fin > now();
  if not found then
    return query select false, 'Ese paciente no tiene mensualidad activa.'; return;
  end if;

  select * into v_plan from planes_paciente where id = v_s.plan_id;
  if v_s.sesiones_usadas >= v_plan.sesiones_incluidas then
    return query select false, 'Ya usó todas las sesiones de su mensualidad.'; return;
  end if;

  update suscripciones_paciente
     set sesiones_usadas = sesiones_usadas + 1, actualizado_en = now()
   where id = v_s.id;

  return query select true,
    'Sesión descontada. Le quedan ' || (v_plan.sesiones_incluidas - v_s.sesiones_usadas - 1) || '.';
end $function$;

REVOKE ALL ON FUNCTION public.consumir_sesion_de_plan(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consumir_sesion_de_plan(uuid) TO authenticated;

-- Cierre de periodo: renueva y pone el contador en cero. Mientras no exista
-- el cobro en linea, el psicologo la usa al recibir la mensualidad.
CREATE OR REPLACE FUNCTION public.renovar_mensualidad_paciente(p_paciente_id uuid)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare v_s suscripciones_paciente%rowtype;
begin
  select * into v_s from suscripciones_paciente
   where paciente_id = p_paciente_id and psicologo_id = auth.uid();
  if not found then
    return query select false, 'Ese paciente no tiene mensualidad.'; return;
  end if;

  update suscripciones_paciente
     set periodo_inicio = now(),
         periodo_fin = now() + interval '1 month',
         sesiones_usadas = 0,
         estado = 'activa',
         actualizado_en = now()
   where id = v_s.id;

  return query select true, 'Mensualidad renovada. El contador de sesiones vuelve a cero.';
end $function$;

REVOKE ALL ON FUNCTION public.renovar_mensualidad_paciente(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.renovar_mensualidad_paciente(uuid) TO authenticated;
