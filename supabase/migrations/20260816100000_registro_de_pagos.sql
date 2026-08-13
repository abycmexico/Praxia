-- REGISTRO DE PAGOS
--
-- Hasta ahora "marcar como pagada" solo cambiaba el estado de la cita: no
-- quedaba cuanto se cobro, cuando, ni con que metodo. Sin eso no hay corte
-- del dia, ni adeudos, ni ingresos reales.
--
-- Se registra el pago aunque se haya cobrado fuera de la plataforma, que es
-- como cobra hoy la mayoria: efectivo y transferencia. La columna `origen`
-- distingue eso de lo que en su momento se cobre en linea, que es sobre lo
-- que Praxia calcularia comision. Asi el dia que entre la pasarela no hay
-- que migrar nada.

CREATE TABLE IF NOT EXISTS public.pagos (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  psicologo_id   uuid NOT NULL REFERENCES public.psicologos(id),
  paciente_id    uuid NOT NULL REFERENCES public.pacientes(id),
  -- Nulo cuando es un abono a cuenta o un paquete que no cuelga de una sola cita.
  cita_id        uuid REFERENCES public.citas(id),
  monto          numeric(10,2) NOT NULL CHECK (monto > 0),
  moneda         text NOT NULL DEFAULT 'MXN',
  metodo         text NOT NULL CHECK (metodo IN ('efectivo','transferencia','tarjeta','deposito','otro')),
  origen         text NOT NULL DEFAULT 'manual' CHECK (origen IN ('manual','en_linea')),
  fecha_pago     date NOT NULL DEFAULT current_date,
  referencia     text,
  notas          text,
  registrado_por uuid REFERENCES public.psicologos(id),
  stripe_payment_id text,
  creado_en      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pagos_por_psicologo ON public.pagos (psicologo_id, fecha_pago DESC);
CREATE INDEX IF NOT EXISTS pagos_por_paciente  ON public.pagos (paciente_id, fecha_pago DESC);
CREATE INDEX IF NOT EXISTS pagos_por_cita      ON public.pagos (cita_id);

ALTER TABLE public.pagos ENABLE ROW LEVEL SECURITY;

-- El psicologo administra los pagos de sus propios pacientes.
DROP POLICY IF EXISTS "psicologo administra sus pagos" ON public.pagos;
CREATE POLICY "psicologo administra sus pagos" ON public.pagos
  FOR ALL TO authenticated
  USING (psicologo_id = auth.uid())
  WITH CHECK (psicologo_id = auth.uid());

-- El paciente ve lo que ha pagado. No lo edita.
DROP POLICY IF EXISTS "paciente ve sus pagos" ON public.pagos;
CREATE POLICY "paciente ve sus pagos" ON public.pagos
  FOR SELECT TO authenticated
  USING (paciente_id = public.mi_paciente_id());

-- El responsable del consultorio ve los pagos de su equipo: es dinero de la
-- operacion, no contenido clinico, asi que no depende del permiso de
-- expedientes.
DROP POLICY IF EXISTS "el dueno ve los pagos de su equipo" ON public.pagos;
CREATE POLICY "el dueno ve los pagos de su equipo" ON public.pagos
  FOR SELECT TO authenticated
  USING (
    public.soy_dueno_consultorio()
    AND psicologo_id IN (
      select id from psicologos where consultorio_id = public.mi_consultorio()
    )
  );

-- Registrar un pago y, si cubre una cita pendiente, confirmarla.
-- Va como funcion y no como insert suelto para que ambas cosas ocurran
-- juntas: registrar el cobro y dejar de mostrar la cita como pendiente.
CREATE OR REPLACE FUNCTION public.registrar_pago(
  p_paciente_id uuid,
  p_monto       numeric,
  p_metodo      text,
  p_cita_id     uuid DEFAULT NULL,
  p_fecha       date DEFAULT NULL,
  p_referencia  text DEFAULT NULL,
  p_notas       text DEFAULT NULL
)
  RETURNS TABLE (ok boolean, mensaje text, pago_id uuid)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_uid uuid := auth.uid();
  v_pago uuid;
  v_estado text;
begin
  if v_uid is null then
    return query select false, 'Necesitas haber iniciado sesion.', null::uuid; return;
  end if;

  if p_monto is null or p_monto <= 0 then
    return query select false, 'El monto debe ser mayor a cero.', null::uuid; return;
  end if;

  if not exists(select 1 from pacientes where id = p_paciente_id and psicologo_id = v_uid) then
    return query select false, 'Ese paciente no es tuyo.', null::uuid; return;
  end if;

  if p_cita_id is not null then
    select estado into v_estado from citas where id = p_cita_id and psicologo_id = v_uid;
    if v_estado is null then
      return query select false, 'Esa cita no existe o no es tuya.', null::uuid; return;
    end if;
  end if;

  insert into pagos (psicologo_id, paciente_id, cita_id, monto, metodo,
                     fecha_pago, referencia, notas, registrado_por)
  values (v_uid, p_paciente_id, p_cita_id, p_monto, p_metodo,
          coalesce(p_fecha, current_date), p_referencia, p_notas, v_uid)
  returning id into v_pago;

  -- Una cita que estaba esperando el pago ya puede confirmarse.
  -- Ojo: `return query` acumula filas, no corta la funcion. Sin el `return`
  -- de abajo, esta rama devolvia dos renglones y el cliente leia el primero.
  if p_cita_id is not null and v_estado = 'pendiente_pago' then
    update citas set estado = 'confirmada' where id = p_cita_id;
    return query select true, 'Pago registrado y cita confirmada.', v_pago;
    return;
  end if;

  return query select true, 'Pago registrado.', v_pago;
end $function$;

REVOKE ALL ON FUNCTION public.registrar_pago(uuid,numeric,text,uuid,date,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_pago(uuid,numeric,text,uuid,date,text,text) TO authenticated;

-- Estado de cuenta por paciente: lo cobrable son las sesiones que ya se
-- dieron, no las agendadas a futuro.
CREATE OR REPLACE VIEW public.estado_cuenta_pacientes
  WITH (security_invoker = true) AS
  SELECT p.id                AS paciente_id,
         p.psicologo_id,
         p.nombre,
         p.estado,
         coalesce(dev.cobrable, 0)  AS cobrable,
         coalesce(pag.pagado, 0)    AS pagado,
         coalesce(dev.cobrable, 0) - coalesce(pag.pagado, 0) AS saldo
    FROM pacientes p
    LEFT JOIN (
      SELECT paciente_id, sum(coalesce(precio,0)) AS cobrable
        FROM citas
       WHERE estado = 'completada'
       GROUP BY paciente_id
    ) dev ON dev.paciente_id = p.id
    LEFT JOIN (
      SELECT paciente_id, sum(monto) AS pagado
        FROM pagos
       GROUP BY paciente_id
    ) pag ON pag.paciente_id = p.id;

REVOKE ALL ON public.estado_cuenta_pacientes FROM PUBLIC;
REVOKE ALL ON public.estado_cuenta_pacientes FROM anon;
GRANT SELECT ON public.estado_cuenta_pacientes TO authenticated;
