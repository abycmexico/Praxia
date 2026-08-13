-- CODIGOS DE ACCESO
--
-- Para entrar hay que pagar un plan o traer un codigo. El codigo existe
-- para los invitados del arranque: amigos, el piloto, quien se quiera
-- dejar entrar sin cobrarle todavia.
--
-- Se guarda en tabla y no en el codigo fuente para poder desactivarlo,
-- limitar cuantas veces se usa y ver quien lo uso. Un codigo escrito en el
-- HTML se lee desde el navegador de cualquiera.

CREATE TABLE IF NOT EXISTS public.codigos_acceso (
  codigo       text PRIMARY KEY,
  descripcion  text,
  dias_acceso  int NOT NULL DEFAULT 30 CHECK (dias_acceso > 0),
  plan_id      text NOT NULL DEFAULT 'individual' REFERENCES public.planes(id),
  usos_maximos int,          -- nulo = sin limite
  usos         int NOT NULL DEFAULT 0,
  activo       boolean NOT NULL DEFAULT true,
  creado_en    timestamptz DEFAULT now()
);

INSERT INTO public.codigos_acceso (codigo, descripcion, dias_acceso, plan_id, usos_maximos)
VALUES ('PraxiaAmigo', 'Invitados del arranque', 365, 'consultorio', NULL)
ON CONFLICT (codigo) DO NOTHING;

-- Un codigo se canjea una sola vez por persona. Sin esto, canjear el mismo
-- codigo en repetidas ocasiones acumula el periodo y cualquiera se regala
-- los años que quiera.
CREATE TABLE IF NOT EXISTS public.canjes_codigo (
  codigo       text NOT NULL REFERENCES public.codigos_acceso(codigo),
  psicologo_id uuid NOT NULL REFERENCES public.psicologos(id),
  canjeado_en  timestamptz DEFAULT now(),
  PRIMARY KEY (codigo, psicologo_id)
);

ALTER TABLE public.canjes_codigo ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.codigos_acceso ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "solo el admin ve los canjes" ON public.canjes_codigo;
CREATE POLICY "solo el admin ve los canjes" ON public.canjes_codigo
  FOR ALL TO authenticated
  USING (public.es_admin()) WITH CHECK (public.es_admin());

-- Nadie lee la tabla desde el cliente: si se pudiera consultar, bastaria
-- pedir la lista para conocer todos los codigos. Se valida por funcion.
DROP POLICY IF EXISTS "solo el admin ve los codigos" ON public.codigos_acceso;
CREATE POLICY "solo el admin ve los codigos" ON public.codigos_acceso
  FOR ALL TO authenticated
  USING (public.es_admin()) WITH CHECK (public.es_admin());

-- Canjear un codigo. Compara sin distinguir mayusculas para que nadie se
-- quede fuera por escribir "praxiaamigo".
CREATE OR REPLACE FUNCTION public.canjear_codigo_acceso(p_codigo text)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_uid uuid := auth.uid();
  v_c codigos_acceso%rowtype;
  v_fin timestamptz;
begin
  if v_uid is null then
    return query select false, 'Necesitas haber iniciado sesión.'; return;
  end if;

  select * into v_c from codigos_acceso
   where lower(codigo) = lower(trim(p_codigo)) and activo;

  if not found then
    return query select false, 'Ese código no es válido.'; return;
  end if;

  if v_c.usos_maximos is not null and v_c.usos >= v_c.usos_maximos then
    return query select false, 'Ese código ya alcanzó su límite de usos.'; return;
  end if;

  if exists(select 1 from canjes_codigo where codigo = v_c.codigo and psicologo_id = v_uid) then
    return query select false, 'Ya habías usado ese código.'; return;
  end if;

  -- Solo el titular canjea: un colaborador ya viene cubierto por su
  -- consultorio y no tiene nada que activar.
  if public.titular_de_mi_suscripcion() <> v_uid then
    return query select false, 'Tu acceso lo administra el responsable de tu consultorio.'; return;
  end if;

  select fin_periodo into v_fin from suscripciones where titular_id = v_uid;

  -- Si todavia le queda periodo, el codigo se suma en vez de reemplazarlo:
  -- nadie deberia perder dias por canjear algo que le regalaron.
  v_fin := greatest(coalesce(v_fin, now()), now()) + (v_c.dias_acceso || ' days')::interval;

  insert into suscripciones (titular_id, plan_id, estado, fin_periodo, renovacion_automatica)
  values (v_uid, v_c.plan_id, 'activa', v_fin, false)
  on conflict (titular_id) do update
    set plan_id = excluded.plan_id,
        estado = 'activa',
        fin_periodo = excluded.fin_periodo,
        cancelada_en = null,
        actualizado_en = now();

  insert into canjes_codigo (codigo, psicologo_id) values (v_c.codigo, v_uid);
  update codigos_acceso set usos = usos + 1 where codigo = v_c.codigo;

  return query select true,
    'Código aplicado. Tienes acceso hasta el ' || to_char(v_fin, 'DD/MM/YYYY') || '.';
end $function$;

REVOKE ALL ON FUNCTION public.canjear_codigo_acceso(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.canjear_codigo_acceso(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.canjear_codigo_acceso(text) TO authenticated;

-- ---------------------------------------------------------------------
-- Se acaba la prueba automatica
-- ---------------------------------------------------------------------
-- Quien se registre a partir de ahora entra sin acceso: tiene que pagar un
-- plan o canjear un codigo. Antes se regalaban 30 dias a cualquiera.
--
-- A quien ya estaba NO se le quita nada: el cambio solo aplica a las altas
-- nuevas. Quitarle el acceso a alguien que ya lo tenia seria cambiarle las
-- reglas despues de que entro.
CREATE OR REPLACE FUNCTION public.crear_suscripcion_de_prueba()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
begin
  insert into suscripciones (titular_id, plan_id, estado, fin_periodo, renovacion_automatica)
  values (NEW.id, 'individual', 'vencida', now(), false)
  on conflict (titular_id) do nothing;
  return NEW;
end $function$;
