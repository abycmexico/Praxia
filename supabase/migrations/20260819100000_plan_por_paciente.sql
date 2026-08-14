-- PLAN DE PAGO POR PACIENTE
--
-- El esquema anterior obligaba a crear planes genericos y luego asignarlos.
-- En la practica el psicologo acuerda las condiciones con cada paciente:
-- cuanto cobra la sesion, cuantas al mes, y si le hace descuento. Ahora el
-- plan se arma sobre el paciente y el total se calcula solo.
--
-- Los planes reutilizables se conservan: quien ya los use no pierde nada, y
-- sirven para el psicologo que cobra parejo a todos.

ALTER TABLE public.planes_paciente
  ADD COLUMN IF NOT EXISTS paciente_id uuid REFERENCES public.pacientes(id),
  ADD COLUMN IF NOT EXISTS precio_sesion numeric(10,2),
  ADD COLUMN IF NOT EXISTS descuento_porcentaje numeric(5,2) NOT NULL DEFAULT 0
    CHECK (descuento_porcentaje >= 0 AND descuento_porcentaje <= 100);

COMMENT ON COLUMN public.planes_paciente.paciente_id IS
  'Cuando el plan es de un solo paciente. Nulo si es un plan que se ofrece a varios.';

-- Arma el plan de un paciente y se lo asigna, en una sola llamada.
-- Va como funcion para que crear el plan y asignarlo no puedan quedar a
-- medias: un plan creado sin asignar solo ensucia la lista.
CREATE OR REPLACE FUNCTION public.crear_plan_de_paciente(
  p_paciente_id  uuid,
  p_precio_sesion numeric,
  p_sesiones      int,
  p_descuento     numeric DEFAULT 0,
  p_nombre        text DEFAULT NULL
)
  RETURNS TABLE (ok boolean, mensaje text, total numeric)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_uid uuid := auth.uid();
  v_nombre_pac text;
  v_total numeric;
  v_plan uuid;
begin
  select nombre into v_nombre_pac
    from pacientes where id = p_paciente_id and psicologo_id = v_uid;
  if v_nombre_pac is null then
    return query select false, 'Ese paciente no es tuyo.', 0::numeric; return;
  end if;

  if p_precio_sesion is null or p_precio_sesion <= 0 then
    return query select false, 'El precio por sesión debe ser mayor a cero.', 0::numeric; return;
  end if;
  if p_sesiones is null or p_sesiones <= 0 then
    return query select false, 'Indica cuántas sesiones incluye.', 0::numeric; return;
  end if;
  if p_descuento < 0 or p_descuento > 100 then
    return query select false, 'El descuento debe ir entre 0 y 100.', 0::numeric; return;
  end if;

  if exists(select 1 from suscripciones_paciente where paciente_id = p_paciente_id) then
    return query select false, v_nombre_pac || ' ya tiene un plan. Quítaselo antes de crear otro.', 0::numeric; return;
  end if;

  v_total := round(p_precio_sesion * p_sesiones * (1 - coalesce(p_descuento,0)/100), 2);

  insert into planes_paciente (
    psicologo_id, paciente_id, nombre, precio, sesiones_incluidas,
    precio_sesion, descuento_porcentaje, descripcion
  ) values (
    v_uid, p_paciente_id,
    coalesce(nullif(trim(p_nombre),''), 'Plan de ' || v_nombre_pac),
    v_total, p_sesiones, p_precio_sesion, coalesce(p_descuento,0),
    p_sesiones || ' sesiones · $' || to_char(p_precio_sesion,'FM999999.00') || ' c/u' ||
      case when coalesce(p_descuento,0) > 0
           then ' · ' || rtrim(rtrim(to_char(p_descuento,'FM990.99'), '0'), '.') || '% de descuento'
           else '' end
  ) returning id into v_plan;

  insert into suscripciones_paciente (paciente_id, psicologo_id, plan_id, periodo_fin)
  values (p_paciente_id, v_uid, v_plan, now() + interval '1 month');

  return query select true,
    'Plan creado para ' || v_nombre_pac || '. Paga ' || to_char(v_total,'FM999,999.00') ||
    ' al mes por ' || p_sesiones || ' sesiones.', v_total;
end $function$;

REVOKE ALL ON FUNCTION public.crear_plan_de_paciente(uuid,numeric,int,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crear_plan_de_paciente(uuid,numeric,int,numeric,text) TO authenticated;
