-- El responsable del consultorio administra la operacion: da de alta
-- pacientes y los asigna, agenda sesiones para su equipo, y saca a quien
-- deja de trabajar ahi. Es lo que hace la recepcion de un consultorio.
--
-- Lo que sigue sin poder: leer expedientes y notas de sesion de pacientes
-- que no atiende. Puede crear el registro de un paciente y asignarlo, pero
-- el contenido clinico queda del psicologo tratante. Por eso aqui solo se
-- agregan politicas de INSERT y UPDATE acotadas, nunca de SELECT sobre
-- pacientes: para consultar sigue existiendo la vista equipo_pacientes,
-- que expone unicamente columnas administrativas.

-- Da de alta pacientes y los asigna a un psicologo de su consultorio.
DROP POLICY IF EXISTS "el dueno da de alta pacientes" ON public.pacientes;
CREATE POLICY "el dueno da de alta pacientes" ON public.pacientes
  FOR INSERT TO authenticated
  WITH CHECK (
    public.soy_dueno_consultorio()
    AND psicologo_id IN (
      select id from psicologos where consultorio_id = public.mi_consultorio()
    )
  );

-- Puede reasignar un paciente a otro psicologo del mismo consultorio.
-- La condicion se exige en ambos lados para que no pueda sacarlo del
-- consultorio ni traerse uno ajeno.
DROP POLICY IF EXISTS "el dueno reasigna pacientes de su consultorio" ON public.pacientes;
CREATE POLICY "el dueno reasigna pacientes de su consultorio" ON public.pacientes
  FOR UPDATE TO authenticated
  USING (
    public.soy_dueno_consultorio()
    AND psicologo_id IN (
      select id from psicologos where consultorio_id = public.mi_consultorio()
    )
  )
  WITH CHECK (
    public.soy_dueno_consultorio()
    AND psicologo_id IN (
      select id from psicologos where consultorio_id = public.mi_consultorio()
    )
  );

-- Agenda sesiones para los psicologos de su consultorio.
DROP POLICY IF EXISTS "el dueno agenda para su equipo" ON public.citas;
CREATE POLICY "el dueno agenda para su equipo" ON public.citas
  FOR INSERT TO authenticated
  WITH CHECK (
    public.soy_dueno_consultorio()
    AND psicologo_id IN (
      select id from psicologos where consultorio_id = public.mi_consultorio()
    )
  );

DROP POLICY IF EXISTS "el dueno ajusta las citas de su equipo" ON public.citas;
CREATE POLICY "el dueno ajusta las citas de su equipo" ON public.citas
  FOR UPDATE TO authenticated
  USING (
    public.soy_dueno_consultorio()
    AND psicologo_id IN (
      select id from psicologos where consultorio_id = public.mi_consultorio()
    )
  )
  WITH CHECK (
    public.soy_dueno_consultorio()
    AND psicologo_id IN (
      select id from psicologos where consultorio_id = public.mi_consultorio()
    )
  );

-- Sacar a alguien del consultorio.
--
-- Sus pacientes NO se reasignan solos: el expediente es del psicologo que
-- lo atiende, y moverlo sin que el paciente lo sepa seria un traspaso a sus
-- espaldas. La funcion avisa cuantos pacientes se van con el para que el
-- responsable lo resuelva de frente.
CREATE OR REPLACE FUNCTION public.quitar_del_consultorio(p_psicologo_id uuid)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_consultorio uuid;
  v_pacientes int;
begin
  if not public.soy_dueno_consultorio() then
    return query select false, 'Solo el responsable del consultorio puede hacer esto.'; return;
  end if;

  v_consultorio := public.mi_consultorio();

  if p_psicologo_id = auth.uid() then
    return query select false, 'No puedes sacarte a ti mismo: eres el responsable.'; return;
  end if;

  if not exists(select 1 from psicologos where id = p_psicologo_id and consultorio_id = v_consultorio) then
    return query select false, 'Esa persona no pertenece a tu consultorio.'; return;
  end if;

  select count(*) into v_pacientes from pacientes where psicologo_id = p_psicologo_id;

  update psicologos
     set consultorio_id = null, rol_consultorio = null
   where id = p_psicologo_id;

  return query select true,
    case when v_pacientes > 0
      then 'Se retiró del consultorio. Sus ' || v_pacientes || ' paciente(s) siguen siendo suyos: si deben quedarse en el consultorio, hay que acordar el traspaso con cada uno.'
      else 'Se retiró del consultorio.'
    end;
end $function$;

REVOKE ALL ON FUNCTION public.quitar_del_consultorio(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quitar_del_consultorio(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.quitar_del_consultorio(uuid) TO authenticated;

-- La vista administrativa suma el dato de especialidad, para agrupar el
-- equipo por area, y el correo y telefono del paciente, que la recepcion
-- necesita para confirmar citas. Nada de eso es contenido clinico.
DROP VIEW IF EXISTS public.equipo_pacientes;
CREATE VIEW public.equipo_pacientes
  WITH (security_invoker = false) AS
  SELECT p.id,
         p.nombre,
         p.estado,
         p.psicologo_id,
         p.modalidad_atencion,
         p.correo,
         p.telefono,
         p.creado_en,
         ps.nombre       AS psicologo_nombre,
         ps.especialidad AS psicologo_especialidad
    FROM pacientes p
    JOIN psicologos ps ON ps.id = p.psicologo_id
   WHERE public.soy_dueno_consultorio()
     AND ps.consultorio_id = public.mi_consultorio();

REVOKE ALL ON public.equipo_pacientes FROM PUBLIC;
REVOKE ALL ON public.equipo_pacientes FROM anon;
GRANT SELECT ON public.equipo_pacientes TO authenticated;
