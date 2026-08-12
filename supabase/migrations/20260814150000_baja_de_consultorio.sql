-- Cuando el responsable retira a alguien, su acceso queda inhabilitado y se
-- le muestra un aviso al entrar, en vez de que descubra solo que ya no ve
-- nada.
--
-- Lo que NO se hace aqui, a proposito: borrar nada. Ese psicologo tiene
-- pacientes con expedientes clinicos, y esos expedientes son de los
-- pacientes, no del consultorio. Los criterios de conservacion de un
-- expediente clinico se miden en años, y los pacientes conservan sus
-- derechos de acceso sobre esa informacion. Una politica de retencion, si
-- se quiere, hay que diseñarla aparte y de modo que no arrastre datos de
-- terceros que no tuvieron parte en la salida.

ALTER TABLE public.psicologos
  ADD COLUMN IF NOT EXISTS baja_consultorio_en     timestamptz,
  ADD COLUMN IF NOT EXISTS baja_consultorio_nombre text;

CREATE OR REPLACE FUNCTION public.quitar_del_consultorio(p_psicologo_id uuid)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_consultorio uuid;
  v_nombre text;
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

  select nombre into v_nombre from consultorios where id = v_consultorio;
  select count(*) into v_pacientes from pacientes where psicologo_id = p_psicologo_id;

  update psicologos
     set consultorio_id  = null,
         rol_consultorio = null,
         baja_consultorio_en     = now(),
         baja_consultorio_nombre = v_nombre
   where id = p_psicologo_id;

  return query select true,
    case when v_pacientes > 0
      then 'Se retiró del consultorio y su acceso quedó inhabilitado. Sus ' || v_pacientes || ' paciente(s) siguen siendo suyos: si deben quedarse en el consultorio, hay que acordar el traspaso con cada uno.'
      else 'Se retiró del consultorio y su acceso quedó inhabilitado.'
    end;
end $function$;

REVOKE ALL ON FUNCTION public.quitar_del_consultorio(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quitar_del_consultorio(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.quitar_del_consultorio(uuid) TO authenticated;

-- Reactivar a alguien que se dio de baja: al volver a darlo de alta con una
-- liga, la marca de baja se limpia y recupera su acceso.
CREATE OR REPLACE FUNCTION public.aceptar_invitacion_consultorio(p_codigo text)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_uid uuid := auth.uid();
  v_correo text := auth.jwt() ->> 'email';
  v_inv invitaciones_consultorio%rowtype;
  v_actual uuid;
  v_existe boolean;
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

  if v_inv.correo is not null and lower(v_inv.correo) <> lower(coalesce(v_correo,'')) then
    return query select false,
      'Esta invitacion es para ' || v_inv.correo || '. Entra con esa cuenta.';
    return;
  end if;

  select exists(select 1 from psicologos where id = v_uid) into v_existe;

  if v_existe then
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
       set consultorio_id  = v_inv.consultorio_id,
           rol_consultorio = 'colaborador',
           estado          = 'aprobado',
           especialidad    = coalesce(especialidad, v_inv.especialidad),
           cedula_profesional = coalesce(cedula_profesional, v_inv.cedula_profesional),
           telefono        = coalesce(telefono, v_inv.telefono),
           baja_consultorio_en     = null,
           baja_consultorio_nombre = null
     where id = v_uid;
  else
    insert into psicologos (
      id, nombre, correo, estado, especialidad, cedula_profesional, telefono,
      consultorio_id, rol_consultorio, perfil_completo
    ) values (
      v_uid,
      coalesce(v_inv.nombre, split_part(coalesce(v_correo,'Psicologo'),'@',1)),
      coalesce(v_correo, v_inv.correo),
      'aprobado',
      v_inv.especialidad,
      v_inv.cedula_profesional,
      v_inv.telefono,
      v_inv.consultorio_id,
      'colaborador',
      true
    );
  end if;

  update invitaciones_consultorio
     set usada_por = v_uid, usada_en = now()
   where id = v_inv.id;

  return query select true, 'Te uniste al consultorio.';
end $function$;

REVOKE ALL ON FUNCTION public.aceptar_invitacion_consultorio(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aceptar_invitacion_consultorio(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.aceptar_invitacion_consultorio(text) TO authenticated;
