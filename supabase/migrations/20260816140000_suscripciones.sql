-- SUSCRIPCION DE PRAXIA
--
-- El consultorio paga una mensualidad de tarifa plana: no cambia por
-- volumen de sesiones ni por tipo de sesion. Se renueva sola y se puede
-- cancelar cuando sea.
--
-- La regla que define el modelo: cancelar NO corta el acceso en el momento.
-- Ya pagaron ese mes, asi que siguen dentro hasta que termine el periodo y
-- simplemente no se vuelve a cobrar. Cobrar por adelantado y cortar al
-- cancelar seria quedarse con dinero por un servicio no prestado.
--
-- Lo que el paciente paga por sus sesiones no tiene nada que ver con esto y
-- vive en la tabla `pagos`: ese dinero es del psicologo, no de Praxia.

CREATE TABLE IF NOT EXISTS public.planes (
  id                 text PRIMARY KEY,
  nombre             text NOT NULL,
  precio_mensual     numeric(10,2) NOT NULL CHECK (precio_mensual >= 0),
  moneda             text NOT NULL DEFAULT 'MXN',
  -- Nulo = sin limite. Es lo que separa al plan individual del de consultorio.
  limite_psicologos  int,
  permite_equipo     boolean NOT NULL DEFAULT false,
  orden              int NOT NULL DEFAULT 0,
  activo             boolean NOT NULL DEFAULT true,
  descripcion        text
);

INSERT INTO public.planes (id, nombre, precio_mensual, limite_psicologos, permite_equipo, orden, descripcion)
VALUES
  ('individual', 'Individual', 399, 1, false, 1,
   'Para un psicólogo. Expediente, agenda, videollamada y documentos.'),
  ('consultorio', 'Consultorio', 899, NULL, true, 2,
   'Todo lo del plan individual, más equipo, organigrama y KPIs del consultorio.')
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.suscripciones (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Titular: el psicologo individual, o el responsable del consultorio.
  -- Sus colaboradores quedan cubiertos por esta misma suscripcion.
  titular_id           uuid NOT NULL UNIQUE REFERENCES public.psicologos(id),
  plan_id              text NOT NULL REFERENCES public.planes(id),
  estado               text NOT NULL DEFAULT 'prueba'
                       CHECK (estado IN ('prueba','activa','cancelada','vencida','impago')),
  inicio               timestamptz NOT NULL DEFAULT now(),
  -- Hasta cuando tiene acceso pagado. Es la fecha que manda.
  fin_periodo          timestamptz NOT NULL,
  renovacion_automatica boolean NOT NULL DEFAULT true,
  cancelada_en         timestamptz,
  stripe_customer_id     text,
  stripe_subscription_id text,
  creado_en            timestamptz DEFAULT now(),
  actualizado_en       timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS suscripciones_por_fin ON public.suscripciones (fin_periodo);

ALTER TABLE public.planes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suscripciones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "todos ven los planes" ON public.planes;
CREATE POLICY "todos ven los planes" ON public.planes
  FOR SELECT TO anon, authenticated USING (activo);

-- El titular ve su suscripcion. El colaborador ve la que lo cubre.
DROP POLICY IF EXISTS "veo la suscripcion que me cubre" ON public.suscripciones;
CREATE POLICY "veo la suscripcion que me cubre" ON public.suscripciones
  FOR SELECT TO authenticated
  USING (
    titular_id = auth.uid()
    OR titular_id IN (
      select c.dueno_id from consultorios c
       where c.id = (select consultorio_id from psicologos where id = auth.uid())
    )
  );

-- El admin de Praxia administra todas: es quien concilia los cobros.
DROP POLICY IF EXISTS "el admin administra suscripciones" ON public.suscripciones;
CREATE POLICY "el admin administra suscripciones" ON public.suscripciones
  FOR ALL TO authenticated
  USING (public.es_admin()) WITH CHECK (public.es_admin());

-- ---------------------------------------------------------------------
-- Quien paga por mi
-- ---------------------------------------------------------------------

-- El titular de la suscripcion que cubre a este psicologo: el mismo si es
-- individual o responsable, o el dueño de su consultorio si es colaborador.
CREATE OR REPLACE FUNCTION public.titular_de_mi_suscripcion()
  RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select coalesce(
    (select c.dueno_id
       from psicologos p
       join consultorios c on c.id = p.consultorio_id
      where p.id = auth.uid()),
    auth.uid()
  );
$function$;

-- Acceso vigente: lo que manda es la fecha de fin de periodo, no el estado.
-- Una suscripcion cancelada sigue dando acceso hasta que ese periodo cierre.
CREATE OR REPLACE FUNCTION public.suscripcion_vigente()
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select exists(
    select 1 from suscripciones
     where titular_id = public.titular_de_mi_suscripcion()
       and estado in ('prueba','activa','cancelada')
       and fin_periodo > now()
  );
$function$;

-- El plan que cubre a quien pregunta, con su estado. Es lo que pinta la
-- pantalla de "Mi plan".
CREATE OR REPLACE FUNCTION public.mi_suscripcion()
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
         (s.estado in ('prueba','activa','cancelada') and s.fin_periodo > now()),
         (s.titular_id = auth.uid())
    from suscripciones s
    join planes pl on pl.id = s.plan_id
   where s.titular_id = public.titular_de_mi_suscripcion();
$function$;

-- Cancelar: no corta nada hoy, solo apaga la renovacion.
CREATE OR REPLACE FUNCTION public.cancelar_renovacion()
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare v_fin timestamptz;
begin
  -- Un colaborador tiene su propia fila de prueba, pero quien lo cubre es el
  -- consultorio. Sin este corte cancelaria esa fila huerfana y se le diria
  -- que conserva acceso hasta una fecha que no es la suya.
  if public.titular_de_mi_suscripcion() <> auth.uid() then
    return query select false,
      'La suscripción la administra el responsable de tu consultorio.'; return;
  end if;

  select fin_periodo into v_fin
    from suscripciones where titular_id = auth.uid();

  if v_fin is null then
    return query select false, 'No eres el titular de una suscripción.'; return;
  end if;

  update suscripciones
     set renovacion_automatica = false,
         estado = 'cancelada',
         cancelada_en = now(),
         actualizado_en = now()
   where titular_id = auth.uid();

  return query select true,
    'Cancelaste la renovación. Conservas el acceso hasta el ' ||
    to_char(v_fin, 'DD/MM/YYYY') || ' y no se te volverá a cobrar.';
end $function$;

-- Reactivar antes de que venza el periodo.
CREATE OR REPLACE FUNCTION public.reactivar_renovacion()
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare v_fin timestamptz;
begin
  if public.titular_de_mi_suscripcion() <> auth.uid() then
    return query select false,
      'La suscripción la administra el responsable de tu consultorio.'; return;
  end if;

  select fin_periodo into v_fin from suscripciones where titular_id = auth.uid();
  if v_fin is null then
    return query select false, 'No eres el titular de una suscripción.'; return;
  end if;
  if v_fin <= now() then
    return query select false, 'Tu periodo ya venció: hay que contratar de nuevo.'; return;
  end if;

  update suscripciones
     set renovacion_automatica = true, estado = 'activa',
         cancelada_en = null, actualizado_en = now()
   where titular_id = auth.uid();

  return query select true, 'Se reactivó la renovación automática.';
end $function$;

REVOKE ALL ON FUNCTION public.titular_de_mi_suscripcion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.suscripcion_vigente() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mi_suscripcion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancelar_renovacion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reactivar_renovacion() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.titular_de_mi_suscripcion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.suscripcion_vigente() TO authenticated;
GRANT EXECUTE ON FUNCTION public.mi_suscripcion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancelar_renovacion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.reactivar_renovacion() TO authenticated;

-- ---------------------------------------------------------------------
-- Alta con periodo de prueba
-- ---------------------------------------------------------------------
-- Todo psicologo arranca con 30 dias, para que el piloto no dependa de que
-- la pasarela ya exista. Va por trigger y no desde el cliente, para que no
-- quede nadie sin suscripcion si el alta ocurre por otro camino.
CREATE OR REPLACE FUNCTION public.crear_suscripcion_de_prueba()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
begin
  insert into suscripciones (titular_id, plan_id, estado, fin_periodo)
  values (NEW.id, 'individual', 'prueba', now() + interval '30 days')
  on conflict (titular_id) do nothing;
  return NEW;
end $function$;

DROP TRIGGER IF EXISTS trg_suscripcion_prueba ON public.psicologos;
CREATE TRIGGER trg_suscripcion_prueba
  AFTER INSERT ON public.psicologos
  FOR EACH ROW EXECUTE FUNCTION public.crear_suscripcion_de_prueba();

-- Los psicologos que ya existen tambien arrancan con su prueba.
INSERT INTO public.suscripciones (titular_id, plan_id, estado, fin_periodo)
SELECT id, 'individual', 'prueba', now() + interval '30 days'
  FROM public.psicologos
ON CONFLICT (titular_id) DO NOTHING;

