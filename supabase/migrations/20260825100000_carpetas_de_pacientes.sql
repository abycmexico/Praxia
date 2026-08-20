-- CARPETAS DE PACIENTES
--
-- Con veinte o treinta pacientes, una sola rejilla deja de servir. Cada
-- psicologo agrupa distinto -por dia de atencion, por tipo de caso, por
-- quien paga- y no hay una clasificacion correcta que imponer desde aqui.
-- Asi que se le dan carpetas vacias y el decide que significan.
--
-- La carpeta es organizacion, no clinica: no cambia permisos ni quien ve
-- que. Un paciente sin carpeta sigue siendo visible como siempre.

CREATE TABLE IF NOT EXISTS public.carpetas_pacientes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  psicologo_id uuid NOT NULL REFERENCES public.psicologos(id) ON DELETE CASCADE,
  nombre       text NOT NULL CHECK (length(trim(nombre)) > 0),
  color        text,
  orden        int NOT NULL DEFAULT 0,
  creado_en    timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS carpetas_por_psicologo
  ON public.carpetas_pacientes (psicologo_id, orden);

-- Dos carpetas con el mismo nombre confunden mas de lo que ordenan.
CREATE UNIQUE INDEX IF NOT EXISTS carpetas_nombre_unico
  ON public.carpetas_pacientes (psicologo_id, lower(trim(nombre)));

ALTER TABLE public.carpetas_pacientes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cada quien sus carpetas" ON public.carpetas_pacientes;
CREATE POLICY "cada quien sus carpetas" ON public.carpetas_pacientes
  FOR ALL TO authenticated
  USING (psicologo_id = auth.uid())
  WITH CHECK (psicologo_id = auth.uid());

-- Al borrar la carpeta, sus pacientes vuelven a quedar sueltos. Nunca se
-- borra un paciente por borrar una carpeta: son cosas de distinto peso.
ALTER TABLE public.pacientes
  ADD COLUMN IF NOT EXISTS carpeta_id uuid
  REFERENCES public.carpetas_pacientes(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS pacientes_por_carpeta
  ON public.pacientes (carpeta_id);

COMMENT ON COLUMN public.pacientes.carpeta_id IS
  'Solo organiza la vista del psicologo. No cambia permisos ni acceso.';

-- ---------------------------------------------------------------------
-- Mover un paciente
-- ---------------------------------------------------------------------
-- Va por funcion para comprobar que tanto el paciente como la carpeta sean
-- suyos. Sin eso se podria mover el paciente de otro psicologo, o meterlo
-- en la carpeta de alguien mas.
CREATE OR REPLACE FUNCTION public.mover_paciente_a_carpeta(
  p_paciente_id uuid,
  p_carpeta_id  uuid DEFAULT NULL
)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return query select false, 'Necesitas haber iniciado sesión.'; return;
  end if;

  if not exists(select 1 from pacientes where id = p_paciente_id and psicologo_id = v_uid) then
    return query select false, 'Ese paciente no te pertenece.'; return;
  end if;

  if p_carpeta_id is not null
     and not exists(select 1 from carpetas_pacientes where id = p_carpeta_id and psicologo_id = v_uid) then
    return query select false, 'Esa carpeta no existe o no es tuya.'; return;
  end if;

  update pacientes set carpeta_id = p_carpeta_id where id = p_paciente_id;

  return query select true, case
    when p_carpeta_id is null then 'El paciente quedó fuera de las carpetas.'
    else 'Paciente movido.' end;
end $function$;

REVOKE ALL ON FUNCTION public.mover_paciente_a_carpeta(uuid,uuid) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.mover_paciente_a_carpeta(uuid,uuid) TO authenticated;
REVOKE ALL ON public.carpetas_pacientes FROM anon;
