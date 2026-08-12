-- La invitacion ahora carga los datos que el dueño ya conoce de su
-- colaborador, para que el invitado no repita el alta completa.
--
-- Lo que el invitado si tiene que hacer es crear su cuenta de acceso:
-- nadie puede crear credenciales por otra persona. Con Google es un clic.
-- Lo que se le quita es el asistente de perfil y la espera de aprobacion:
-- si el responsable de un consultorio lo dio de alta, ya respondio por el.

ALTER TABLE public.invitaciones_consultorio
  ADD COLUMN IF NOT EXISTS nombre             text,
  ADD COLUMN IF NOT EXISTS correo             text,
  ADD COLUMN IF NOT EXISTS especialidad       text,
  ADD COLUMN IF NOT EXISTS cedula_profesional text,
  ADD COLUMN IF NOT EXISTS telefono           text;

-- Datos publicos minimos de la invitacion, para pintar la pantalla antes
-- de que el invitado se autentique. Expone solo lo necesario para que
-- reconozca de quien viene: no el correo ni la cedula.
CREATE OR REPLACE FUNCTION public.info_publica_invitacion(p_codigo text)
  RETURNS TABLE (
    nombre_invitado    text,
    nombre_consultorio text,
    nombre_responsable text,
    vigente            boolean
  )
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select i.nombre,
         c.nombre,
         p.nombre,
         (i.usada_por is null and i.expira_en > now())
    from invitaciones_consultorio i
    join consultorios c on c.id = i.consultorio_id
    join psicologos  p on p.id = c.dueno_id
   where i.codigo = p_codigo;
$function$;

REVOKE ALL ON FUNCTION public.info_publica_invitacion(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.info_publica_invitacion(text) TO anon;
GRANT EXECUTE ON FUNCTION public.info_publica_invitacion(text) TO authenticated;

-- Acepta la invitacion y deja el perfil listo de una vez: copia los datos
-- que cargo el responsable, liga al consultorio y da por aprobado.
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

  -- Si el responsable anoto un correo, la cuenta con la que entra debe ser
  -- esa: de lo contrario el alta quedaria a nombre de alguien distinto.
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

    -- Perfil que ya existia: se liga sin pisar lo que la persona haya puesto.
    update psicologos
       set consultorio_id  = v_inv.consultorio_id,
           rol_consultorio = 'colaborador',
           estado          = 'aprobado',
           especialidad    = coalesce(especialidad, v_inv.especialidad),
           cedula_profesional = coalesce(cedula_profesional, v_inv.cedula_profesional),
           telefono        = coalesce(telefono, v_inv.telefono)
     where id = v_uid;
  else
    -- Alta nueva: el perfil se arma con lo que cargo el responsable, asi el
    -- invitado no vuelve a capturarlo ni pasa por el asistente.
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
