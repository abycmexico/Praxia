-- Migration unit 1: schema_changes
-- Transaction mode: transactional
-- Boundary reason: default

SET check_function_bodies = false;

DROP FUNCTION
  public.actualizar_mis_datos(IN p_nombre text, IN p_telefono text, IN p_fecha_nacimiento date, IN p_emergencia_nombre text, IN p_emergencia_telefono text, IN p_foto_url text);

ALTER TABLE public.citas
  DROP CONSTRAINT citas_estado_valido;

ALTER TABLE public.pacientes
  DROP CONSTRAINT pacientes_id_fkey;

DROP VIEW public.psicologos_publicos;

DROP POLICY "paciente actualiza sus citas" ON public.citas;

DROP POLICY "paciente ve sus propias citas" ON public.citas;

DROP POLICY "paciente registra su consentimiento" ON public.consentimientos;

DROP POLICY "paciente ve sus consentimientos" ON public.consentimientos;

DROP POLICY "paciente sube sus documentos" ON public.documentos;

DROP POLICY "paciente ve sus documentos" ON public.documentos;

DROP POLICY "pacientes ven su propio perfil" ON public.pacientes;

CREATE FUNCTION public.actualizar_mis_datos (
  p_nombre              text DEFAULT NULL::text,
  p_telefono            text DEFAULT NULL::text,
  p_fecha_nacimiento    date DEFAULT NULL::date,
  p_emergencia_nombre   text DEFAULT NULL::text,
  p_emergencia_telefono text DEFAULT NULL::text,
  p_foto_url            text DEFAULT NULL::text
)
  RETURNS TABLE (
    ok      boolean,
    mensaje text
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_id uuid;
begin
  select id into v_id from pacientes where auth_user_id = auth.uid();
  if v_id is null then
    return query select false, 'No se encontró tu expediente.'; return;
  end if;

  update pacientes set
    nombre = coalesce(p_nombre, nombre),
    telefono = coalesce(p_telefono, telefono),
    fecha_nacimiento = coalesce(p_fecha_nacimiento, fecha_nacimiento),
    contacto_emergencia_nombre = coalesce(p_emergencia_nombre, contacto_emergencia_nombre),
    contacto_emergencia_telefono = coalesce(p_emergencia_telefono, contacto_emergencia_telefono),
    foto_url = coalesce(p_foto_url, foto_url)
  where id = v_id;

  return query select true, 'Datos actualizados.';
end $function$;

GRANT ALL ON FUNCTION public.actualizar_mis_datos(text, text, date, text, text, text) TO anon;

GRANT ALL ON FUNCTION public.actualizar_mis_datos(text, text, date, text, text, text) TO authenticated;

GRANT ALL ON FUNCTION public.actualizar_mis_datos(text, text, date, text, text, text) TO service_role;

CREATE FUNCTION public.aprobar_solicitud_paciente (
  p_cita_id uuid
)
  RETURNS TABLE (
    ok      boolean,
    mensaje text
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_cita citas%rowtype;
  v_ocupado int;
  v_nuevo_estado text;
begin
  select * into v_cita from citas where id = p_cita_id;

  if not found or v_cita.psicologo_id <> auth.uid() then
    return query select false, 'No tienes permiso sobre esa solicitud.'; return;
  end if;
  if v_cita.estado <> 'pendiente_aprobacion' then
    return query select false, 'Esta solicitud ya fue procesada.'; return;
  end if;
  if v_cita.fecha_hora <= now() then
    return query select false, 'Esa fecha ya pasó.'; return;
  end if;

  select count(*) into v_ocupado from citas
   where psicologo_id = auth.uid() and id <> p_cita_id
     and estado in ('pendiente_confirmacion','pendiente_pago','confirmada')
     and fecha_hora < (v_cita.fecha_hora + make_interval(mins => v_cita.duracion_minutos))
     and (fecha_hora + make_interval(mins => duracion_minutos)) > v_cita.fecha_hora;

  if v_ocupado > 0 then
    return query select false, 'Ya tienes otra cita confirmada en ese horario. Recházala o reprograma antes.'; return;
  end if;

  v_nuevo_estado := case when coalesce(v_cita.precio,0) > 0 then 'pendiente_pago' else 'confirmada' end;
  update citas set estado = v_nuevo_estado where id = p_cita_id;

  return query select true, 'Solicitud aprobada.';
end $function$;

GRANT ALL ON FUNCTION public.aprobar_solicitud_paciente(uuid) TO anon;

GRANT ALL ON FUNCTION public.aprobar_solicitud_paciente(uuid) TO authenticated;

GRANT ALL ON FUNCTION public.aprobar_solicitud_paciente(uuid) TO service_role;

CREATE FUNCTION public.crear_consulta_rapida (
  p_paciente_id uuid,
  p_precio      numeric DEFAULT 0
)
  RETURNS TABLE (
    ok      boolean,
    mensaje text,
    cita_id uuid,
    estado  text
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_paciente pacientes%rowtype;
  v_config configuracion%rowtype;
  v_estado text;
  v_id uuid;
begin
  select * into v_paciente from pacientes where id = p_paciente_id;
  if not found or v_paciente.psicologo_id <> auth.uid() then
    return query select false, 'Ese paciente no te pertenece.', null::uuid, null::text;
    return;
  end if;

  select * into v_config from configuracion where psicologo_id = auth.uid();
  v_estado := case when coalesce(p_precio,0) > 0 then 'pendiente_pago' else 'confirmada' end;

  insert into citas (psicologo_id, paciente_id, fecha_hora, duracion_minutos, precio, estado)
  values (auth.uid(), p_paciente_id, now(), coalesce(v_config.duracion_sesion, 50), coalesce(p_precio, 0), v_estado)
  returning id into v_id;

  return query select true, 'Consulta creada.', v_id, v_estado;
end $function$;

GRANT ALL ON FUNCTION public.crear_consulta_rapida(uuid, numeric) TO anon;

GRANT ALL ON FUNCTION public.crear_consulta_rapida(uuid, numeric) TO authenticated;

GRANT ALL ON FUNCTION public.crear_consulta_rapida(uuid, numeric) TO service_role;

CREATE OR REPLACE FUNCTION public.crear_estado_oauth_google()
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_state uuid;
begin
  delete from google_oauth_estados where creado_en < now() - interval '10 minutes';
  insert into google_oauth_estados (psicologo_id) values (auth.uid())
  returning state into v_state;
  return v_state;
end $function$;

CREATE FUNCTION public.crear_paciente_directo (
  p_nombre             text,
  p_correo             text    DEFAULT NULL::text,
  p_telefono           text    DEFAULT NULL::text,
  p_modalidad_atencion text    DEFAULT 'presencial'::text,
  p_es_menor_edad      boolean DEFAULT false,
  p_tutor_nombre       text    DEFAULT NULL::text,
  p_tutor_relacion     text    DEFAULT NULL::text,
  p_tutor_telefono     text    DEFAULT NULL::text,
  p_tutor_correo       text    DEFAULT NULL::text
)
  RETURNS TABLE (
    ok          boolean,
    mensaje     text,
    paciente_id uuid
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare v_id uuid;
begin
  if p_nombre is null or trim(p_nombre) = '' then
    return query select false, 'Falta el nombre del paciente.', null::uuid; return;
  end if;
  if p_es_menor_edad and (p_tutor_nombre is null or trim(p_tutor_nombre) = '') then
    return query select false, 'Falta el nombre del tutor legal.', null::uuid; return;
  end if;

  insert into pacientes (
    nombre, correo, telefono, modalidad_atencion, psicologo_id, estado,
    es_menor_edad, tutor_nombre, tutor_relacion, tutor_telefono, tutor_correo
  )
  values (
    trim(p_nombre), p_correo, p_telefono, p_modalidad_atencion, auth.uid(), 'activo',
    p_es_menor_edad, p_tutor_nombre, p_tutor_relacion, p_tutor_telefono, p_tutor_correo
  )
  returning id into v_id;

  return query select true, 'Paciente creado.', v_id;
end $function$;

GRANT ALL ON FUNCTION public.crear_paciente_directo(text, text, text, text, boolean, text, text, text, text) TO anon;

GRANT ALL ON FUNCTION public.crear_paciente_directo(text, text, text, text, boolean, text, text, text, text) TO authenticated;

GRANT ALL ON FUNCTION public.crear_paciente_directo(text, text, text, text, boolean, text, text, text, text) TO service_role;

CREATE FUNCTION public.crear_paciente_directo (
  p_nombre             text,
  p_correo             text DEFAULT NULL::text,
  p_telefono           text DEFAULT NULL::text,
  p_modalidad_atencion text DEFAULT 'presencial'::text
)
  RETURNS TABLE (
    ok          boolean,
    mensaje     text,
    paciente_id uuid
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare v_id uuid;
begin
  if p_nombre is null or trim(p_nombre) = '' then
    return query select false, 'Falta el nombre del paciente.', null::uuid; return;
  end if;
  insert into pacientes (nombre, correo, telefono, modalidad_atencion, psicologo_id, estado)
  values (trim(p_nombre), p_correo, p_telefono, p_modalidad_atencion, auth.uid(), 'activo')
  returning id into v_id;
  return query select true, 'Paciente creado.', v_id;
end $function$;

GRANT ALL ON FUNCTION public.crear_paciente_directo(text, text, text, text) TO anon;

GRANT ALL ON FUNCTION public.crear_paciente_directo(text, text, text, text) TO authenticated;

GRANT ALL ON FUNCTION public.crear_paciente_directo(text, text, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.desconectar_google_calendar()
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
  delete from google_calendar_tokens where psicologo_id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION public.esta_conectado_google_calendar()
  RETURNS boolean
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
  select exists(select 1 from google_calendar_tokens where psicologo_id = auth.uid());
$function$;

CREATE FUNCTION public.info_publica_claim (
  p_paciente_id uuid
)
  RETURNS TABLE (
    nombre        text,
    correo        text,
    es_menor_edad boolean,
    tutor_nombre  text
  )
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
  select nombre, correo, es_menor_edad, tutor_nombre
  from pacientes
  where id = p_paciente_id and auth_user_id is null;
$function$;

GRANT ALL ON FUNCTION public.info_publica_claim(uuid) TO anon;

GRANT ALL ON FUNCTION public.info_publica_claim(uuid) TO authenticated;

GRANT ALL ON FUNCTION public.info_publica_claim(uuid) TO service_role;

CREATE FUNCTION public.mi_paciente_id()
  RETURNS uuid
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
  select id from pacientes where auth_user_id = auth.uid();
$function$;

GRANT ALL ON FUNCTION public.mi_paciente_id() TO anon;

GRANT ALL ON FUNCTION public.mi_paciente_id() TO authenticated;

GRANT ALL ON FUNCTION public.mi_paciente_id() TO service_role;

CREATE FUNCTION public.notificar_solicitud_cita()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_nombre_paciente text;
begin
  if NEW.estado = 'pendiente_aprobacion' then
    select nombre into v_nombre_paciente from pacientes where id = NEW.paciente_id;
    insert into notificaciones (psicologo_id, tipo, titulo, mensaje, cita_id)
    values (
      NEW.psicologo_id,
      'solicitud_cita',
      'Nueva solicitud de sesión',
      coalesce(v_nombre_paciente, 'Un paciente') || ' solicitó una sesión para el ' ||
        to_char(NEW.fecha_hora, 'DD/MM/YYYY') || ' a las ' || to_char(NEW.fecha_hora, 'HH24:MI'),
      NEW.id
    );
  end if;
  return NEW;
end $function$;

GRANT ALL ON FUNCTION public.notificar_solicitud_cita() TO anon;

GRANT ALL ON FUNCTION public.notificar_solicitud_cita() TO authenticated;

GRANT ALL ON FUNCTION public.notificar_solicitud_cita() TO service_role;

CREATE FUNCTION public.rechazar_solicitud_paciente (
  p_cita_id uuid,
  p_motivo  text DEFAULT NULL::text
)
  RETURNS TABLE (
    ok      boolean,
    mensaje text
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_cita citas%rowtype;
begin
  select * into v_cita from citas where id = p_cita_id;
  if not found or v_cita.psicologo_id <> auth.uid() then
    return query select false, 'No tienes permiso sobre esa solicitud.'; return;
  end if;
  if v_cita.estado <> 'pendiente_aprobacion' then
    return query select false, 'Esta solicitud ya fue procesada.'; return;
  end if;

  update citas
     set estado = 'cancelada', cancelada_en = now(), cancelada_por = 'psicologo',
         motivo_cancelacion = coalesce(p_motivo, 'El psicólogo no pudo en ese horario')
   where id = p_cita_id;

  return query select true, 'Solicitud rechazada.';
end $function$;

GRANT ALL ON FUNCTION public.rechazar_solicitud_paciente(uuid, text) TO anon;

GRANT ALL ON FUNCTION public.rechazar_solicitud_paciente(uuid, text) TO authenticated;

GRANT ALL ON FUNCTION public.rechazar_solicitud_paciente(uuid, text) TO service_role;

CREATE FUNCTION public.solicitar_cita_paciente (
  p_fecha_hora timestamp with time zone
)
  RETURNS TABLE (
    ok      boolean,
    mensaje text,
    cita_id uuid
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_paciente pacientes%rowtype;
  v_config configuracion%rowtype;
  v_duracion int;
  v_ocupado int;
  v_id uuid;
begin
  select * into v_paciente from pacientes where auth_user_id = auth.uid();
  if not found then
    return query select false, 'No encontramos tu perfil.', null::uuid;
    return;
  end if;

  if p_fecha_hora <= now() then
    return query select false, 'Elige una fecha y hora futuras.', null::uuid;
    return;
  end if;

  select * into v_config from configuracion where psicologo_id = v_paciente.psicologo_id;
  v_duracion := coalesce(v_config.duracion_sesion, 50);

  select count(*) into v_ocupado from citas
   where psicologo_id = v_paciente.psicologo_id
     and estado in ('pendiente_aprobacion','pendiente_confirmacion','pendiente_pago','confirmada')
     and fecha_hora < (p_fecha_hora + make_interval(mins => v_duracion))
     and (fecha_hora + make_interval(mins => duracion_minutos)) > p_fecha_hora;

  if v_ocupado > 0 then
    return query select false, 'Tu psicólogo ya tiene algo agendado en ese horario. Elige otro.', null::uuid;
    return;
  end if;

  insert into citas (psicologo_id, paciente_id, fecha_hora, duracion_minutos, precio, estado)
  values (v_paciente.psicologo_id, v_paciente.id, p_fecha_hora,
          v_duracion, coalesce(v_config.precio_sesion, 0), 'pendiente_aprobacion')
  returning id into v_id;

  return query select true, 'Solicitud enviada. Tu psicólogo la tiene que aprobar.', v_id;
end $function$;

GRANT ALL ON FUNCTION public.solicitar_cita_paciente(timestamp WITH time zone) TO anon;

GRANT ALL ON FUNCTION public.solicitar_cita_paciente(timestamp WITH time zone) TO authenticated;

GRANT ALL ON FUNCTION public.solicitar_cita_paciente(timestamp WITH time zone) TO service_role;

CREATE FUNCTION public.vincular_cuenta_paciente (
  p_paciente_id uuid
)
  RETURNS TABLE (
    ok      boolean,
    mensaje text
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare v_paciente pacientes%rowtype;
begin
  select * into v_paciente from pacientes where id = p_paciente_id;
  if not found then return query select false, 'Ese expediente no existe.'; return; end if;
  if v_paciente.auth_user_id is not null then
    return query select false, 'Ese paciente ya tiene una cuenta vinculada.'; return;
  end if;
  update pacientes set auth_user_id = auth.uid() where id = p_paciente_id;
  return query select true, 'Cuenta vinculada correctamente.';
end $function$;

GRANT ALL ON FUNCTION public.vincular_cuenta_paciente(uuid) TO anon;

GRANT ALL ON FUNCTION public.vincular_cuenta_paciente(uuid) TO authenticated;

GRANT ALL ON FUNCTION public.vincular_cuenta_paciente(uuid) TO service_role;

ALTER TABLE public.pacientes
  ALTER COLUMN correo DROP NOT NULL;

ALTER TABLE public.pacientes
  ALTER COLUMN id SET DEFAULT gen_random_uuid();

CREATE TABLE public.aceptaciones_terminos (
  id             uuid                     DEFAULT gen_random_uuid() NOT NULL,
  psicologo_id   uuid                     NOT NULL,
  texto_aceptado text                     NOT NULL,
  version        text                     NOT NULL,
  aceptado_en    timestamp with time zone DEFAULT now(),
  user_agent     text
);

ALTER TABLE public.aceptaciones_terminos
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.aceptaciones_terminos
  ADD CONSTRAINT aceptaciones_terminos_pkey PRIMARY KEY (id);

ALTER TABLE public.aceptaciones_terminos
  ADD CONSTRAINT aceptaciones_terminos_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

GRANT ALL ON public.aceptaciones_terminos TO anon;

GRANT ALL ON public.aceptaciones_terminos TO authenticated;

GRANT ALL ON public.aceptaciones_terminos TO service_role;

CREATE POLICY "psicologo registra su aceptacion" ON public.aceptaciones_terminos
  FOR INSERT
  WITH CHECK ((auth.uid() = psicologo_id));

CREATE POLICY "psicologo ve sus aceptaciones" ON public.aceptaciones_terminos
  FOR SELECT
  USING ((auth.uid() = psicologo_id));

ALTER TABLE public.citas
  ADD CONSTRAINT citas_estado_valido
    CHECK (estado = ANY (ARRAY['pendiente_aprobacion'::text, 'pendiente_confirmacion'::text, 'pendiente_pago'::text, 'confirmada'::text, 'completada'::text, 'cancelada'::text]));

CREATE TRIGGER trg_notificar_solicitud
  AFTER INSERT ON public.citas
  FOR EACH ROW
  EXECUTE FUNCTION public.notificar_solicitud_cita();

CREATE POLICY "paciente ve sus citas" ON public.citas
  FOR SELECT
  USING ((paciente_id = public.mi_paciente_id()));

CREATE POLICY "paciente actualiza sus citas" ON public.citas
  FOR UPDATE
  USING ((paciente_id = public.mi_paciente_id()));

ALTER TABLE public.configuracion
  ADD COLUMN logo_url text;

CREATE POLICY "paciente registra su consentimiento" ON public.consentimientos
  FOR INSERT
  WITH CHECK ((paciente_id = public.mi_paciente_id()));

ALTER TABLE public.documentos
  ADD COLUMN subido_por text;

CREATE POLICY "paciente lee sus documentos" ON public.documentos
  FOR SELECT
  USING ((paciente_id = public.mi_paciente_id()));

CREATE POLICY "paciente sube sus documentos" ON public.documentos
  FOR INSERT
  WITH CHECK ((paciente_id = public.mi_paciente_id()));

CREATE TABLE public.evaluaciones_psicologicas (
  id               uuid                     DEFAULT gen_random_uuid() NOT NULL,
  paciente_id      uuid                     NOT NULL,
  psicologo_id     uuid                     NOT NULL,
  nombre_prueba    text                     NOT NULL,
  fecha_aplicacion date,
  motivo           text,
  resultado        text,
  interpretacion   text,
  observaciones    text,
  aplicada_por     text,
  creado_en        timestamp with time zone DEFAULT now()
);

ALTER TABLE public.evaluaciones_psicologicas
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.evaluaciones_psicologicas
  ADD CONSTRAINT evaluaciones_psicologicas_paciente_id_fkey FOREIGN KEY (paciente_id) REFERENCES public.pacientes(id);

ALTER TABLE public.evaluaciones_psicologicas
  ADD CONSTRAINT evaluaciones_psicologicas_pkey PRIMARY KEY (id);

ALTER TABLE public.evaluaciones_psicologicas
  ADD CONSTRAINT evaluaciones_psicologicas_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

GRANT ALL ON public.evaluaciones_psicologicas TO anon;

GRANT ALL ON public.evaluaciones_psicologicas TO authenticated;

GRANT ALL ON public.evaluaciones_psicologicas TO service_role;

CREATE POLICY "psicologo administra evaluaciones" ON public.evaluaciones_psicologicas
  USING ((auth.uid() = psicologo_id))
  WITH CHECK ((auth.uid() = psicologo_id));

CREATE TABLE public.medicamentos (
  id               uuid                     DEFAULT gen_random_uuid() NOT NULL,
  paciente_id      uuid                     NOT NULL,
  psicologo_id     uuid                     NOT NULL,
  nombre           text                     NOT NULL,
  dosis            text,
  frecuencia       text,
  medico_prescribe text,
  fecha_inicio     date,
  fecha_fin        date,
  motivo           text,
  observaciones    text,
  creado_en        timestamp with time zone DEFAULT now()
);

ALTER TABLE public.medicamentos
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.medicamentos
  ADD CONSTRAINT medicamentos_paciente_id_fkey FOREIGN KEY (paciente_id) REFERENCES public.pacientes(id);

ALTER TABLE public.medicamentos
  ADD CONSTRAINT medicamentos_pkey PRIMARY KEY (id);

ALTER TABLE public.medicamentos
  ADD CONSTRAINT medicamentos_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

GRANT ALL ON public.medicamentos TO anon;

GRANT ALL ON public.medicamentos TO authenticated;

GRANT ALL ON public.medicamentos TO service_role;

CREATE POLICY "psicologo administra medicamentos" ON public.medicamentos
  USING ((auth.uid() = psicologo_id))
  WITH CHECK ((auth.uid() = psicologo_id));

ALTER TABLE public.notas_sesion
  ADD COLUMN numero_sesion integer;

ALTER TABLE public.notas_sesion
  ADD COLUMN modalidad text;

ALTER TABLE public.notas_sesion
  ADD COLUMN estado_paciente text;

ALTER TABLE public.notas_sesion
  ADD COLUMN intervenciones text;

ALTER TABLE public.notas_sesion
  ADD COLUMN respuesta_paciente text;

ALTER TABLE public.notas_sesion
  ADD COLUMN avances text;

ALTER TABLE public.notas_sesion
  ADD COLUMN dificultades text;

ALTER TABLE public.notas_sesion
  ADD COLUMN riesgos_relevantes text;

ALTER TABLE public.notas_sesion
  ADD COLUMN plan_siguiente_sesion text;

ALTER TABLE public.notas_sesion
  ADD COLUMN notas_privadas text;

CREATE TABLE public.notificaciones (
  id           uuid                     DEFAULT gen_random_uuid() NOT NULL,
  psicologo_id uuid                     NOT NULL,
  tipo         text                     DEFAULT 'solicitud_cita'::text NOT NULL,
  titulo       text                     NOT NULL,
  mensaje      text,
  leida        boolean                  DEFAULT false NOT NULL,
  cita_id      uuid,
  creado_en    timestamp with time zone DEFAULT now()
);

ALTER TABLE public.notificaciones
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.notificaciones
  ADD CONSTRAINT notificaciones_cita_id_fkey FOREIGN KEY (cita_id) REFERENCES public.citas(id);

ALTER TABLE public.notificaciones
  ADD CONSTRAINT notificaciones_pkey PRIMARY KEY (id);

ALTER TABLE public.notificaciones
  ADD CONSTRAINT notificaciones_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

GRANT ALL ON public.notificaciones TO anon;

GRANT ALL ON public.notificaciones TO authenticated;

GRANT ALL ON public.notificaciones TO service_role;

CREATE POLICY "psicologo marca sus notificaciones" ON public.notificaciones
  FOR UPDATE
  USING ((auth.uid() = psicologo_id));

CREATE POLICY "psicologo ve sus notificaciones" ON public.notificaciones
  FOR SELECT
  USING ((auth.uid() = psicologo_id));

CREATE TABLE public.objetivos_terapeuticos (
  id                uuid                     DEFAULT gen_random_uuid() NOT NULL,
  paciente_id       uuid                     NOT NULL,
  psicologo_id      uuid                     NOT NULL,
  objetivo          text                     NOT NULL,
  descripcion       text,
  prioridad         text                     DEFAULT 'media'::text,
  fecha_objetivo    date,
  estado            text                     DEFAULT 'pendiente'::text NOT NULL,
  notas_seguimiento text,
  creado_en         timestamp with time zone DEFAULT now()
);

ALTER TABLE public.objetivos_terapeuticos
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.objetivos_terapeuticos
  ADD CONSTRAINT objetivos_estado_valido CHECK (estado = ANY (ARRAY['pendiente'::text, 'en_progreso'::text, 'logrado'::text, 'pausado'::text]));

ALTER TABLE public.objetivos_terapeuticos
  ADD CONSTRAINT objetivos_prioridad_valida CHECK (prioridad = ANY (ARRAY['baja'::text, 'media'::text, 'alta'::text]));

ALTER TABLE public.objetivos_terapeuticos
  ADD CONSTRAINT objetivos_terapeuticos_paciente_id_fkey FOREIGN KEY (paciente_id) REFERENCES public.pacientes(id);

ALTER TABLE public.objetivos_terapeuticos
  ADD CONSTRAINT objetivos_terapeuticos_pkey PRIMARY KEY (id);

ALTER TABLE public.objetivos_terapeuticos
  ADD CONSTRAINT objetivos_terapeuticos_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

GRANT ALL ON public.objetivos_terapeuticos TO anon;

GRANT ALL ON public.objetivos_terapeuticos TO authenticated;

GRANT ALL ON public.objetivos_terapeuticos TO service_role;

CREATE POLICY "psicologo administra objetivos" ON public.objetivos_terapeuticos
  USING ((auth.uid() = psicologo_id))
  WITH CHECK ((auth.uid() = psicologo_id));

ALTER TABLE public.pacientes
  ADD COLUMN genero text;

ALTER TABLE public.pacientes
  ADD COLUMN pronombres text;

ALTER TABLE public.pacientes
  ADD COLUMN direccion text;

ALTER TABLE public.pacientes
  ADD COLUMN ciudad text;

ALTER TABLE public.pacientes
  ADD COLUMN estado_geografico text;

ALTER TABLE public.pacientes
  ADD COLUMN pais text;

ALTER TABLE public.pacientes
  ADD COLUMN ocupacion text;

ALTER TABLE public.pacientes
  ADD COLUMN estado_civil text;

ALTER TABLE public.pacientes
  ADD COLUMN escolaridad text;

ALTER TABLE public.pacientes
  ADD COLUMN contacto_emergencia_relacion text;

ALTER TABLE public.pacientes
  ADD COLUMN tipo_atencion text;

ALTER TABLE public.pacientes
  ADD COLUMN modalidad_atencion text;

ALTER TABLE public.pacientes
  ADD COLUMN frecuencia_sesiones text;

ALTER TABLE public.pacientes
  ADD COLUMN fecha_primera_sesion date;

ALTER TABLE public.pacientes
  ADD COLUMN fecha_ultima_sesion date;

ALTER TABLE public.pacientes
  ADD COLUMN problema_actual text;

ALTER TABLE public.pacientes
  ADD COLUMN sintomas_reportados text;

ALTER TABLE public.pacientes
  ADD COLUMN expectativas_paciente text;

ALTER TABLE public.pacientes
  ADD COLUMN objetivos_iniciales text;

ALTER TABLE public.pacientes
  ADD COLUMN quien_refiere text;

ALTER TABLE public.pacientes
  ADD COLUMN tiempo_evolucion text;

ALTER TABLE public.pacientes
  ADD COLUMN factores_desencadenantes text;

ALTER TABLE public.pacientes
  ADD COLUMN antecedentes_medicos text;

ALTER TABLE public.pacientes
  ADD COLUMN antecedentes_psicologicos text;

ALTER TABLE public.pacientes
  ADD COLUMN antecedentes_psiquiatricos text;

ALTER TABLE public.pacientes
  ADD COLUMN tratamientos_anteriores text;

ALTER TABLE public.pacientes
  ADD COLUMN hospitalizaciones text;

ALTER TABLE public.pacientes
  ADD COLUMN consumo_sustancias text;

ALTER TABLE public.pacientes
  ADD COLUMN alergias text;

ALTER TABLE public.pacientes
  ADD COLUMN enfermedades_relevantes text;

ALTER TABLE public.pacientes
  ADD COLUMN antecedentes_familiares text;

ALTER TABLE public.pacientes
  ADD COLUMN historia_prenatal text;

ALTER TABLE public.pacientes
  ADD COLUMN historia_infancia text;

ALTER TABLE public.pacientes
  ADD COLUMN historia_adolescencia text;

ALTER TABLE public.pacientes
  ADD COLUMN historia_desarrollo text;

ALTER TABLE public.pacientes
  ADD COLUMN relaciones_familiares text;

ALTER TABLE public.pacientes
  ADD COLUMN dinamica_familiar text;

ALTER TABLE public.pacientes
  ADD COLUMN historia_escolar text;

ALTER TABLE public.pacientes
  ADD COLUMN historia_laboral text;

ALTER TABLE public.pacientes
  ADD COLUMN relaciones_pareja text;

ALTER TABLE public.pacientes
  ADD COLUMN vida_social text;

ALTER TABLE public.pacientes
  ADD COLUMN eventos_significativos text;

ALTER TABLE public.pacientes
  ADD COLUMN recursos_personales text;

ALTER TABLE public.pacientes
  ADD COLUMN red_apoyo text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_apariencia_conducta text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_estado_animo text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_afecto text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_lenguaje text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_pensamiento text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_percepcion text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_orientacion text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_atencion text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_memoria text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_insight text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_juicio text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_funcionamiento_general text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_factores_riesgo text;

ALTER TABLE public.pacientes
  ADD COLUMN eval_factores_protectores text;

ALTER TABLE public.pacientes
  ADD COLUMN impresion_clinica text;

ALTER TABLE public.pacientes
  ADD COLUMN hipotesis_trabajo text;

ALTER TABLE public.pacientes
  ADD COLUMN diagnostico text;

ALTER TABLE public.pacientes
  ADD COLUMN codigo_diagnostico text;

ALTER TABLE public.pacientes
  ADD COLUMN diagnosticos_diferenciales text;

ALTER TABLE public.pacientes
  ADD COLUMN diagnostico_fecha date;

ALTER TABLE public.pacientes
  ADD COLUMN plan_enfoque text;

ALTER TABLE public.pacientes
  ADD COLUMN plan_intervenciones text;

ALTER TABLE public.pacientes
  ADD COLUMN plan_frecuencia text;

ALTER TABLE public.pacientes
  ADD COLUMN plan_duracion_estimada text;

ALTER TABLE public.pacientes
  ADD COLUMN plan_indicadores text;

ALTER TABLE public.pacientes
  ADD COLUMN plan_recomendaciones text;

ALTER TABLE public.pacientes
  ADD COLUMN riesgo_actual text;

ALTER TABLE public.pacientes
  ADD COLUMN riesgo_ideacion_suicida text;

ALTER TABLE public.pacientes
  ADD COLUMN riesgo_autolesiones text;

ALTER TABLE public.pacientes
  ADD COLUMN riesgo_terceros text;

ALTER TABLE public.pacientes
  ADD COLUMN riesgo_factores_riesgo text;

ALTER TABLE public.pacientes
  ADD COLUMN riesgo_factores_protectores text;

ALTER TABLE public.pacientes
  ADD COLUMN riesgo_plan_intervencion text;

ALTER TABLE public.pacientes
  ADD COLUMN riesgo_nivel text;

ALTER TABLE public.pacientes
  ADD COLUMN riesgo_fecha_evaluacion date;

ALTER TABLE public.pacientes
  ADD COLUMN seguimiento_evolucion_general text;

ALTER TABLE public.pacientes
  ADD COLUMN seguimiento_objetivos_alcanzados text;

ALTER TABLE public.pacientes
  ADD COLUMN seguimiento_objetivos_pendientes text;

ALTER TABLE public.pacientes
  ADD COLUMN motivo_alta text;

ALTER TABLE public.pacientes
  ADD COLUMN fecha_alta date;

ALTER TABLE public.pacientes
  ADD COLUMN estado_alta text;

ALTER TABLE public.pacientes
  ADD COLUMN recomendaciones_alta text;

ALTER TABLE public.pacientes
  ADD COLUMN seguimiento_posterior text;

ALTER TABLE public.pacientes
  ADD COLUMN folio text;

ALTER TABLE public.pacientes
  ADD COLUMN auth_user_id uuid;

ALTER TABLE public.pacientes
  ADD CONSTRAINT pacientes_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id);

ALTER TABLE public.pacientes
  ADD CONSTRAINT pacientes_auth_user_id_key UNIQUE (auth_user_id);

ALTER TABLE public.pacientes
  ADD COLUMN es_menor_edad boolean DEFAULT false;

ALTER TABLE public.pacientes
  ADD COLUMN tutor_nombre text;

ALTER TABLE public.pacientes
  ADD COLUMN tutor_relacion text;

ALTER TABLE public.pacientes
  ADD COLUMN tutor_telefono text;

ALTER TABLE public.pacientes
  ADD COLUMN tutor_correo text;

CREATE POLICY "paciente ve su propio registro" ON public.pacientes
  FOR SELECT
  USING ((auth.uid() = auth_user_id));

ALTER TABLE public.psicologos
  ADD COLUMN terminos_aceptados_en timestamp with time zone;

ALTER TABLE public.psicologos
  ADD COLUMN terminos_version_aceptada text;

CREATE TABLE public.reportes_pacientes (
  id           uuid                     DEFAULT gen_random_uuid() NOT NULL,
  paciente_id  uuid                     NOT NULL,
  psicologo_id uuid                     NOT NULL,
  descripcion  text                     NOT NULL,
  estado       text                     DEFAULT 'nuevo'::text NOT NULL,
  creado_en    timestamp with time zone DEFAULT now()
);

ALTER TABLE public.reportes_pacientes
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.reportes_pacientes
  ADD CONSTRAINT reportes_pacientes_paciente_id_fkey FOREIGN KEY (paciente_id) REFERENCES public.pacientes(id);

ALTER TABLE public.reportes_pacientes
  ADD CONSTRAINT reportes_pacientes_pkey PRIMARY KEY (id);

ALTER TABLE public.reportes_pacientes
  ADD CONSTRAINT reportes_pacientes_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

GRANT ALL ON public.reportes_pacientes TO anon;

GRANT ALL ON public.reportes_pacientes TO authenticated;

GRANT ALL ON public.reportes_pacientes TO service_role;

CREATE POLICY "admin actualiza reportes" ON public.reportes_pacientes
  FOR UPDATE
  USING (((auth.jwt() ->> 'email'::text) = 'abycmexico@gmail.com'::text));

CREATE POLICY "admin ve todos los reportes" ON public.reportes_pacientes
  FOR SELECT
  USING (((auth.jwt() ->> 'email'::text) = 'abycmexico@gmail.com'::text));

CREATE POLICY "paciente crea sus reportes" ON public.reportes_pacientes
  FOR INSERT
  WITH CHECK ((paciente_id = public.mi_paciente_id()));

CREATE VIEW public.psicologos_publicos WITH (security_invoker=off) AS SELECT id,
    nombre,
    foto_url,
    especialidad,
    ciudad,
    bio,
    cedula_profesional,
    telefono,
    correo
   FROM public.psicologos
  WHERE (estado = 'aprobado'::text);

GRANT ALL ON public.psicologos_publicos TO anon;

GRANT ALL ON public.psicologos_publicos TO authenticated;

GRANT ALL ON public.psicologos_publicos TO service_role;

ALTER POLICY "pacientes se registran a si mismos" ON public.pacientes WITH CHECK ((auth.uid() = auth_user_id));
