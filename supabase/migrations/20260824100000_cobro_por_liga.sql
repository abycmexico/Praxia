-- COBRO POR LIGA
--
-- Hasta ahora pagar exigia que el paciente tuviera cuenta y estuviera dentro
-- de Praxia. Pero en Praxia "sin cuenta" no significa "no existe": el
-- psicologo crea el expediente y la cuenta es opcional. Asi que la mayoria de
-- los pacientes a los que hay que cobrarles no podian pagar en linea.
--
-- Esto permite generar una liga por una sesion suelta y mandarla por
-- WhatsApp. Quien la abre paga sin cuenta y sin contrasena.
--
-- El cobro cuelga de un paciente a proposito: la tabla pagos exige uno, y sin
-- eso el estado de cuenta dejaria de cuadrar. Cobrarle a alguien que no es
-- paciente no es algo que deba pasar por un sistema de expedientes clinicos.

CREATE TABLE IF NOT EXISTS public.cobros_liga (
  -- El id ES el token de la liga: uuid aleatorio, imposible de adivinar.
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  psicologo_id      uuid NOT NULL REFERENCES public.psicologos(id) ON DELETE CASCADE,
  paciente_id       uuid NOT NULL REFERENCES public.pacientes(id) ON DELETE CASCADE,
  monto             numeric(10,2) NOT NULL CHECK (monto > 0),
  concepto          text NOT NULL,
  estado            text NOT NULL DEFAULT 'pendiente'
                    CHECK (estado IN ('pendiente','pagado','cancelado')),
  -- Una liga de pago viva para siempre es una liga que un dia alguien
  -- encuentra. Siete dias alcanzan para cobrar una sesion.
  expira_en         timestamptz NOT NULL DEFAULT now() + interval '7 days',
  pagado_en         timestamptz,
  stripe_payment_id text,
  creado_en         timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS cobros_liga_por_psicologo
  ON public.cobros_liga (psicologo_id, creado_en DESC);
CREATE INDEX IF NOT EXISTS cobros_liga_por_paciente
  ON public.cobros_liga (paciente_id);

ALTER TABLE public.cobros_liga ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "el psicologo administra sus cobros" ON public.cobros_liga;
CREATE POLICY "el psicologo administra sus cobros" ON public.cobros_liga
  FOR ALL TO authenticated
  USING (psicologo_id = auth.uid())
  WITH CHECK (psicologo_id = auth.uid());

-- El paciente ve los suyos si tiene cuenta, para no perder de vista lo que
-- le cobraron.
DROP POLICY IF EXISTS "el paciente ve sus cobros" ON public.cobros_liga;
CREATE POLICY "el paciente ve sus cobros" ON public.cobros_liga
  FOR SELECT TO authenticated
  USING (paciente_id = public.mi_paciente_id());

-- ---------------------------------------------------------------------
-- Crear una liga
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_cobro_liga(
  p_paciente_id uuid,
  p_monto       numeric,
  p_concepto    text DEFAULT NULL,
  p_dias        int  DEFAULT 7
)
  RETURNS TABLE (ok boolean, mensaje text, cobro_id uuid)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then
    return query select false, 'Necesitas haber iniciado sesión.', null::uuid; return;
  end if;

  -- El paciente tiene que ser suyo. Sin esto se podria generar un cobro a
  -- nombre del paciente de otro psicologo.
  if not exists(select 1 from pacientes where id = p_paciente_id and psicologo_id = v_uid) then
    return query select false, 'Ese paciente no te pertenece.', null::uuid; return;
  end if;

  if p_monto is null or p_monto <= 0 then
    return query select false, 'El monto tiene que ser mayor a cero.', null::uuid; return;
  end if;

  insert into cobros_liga (psicologo_id, paciente_id, monto, concepto, expira_en)
  values (
    v_uid, p_paciente_id, round(p_monto, 2),
    coalesce(nullif(trim(p_concepto), ''), 'Sesión de terapia'),
    now() + (greatest(coalesce(p_dias, 7), 1) || ' days')::interval
  )
  returning id into v_id;

  return query select true, 'Liga de cobro creada.', v_id;
end $function$;

-- ---------------------------------------------------------------------
-- Lo que ve quien abre la liga, sin cuenta
-- ---------------------------------------------------------------------
-- Devuelve el minimo para poder pagar con confianza: de quien es el cobro,
-- por que y cuanto.
--
-- NO devuelve el nombre del paciente. Si la liga se reenvia o se filtra, no
-- debe enterarse nadie de que esa persona va a terapia con ese psicologo:
-- eso es justamente el dato sensible.
CREATE OR REPLACE FUNCTION public.cobro_publico(p_id uuid)
  RETURNS TABLE (
    existe      boolean,
    estado      text,
    concepto    text,
    monto       numeric,
    psicologo   text,
    consultorio text,
    logo_url    text,
    cobrable    boolean,
    mensaje     text
  )
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_c cobros_liga%rowtype;
  v_psi psicologos%rowtype;
  v_cfg configuracion%rowtype;
begin
  select * into v_c from cobros_liga where id = p_id;

  if not found then
    return query select false, null::text, null::text, null::numeric,
                        null::text, null::text, null::text, false,
                        'Esta liga de pago no existe.';
    return;
  end if;

  select * into v_psi from psicologos where id = v_c.psicologo_id;
  select * into v_cfg from configuracion where psicologo_id = v_c.psicologo_id;

  return query select
    true,
    v_c.estado,
    v_c.concepto,
    v_c.monto,
    v_psi.nombre,
    v_cfg.nombre_consultorio,
    v_cfg.logo_url,
    (v_c.estado = 'pendiente' and v_c.expira_en > now()),
    case
      when v_c.estado = 'pagado'    then 'Este cobro ya fue pagado.'
      when v_c.estado = 'cancelado' then 'Este cobro fue cancelado.'
      when v_c.expira_en <= now()   then 'Esta liga de pago ya venció. Pídele una nueva a tu psicólogo.'
      else null
    end;
end $function$;

-- ---------------------------------------------------------------------
-- Cancelar una liga
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancelar_cobro_liga(p_id uuid)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
begin
  update cobros_liga
     set estado = 'cancelado'
   where id = p_id and psicologo_id = auth.uid() and estado = 'pendiente';

  if not found then
    return query select false, 'No se pudo cancelar: o no es tuya, o ya no está pendiente.';
  else
    return query select true, 'Liga cancelada.';
  end if;
end $function$;

-- ---------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------
-- cobro_publico es de las poquisimas que anon puede llamar, porque quien
-- abre la liga no tiene cuenta. Devuelve solo lo que se puede enseñar.
REVOKE ALL ON FUNCTION public.crear_cobro_liga(uuid,numeric,text,int) FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.cancelar_cobro_liga(uuid) FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.cobro_publico(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.crear_cobro_liga(uuid,numeric,text,int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancelar_cobro_liga(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cobro_publico(uuid) TO anon, authenticated;

-- La tabla no se abre a anon: lo que necesita ver pasa por la funcion.
REVOKE ALL ON public.cobros_liga FROM anon;
