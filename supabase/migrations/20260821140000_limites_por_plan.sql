-- LIMITES DE CADA PLAN
--
-- El plan economico es para quien lleva pocos pacientes: hasta 7 expedientes.
-- El de consultorio no limita expedientes, pero si cuantos psicologos caben
-- en el equipo.
--
-- Los limites se revisan en la base y no en la pantalla. Un limite que solo
-- vive en el navegador no es un limite: basta con llamar a la API directo.

ALTER TABLE public.planes
  ADD COLUMN IF NOT EXISTS limite_pacientes int;

COMMENT ON COLUMN public.planes.limite_pacientes IS
  'Cuantos expedientes caben. Nulo = sin limite.';

UPDATE public.planes SET limite_pacientes = 7,    limite_psicologos = 1 WHERE id = 'individual';
UPDATE public.planes SET limite_pacientes = NULL, limite_psicologos = 7 WHERE id = 'consultorio';

ALTER TABLE public.psicologos
  ADD COLUMN IF NOT EXISTS pacientes_estimados int,
  ADD COLUMN IF NOT EXISTS plan_elegido        text;

COMMENT ON COLUMN public.psicologos.plan_elegido IS
  'Lo que dijo querer al registrarse. La suscripcion real manda; esto sirve para saber que esperaba.';

-- ---------------------------------------------------------------------
-- Cuantos expedientes le tocan
-- ---------------------------------------------------------------------
-- Se mira el plan del titular, no el del colaborador: en un consultorio la
-- suscripcion la paga el dueño y cubre a su equipo.
CREATE OR REPLACE FUNCTION public.limite_de_pacientes(p_psicologo uuid)
  RETURNS int
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select pl.limite_pacientes
    from suscripciones s
    join planes pl on pl.id = s.plan_id
   where s.titular_id = coalesce(
           (select c.dueno_id from consultorios c
             where c.id = (select consultorio_id from psicologos where id = p_psicologo)),
           p_psicologo)
   limit 1;
$function$;

-- Si no se encuentra plan, no se limita: dejar a alguien sin poder dar de
-- alta un paciente por un dato faltante es peor que dejarlo pasar.
CREATE OR REPLACE FUNCTION public.revisar_limite_de_pacientes()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_limite int;
  v_tiene  int;
begin
  v_limite := public.limite_de_pacientes(NEW.psicologo_id);
  if v_limite is null then
    return NEW;
  end if;

  select count(*) into v_tiene
    from pacientes
   where psicologo_id = NEW.psicologo_id
     and coalesce(estado, 'activo') <> 'archivado';

  if v_tiene >= v_limite then
    -- El mensaje dice el limite y la salida. Un error que solo dice "no se
    -- pudo" manda a la persona a soporte por algo que puede resolver sola.
    raise exception
      'Tu plan permite % expedientes y ya tienes %. Cambia al plan Consultorio para tener expedientes ilimitados.',
      v_limite, v_tiene
      using errcode = 'check_violation';
  end if;

  return NEW;
end $function$;

DROP TRIGGER IF EXISTS trg_limite_pacientes ON public.pacientes;
CREATE TRIGGER trg_limite_pacientes
  BEFORE INSERT ON public.pacientes
  FOR EACH ROW EXECUTE FUNCTION public.revisar_limite_de_pacientes();

-- Lo que el panel necesita para avisar antes de toparse con el limite.
CREATE OR REPLACE FUNCTION public.mi_cupo_de_pacientes()
  RETURNS TABLE (limite int, usados int, restantes int)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select
    public.limite_de_pacientes(auth.uid()),
    (select count(*)::int from pacientes
      where psicologo_id = auth.uid() and coalesce(estado,'activo') <> 'archivado'),
    case when public.limite_de_pacientes(auth.uid()) is null then null
         else greatest(0, public.limite_de_pacientes(auth.uid())
              - (select count(*)::int from pacientes
                  where psicologo_id = auth.uid() and coalesce(estado,'activo') <> 'archivado'))
    end;
$function$;

REVOKE ALL ON FUNCTION public.limite_de_pacientes(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mi_cupo_de_pacientes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mi_cupo_de_pacientes() TO authenticated;

-- ---------------------------------------------------------------------
-- El registro ahora guarda tambien cuantos pacientes espera y que plan quiere
-- ---------------------------------------------------------------------
-- Se borra antes porque cambia la firma: Postgres no deja reemplazar una
-- funcion agregandole parametros sin quitar la anterior, y dejar las dos
-- crea una ambiguedad que falla en tiempo de ejecucion.
DROP FUNCTION IF EXISTS public.registrar_perfil_psicologo(text,text,text,text,text,text,text,text,text,text);

CREATE OR REPLACE FUNCTION public.registrar_perfil_psicologo(
  p_nombre              text,
  p_apellido_paterno    text,
  p_apellido_materno    text,
  p_telefono            text,
  p_correo              text,
  p_profesion           text,
  p_especialidad        text,
  p_cedula              text,
  p_consultorio         text DEFAULT NULL,
  p_ciudad              text DEFAULT NULL,
  p_pacientes_estimados int  DEFAULT NULL,
  p_plan                text DEFAULT NULL
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

  if length(v_tel) <> 10 then
    return query select false, 'El teléfono debe tener 10 dígitos.'; return;
  end if;

  if length(v_ced) < 7 or length(v_ced) > 8 then
    return query select false, 'La cédula profesional tiene 7 u 8 dígitos.'; return;
  end if;

  if coalesce(trim(p_profesion),'') = '' or coalesce(trim(p_especialidad),'') = '' then
    return query select false, 'Falta tu profesión o tu área.'; return;
  end if;

  -- El plan tiene que existir de verdad. Guardar uno inventado haria que
  -- despues no cuadre con ninguna suscripcion.
  if p_plan is not null and not exists(select 1 from planes where id = p_plan) then
    return query select false, 'Ese plan no existe.'; return;
  end if;

  insert into psicologos (
    id, nombre, apellido_paterno, apellido_materno, correo, telefono,
    profesion, especialidad, cedula_profesional, nombre_consultorio, ciudad,
    pacientes_estimados, plan_elegido, estado, perfil_completo
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
    p_pacientes_estimados,
    p_plan,
    'pendiente',
    false
  )
  on conflict (id) do update set
    nombre              = excluded.nombre,
    apellido_paterno    = excluded.apellido_paterno,
    apellido_materno    = excluded.apellido_materno,
    telefono            = excluded.telefono,
    profesion           = excluded.profesion,
    especialidad        = excluded.especialidad,
    cedula_profesional  = excluded.cedula_profesional,
    nombre_consultorio  = excluded.nombre_consultorio,
    ciudad              = excluded.ciudad,
    pacientes_estimados = excluded.pacientes_estimados,
    plan_elegido        = excluded.plan_elegido;

  return query select true, 'Tu perfil quedó registrado.';
end $function$;

REVOKE ALL ON FUNCTION public.registrar_perfil_psicologo(text,text,text,text,text,text,text,text,text,text,int,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_perfil_psicologo(text,text,text,text,text,text,text,text,text,text,int,text) TO authenticated;
