-- El colaborador decide si comparte sus expedientes con el responsable del
-- consultorio. Apagado por omision: el acceso clinico se concede, no se
-- presume.
--
-- Quien manda es el psicologo tratante, porque es el responsable de los
-- datos de sus pacientes. El responsable del consultorio puede pedirlo, no
-- activarlo: por eso hay dos funciones distintas y solo una cambia el
-- interruptor.
--
-- Importante para quien opere esto: si un consultorio activa el permiso,
-- el aviso de privacidad que aceptan los pacientes deberia decirlo. Hoy ese
-- aviso dice que el responsable de sus datos es su psicologo tratante.

ALTER TABLE public.psicologos
  ADD COLUMN IF NOT EXISTS comparte_expedientes boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS comparte_expedientes_desde timestamptz;

-- ¿Puedo, como responsable, ver los expedientes de este psicologo?
-- Solo si esta en mi consultorio y el lo habilito.
CREATE OR REPLACE FUNCTION public.puedo_ver_expedientes_de(p_psicologo_id uuid)
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select exists(
    select 1
      from psicologos colaborador
      join psicologos responsable on responsable.id = auth.uid()
     where colaborador.id = p_psicologo_id
       and colaborador.comparte_expedientes = true
       and colaborador.consultorio_id is not null
       and colaborador.consultorio_id = responsable.consultorio_id
       and responsable.rol_consultorio = 'dueno'
  );
$function$;

REVOKE ALL ON FUNCTION public.puedo_ver_expedientes_de(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.puedo_ver_expedientes_de(uuid) TO authenticated;

-- El responsable solicita el acceso: no lo concede, solo avisa.
CREATE OR REPLACE FUNCTION public.solicitar_acceso_expedientes(p_psicologo_id uuid)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_nombre text;
  v_consultorio text;
begin
  if not public.soy_dueno_consultorio() then
    return query select false, 'Solo el responsable del consultorio puede solicitarlo.'; return;
  end if;

  if not exists(select 1 from psicologos where id = p_psicologo_id and consultorio_id = public.mi_consultorio()) then
    return query select false, 'Esa persona no pertenece a tu consultorio.'; return;
  end if;

  if exists(select 1 from psicologos where id = p_psicologo_id and comparte_expedientes) then
    return query select false, 'Ya te compartió el acceso a sus expedientes.'; return;
  end if;

  select nombre into v_nombre from psicologos where id = auth.uid();
  select nombre into v_consultorio from consultorios where id = public.mi_consultorio();

  insert into notificaciones (psicologo_id, tipo, titulo, mensaje)
  values (
    p_psicologo_id,
    'solicitud_expedientes',
    v_nombre || ' pide acceso a tus expedientes',
    'Como responsable de ' || coalesce(v_consultorio,'el consultorio') ||
    ', pide poder consultar los expedientes de tus pacientes. Tú decides: puedes activarlo o dejarlo apagado desde tu consultorio, y quitarlo cuando quieras.'
  );

  return query select true, 'Se le envió la solicitud. Queda de su lado decidir.';
end $function$;

REVOKE ALL ON FUNCTION public.solicitar_acceso_expedientes(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.solicitar_acceso_expedientes(uuid) TO authenticated;

-- El colaborador enciende o apaga el permiso, y se avisa al responsable.
CREATE OR REPLACE FUNCTION public.definir_acceso_expedientes(p_compartir boolean)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_consultorio uuid;
  v_dueno uuid;
  v_nombre text;
begin
  select consultorio_id, nombre into v_consultorio, v_nombre
    from psicologos where id = auth.uid();

  if v_consultorio is null then
    return query select false, 'No perteneces a ningún consultorio.'; return;
  end if;

  update psicologos
     set comparte_expedientes = p_compartir,
         comparte_expedientes_desde = case when p_compartir then now() else null end
   where id = auth.uid();

  select dueno_id into v_dueno from consultorios where id = v_consultorio;

  if v_dueno is not null and v_dueno <> auth.uid() then
    insert into notificaciones (psicologo_id, tipo, titulo, mensaje)
    values (
      v_dueno,
      'permiso_expedientes',
      v_nombre || (case when p_compartir then ' te dio acceso a sus expedientes' else ' retiró tu acceso a sus expedientes' end),
      case when p_compartir
        then 'Ya puedes consultar los expedientes de sus pacientes. Recuerda que sigue siendo el responsable de esa información.'
        else 'Dejaste de tener acceso a los expedientes de sus pacientes.'
      end
    );
  end if;

  return query select true,
    case when p_compartir
      then 'Compartiste el acceso a tus expedientes.'
      else 'Retiraste el acceso a tus expedientes.'
    end;
end $function$;

REVOKE ALL ON FUNCTION public.definir_acceso_expedientes(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.definir_acceso_expedientes(boolean) TO authenticated;

-- ---------------------------------------------------------------------
-- Politicas de lectura clinica, condicionadas al permiso
-- ---------------------------------------------------------------------

DROP POLICY IF EXISTS "el dueno lee expedientes autorizados" ON public.pacientes;
CREATE POLICY "el dueno lee expedientes autorizados" ON public.pacientes
  FOR SELECT TO authenticated
  USING (public.puedo_ver_expedientes_de(psicologo_id));

DROP POLICY IF EXISTS "el dueno lee notas autorizadas" ON public.notas_sesion;
CREATE POLICY "el dueno lee notas autorizadas" ON public.notas_sesion
  FOR SELECT TO authenticated
  USING (public.puedo_ver_expedientes_de(psicologo_id));

DROP POLICY IF EXISTS "el dueno lee evaluaciones autorizadas" ON public.evaluaciones_psicologicas;
CREATE POLICY "el dueno lee evaluaciones autorizadas" ON public.evaluaciones_psicologicas
  FOR SELECT TO authenticated
  USING (public.puedo_ver_expedientes_de(psicologo_id));

DROP POLICY IF EXISTS "el dueno lee objetivos autorizados" ON public.objetivos_terapeuticos;
CREATE POLICY "el dueno lee objetivos autorizados" ON public.objetivos_terapeuticos
  FOR SELECT TO authenticated
  USING (public.puedo_ver_expedientes_de(psicologo_id));

DROP POLICY IF EXISTS "el dueno lee medicacion autorizada" ON public.medicamentos;
CREATE POLICY "el dueno lee medicacion autorizada" ON public.medicamentos
  FOR SELECT TO authenticated
  USING (public.puedo_ver_expedientes_de(psicologo_id));

DROP POLICY IF EXISTS "el dueno lee documentos autorizados" ON public.documentos;
CREATE POLICY "el dueno lee documentos autorizados" ON public.documentos
  FOR SELECT TO authenticated
  USING (public.puedo_ver_expedientes_de(psicologo_id));
