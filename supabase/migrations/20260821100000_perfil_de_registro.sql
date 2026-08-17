-- PERFIL COMPLETO AL REGISTRARSE
--
-- Hasta ahora el alta pedia nombre y correo, y todo lo demas se llenaba
-- despues -o nunca-. Eso dejaba al administrador aprobando cuentas sin saber
-- quien esta del otro lado, que es justo lo contrario de lo que deberia
-- pasar cuando lo que se aprueba es el acceso a expedientes clinicos.

ALTER TABLE public.psicologos
  ADD COLUMN IF NOT EXISTS apellido_paterno   text,
  ADD COLUMN IF NOT EXISTS apellido_materno   text,
  ADD COLUMN IF NOT EXISTS profesion          text,
  ADD COLUMN IF NOT EXISTS nombre_consultorio text,
  ADD COLUMN IF NOT EXISTS cedula_verificada  boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.psicologos.nombre IS
  'Nombre completo armado. Se conserva porque lo usa toda la app; los apellidos van aparte para poder ordenar y buscar.';
COMMENT ON COLUMN public.psicologos.cedula_verificada IS
  'La marca el administrador tras revisarla en el registro de la SEP. Praxia no puede comprobarla sola.';
COMMENT ON COLUMN public.psicologos.nombre_consultorio IS
  'Lo que declaro al registrarse. No crea el consultorio del modulo de equipo: eso se hace al activarlo.';

-- Que el correo no se repita. Antes dos altas con el mismo correo creaban dos
-- perfiles y ninguna consulta sabia cual era el bueno.
CREATE UNIQUE INDEX IF NOT EXISTS psicologos_correo_unico
  ON public.psicologos (lower(correo));

-- ---------------------------------------------------------------------
-- Alta desde el registro
-- ---------------------------------------------------------------------
-- Va por funcion y no por insert directo para que el perfil se guarde
-- completo o no se guarde: media alta es peor que ninguna, porque el
-- administrador la aprueba creyendo que reviso algo.
CREATE OR REPLACE FUNCTION public.registrar_perfil_psicologo(
  p_nombre            text,
  p_apellido_paterno  text,
  p_apellido_materno  text,
  p_telefono          text,
  p_correo            text,
  p_profesion         text,
  p_especialidad      text,
  p_cedula            text,
  p_consultorio       text DEFAULT NULL,
  p_ciudad            text DEFAULT NULL
)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_uid  uuid := auth.uid();
  v_tel  text := regexp_replace(coalesce(p_telefono,''), '\D', '', 'g');
  v_ced  text := regexp_replace(coalesce(p_cedula,''),   '\D', '', 'g');
begin
  if v_uid is null then
    return query select false, 'Necesitas haber iniciado sesión.'; return;
  end if;

  if coalesce(trim(p_nombre),'') = '' or coalesce(trim(p_apellido_paterno),'') = '' then
    return query select false, 'Falta tu nombre o tu primer apellido.'; return;
  end if;

  -- Diez digitos es un numero mexicano sin lada de pais. Se guarda limpio
  -- para que WhatsApp y las llamadas del panel funcionen sin adivinar.
  if length(v_tel) <> 10 then
    return query select false, 'El teléfono debe tener 10 dígitos.'; return;
  end if;

  -- La cedula de la SEP trae 7 u 8 digitos. Esto solo revisa la forma:
  -- que exista de verdad lo comprueba una persona antes de aprobar.
  if length(v_ced) < 7 or length(v_ced) > 8 then
    return query select false, 'La cédula profesional tiene 7 u 8 dígitos.'; return;
  end if;

  if coalesce(trim(p_profesion),'') = '' or coalesce(trim(p_especialidad),'') = '' then
    return query select false, 'Falta tu profesión o tu área.'; return;
  end if;

  insert into psicologos (
    id, nombre, apellido_paterno, apellido_materno, correo, telefono,
    profesion, especialidad, cedula_profesional, nombre_consultorio, ciudad,
    estado, perfil_completo
  ) values (
    v_uid,
    trim(p_nombre) || ' ' || trim(p_apellido_paterno)
      || case when coalesce(trim(p_apellido_materno),'') <> '' then ' ' || trim(p_apellido_materno) else '' end,
    trim(p_apellido_paterno),
    nullif(trim(coalesce(p_apellido_materno,'')), ''),
    lower(trim(p_correo)),
    v_tel,
    trim(p_profesion),
    trim(p_especialidad),
    v_ced,
    nullif(trim(coalesce(p_consultorio,'')), ''),
    nullif(trim(coalesce(p_ciudad,'')), ''),
    'pendiente',
    -- Sigue en false a proposito: perfil_completo lo marca la pantalla de
    -- bienvenida, que es donde se piden la foto, la direccion y el codigo de
    -- etica. Darlo por completo aqui haria que esa pantalla se saltara y esos
    -- datos no se pidieran nunca.
    false
  )
  -- Si vuelve a enviar el formulario -recargo, se le fue el internet- se
  -- actualiza en vez de tronar por clave duplicada.
  on conflict (id) do update set
    nombre             = excluded.nombre,
    apellido_paterno   = excluded.apellido_paterno,
    apellido_materno   = excluded.apellido_materno,
    telefono           = excluded.telefono,
    profesion          = excluded.profesion,
    especialidad       = excluded.especialidad,
    cedula_profesional = excluded.cedula_profesional,
    nombre_consultorio = excluded.nombre_consultorio,
    ciudad             = excluded.ciudad;

  return query select true, 'Tu perfil quedó registrado.';
end $function$;

REVOKE ALL ON FUNCTION public.registrar_perfil_psicologo(text,text,text,text,text,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_perfil_psicologo(text,text,text,text,text,text,text,text,text,text) TO authenticated;
