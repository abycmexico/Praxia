-- EQUIPO DEL CONSULTORIO
--
-- Un consultorio agrupa a varios psicologos: un dueño y sus colaboradores.
-- El dueño ve la operacion de su consultorio, pero NO el contenido clinico
-- de los pacientes que no atiende.
--
-- Por que esa linea: el aviso de privacidad que aceptan los pacientes dice
-- que el responsable de sus datos es su psicologo tratante. Un paciente que
-- llega con una colaboradora consintio que ella maneje su informacion, no
-- el dueño del consultorio. Darle acceso clinico obligaria a cambiar el
-- aviso y a recabar el consentimiento de nuevo.
--
-- Lo que NO se toca: pacientes.psicologo_id sigue apuntando al psicologo
-- tratante. El expediente sigue siendo suyo; encima se suman permisos
-- administrativos del dueño.

CREATE TABLE IF NOT EXISTS public.consultorios (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre    text NOT NULL,
  dueno_id  uuid NOT NULL REFERENCES public.psicologos(id),
  creado_en timestamptz DEFAULT now()
);

ALTER TABLE public.psicologos
  ADD COLUMN IF NOT EXISTS consultorio_id uuid REFERENCES public.consultorios(id),
  ADD COLUMN IF NOT EXISTS rol_consultorio text
    CHECK (rol_consultorio IN ('dueno','colaborador'));

CREATE INDEX IF NOT EXISTS psicologos_por_consultorio
  ON public.psicologos (consultorio_id);

-- Invitaciones: el dueño genera una liga y el psicologo se suma al abrirla.
CREATE TABLE IF NOT EXISTS public.invitaciones_consultorio (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consultorio_id uuid NOT NULL REFERENCES public.consultorios(id),
  codigo         text NOT NULL UNIQUE,
  creada_por     uuid NOT NULL REFERENCES public.psicologos(id),
  creada_en      timestamptz DEFAULT now(),
  expira_en      timestamptz NOT NULL DEFAULT (now() + interval '14 days'),
  usada_por      uuid REFERENCES public.psicologos(id),
  usada_en       timestamptz
);

-- ---------------------------------------------------------------------
-- Funciones de apoyo
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.mi_consultorio()
  RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select consultorio_id from psicologos where id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION public.soy_dueno_consultorio()
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select exists(
    select 1 from psicologos
    where id = auth.uid()
      and consultorio_id is not null
      and rol_consultorio = 'dueno'
  );
$function$;

REVOKE ALL ON FUNCTION public.mi_consultorio() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.soy_dueno_consultorio() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mi_consultorio() TO authenticated;
GRANT EXECUTE ON FUNCTION public.soy_dueno_consultorio() TO authenticated;

-- Aceptar una invitacion: el psicologo queda ligado al consultorio.
CREATE OR REPLACE FUNCTION public.aceptar_invitacion_consultorio(p_codigo text)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_uid uuid := auth.uid();
  v_inv invitaciones_consultorio%rowtype;
  v_actual uuid;
begin
  if v_uid is null then
    return query select false, 'Necesitas haber iniciado sesion.'; return;
  end if;

  select * into v_inv from invitaciones_consultorio where codigo = p_codigo;
  if not found then
    return query select false, 'Esa invitacion no existe.'; return;
  end if;
  if v_inv.usada_por is not null then
    return query select false, 'Esa invitacion ya se uso.'; return;
  end if;
  if v_inv.expira_en < now() then
    return query select false, 'Esa invitacion ya vencio. Pide una nueva.'; return;
  end if;

  select consultorio_id into v_actual from psicologos where id = v_uid;
  if v_actual is not null then
    if v_actual = v_inv.consultorio_id then
      return query select true, 'Ya perteneces a este consultorio.';
    else
      return query select false, 'Ya perteneces a otro consultorio. Sal de ese antes de unirte a este.';
    end if;
    return;
  end if;

  update psicologos
     set consultorio_id = v_inv.consultorio_id,
         rol_consultorio = 'colaborador'
   where id = v_uid;

  update invitaciones_consultorio
     set usada_por = v_uid, usada_en = now()
   where id = v_inv.id;

  return query select true, 'Te uniste al consultorio.';
end $function$;

REVOKE ALL ON FUNCTION public.aceptar_invitacion_consultorio(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aceptar_invitacion_consultorio(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.aceptar_invitacion_consultorio(text) TO authenticated;

-- ---------------------------------------------------------------------
-- Politicas
-- ---------------------------------------------------------------------

ALTER TABLE public.consultorios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invitaciones_consultorio ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "veo mi consultorio" ON public.consultorios;
CREATE POLICY "veo mi consultorio" ON public.consultorios
  FOR SELECT TO authenticated
  USING (id = public.mi_consultorio() OR dueno_id = auth.uid());

DROP POLICY IF EXISTS "creo mi consultorio" ON public.consultorios;
CREATE POLICY "creo mi consultorio" ON public.consultorios
  FOR INSERT TO authenticated
  WITH CHECK (dueno_id = auth.uid());

DROP POLICY IF EXISTS "el dueno edita su consultorio" ON public.consultorios;
CREATE POLICY "el dueno edita su consultorio" ON public.consultorios
  FOR UPDATE TO authenticated
  USING (dueno_id = auth.uid()) WITH CHECK (dueno_id = auth.uid());

DROP POLICY IF EXISTS "el dueno administra invitaciones" ON public.invitaciones_consultorio;
CREATE POLICY "el dueno administra invitaciones" ON public.invitaciones_consultorio
  FOR ALL TO authenticated
  USING (public.soy_dueno_consultorio() AND consultorio_id = public.mi_consultorio())
  WITH CHECK (public.soy_dueno_consultorio() AND consultorio_id = public.mi_consultorio());

-- El dueño ve a los psicologos de su consultorio (son sus colaboradores).
DROP POLICY IF EXISTS "el dueno ve a su equipo" ON public.psicologos;
CREATE POLICY "el dueno ve a su equipo" ON public.psicologos
  FOR SELECT TO authenticated
  USING (
    public.soy_dueno_consultorio()
    AND consultorio_id = public.mi_consultorio()
  );

-- Y ve sus citas, que es lo que sostiene agenda, ocupacion e ingresos.
-- citas no guarda contenido clinico: las notas viven en notas_sesion, que
-- deliberadamente NO se abre al dueño.
DROP POLICY IF EXISTS "el dueno ve las citas de su equipo" ON public.citas;
CREATE POLICY "el dueno ve las citas de su equipo" ON public.citas
  FOR SELECT TO authenticated
  USING (
    public.soy_dueno_consultorio()
    AND psicologo_id IN (
      select id from psicologos where consultorio_id = public.mi_consultorio()
    )
  );

-- ---------------------------------------------------------------------
-- Vista administrativa de pacientes
--
-- RLS filtra filas, no columnas: dar SELECT sobre pacientes le mostraria
-- al dueño motivo de consulta, diagnostico y riesgo. Por eso el acceso va
-- por una vista que expone unicamente lo administrativo, y sobre la tabla
-- no se le abre ninguna politica.
-- ---------------------------------------------------------------------

DROP VIEW IF EXISTS public.equipo_pacientes;
CREATE VIEW public.equipo_pacientes
  WITH (security_invoker = false) AS
  SELECT p.id,
         p.nombre,
         p.estado,
         p.psicologo_id,
         p.modalidad_atencion,
         p.creado_en
    FROM pacientes p
    JOIN psicologos ps ON ps.id = p.psicologo_id
   WHERE public.soy_dueno_consultorio()
     AND ps.consultorio_id = public.mi_consultorio();

REVOKE ALL ON public.equipo_pacientes FROM PUBLIC;
REVOKE ALL ON public.equipo_pacientes FROM anon;
GRANT SELECT ON public.equipo_pacientes TO authenticated;
