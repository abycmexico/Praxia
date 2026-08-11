-- Migration unit 1: schema_changes
-- Transaction mode: transactional
-- Boundary reason: default

SET check_function_bodies = false;

DROP EXTENSION pg_net;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT DELETE, INSERT, SELECT, UPDATE ON TABLES TO anon;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT, USAGE ON SEQUENCES TO anon;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON ROUTINES TO anon;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT DELETE, INSERT, SELECT, UPDATE ON TABLES TO authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT, USAGE ON SEQUENCES TO authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON ROUTINES TO authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT DELETE, INSERT, SELECT, UPDATE ON TABLES TO service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT, USAGE ON SEQUENCES TO service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON ROUTINES TO service_role;

CREATE FUNCTION public.aceptar_cita_por_token (
  p_token uuid
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
  select * into v_cita from citas where confirmacion_token = p_token;

  if not found then
    return query select false, 'Esta liga no es válida.'; return;
  end if;

  if v_cita.estado <> 'pendiente_confirmacion' then
    return query select false, 'Esta cita ya fue procesada anteriormente.'; return;
  end if;

  if v_cita.fecha_hora <= now() then
    return query select false, 'Esta cita ya no se puede confirmar, la fecha ya pasó.'; return;
  end if;

  update citas
     set estado = 'pendiente_pago',
         requiere_confirmacion_paciente = false,
         confirmada_por_paciente_en = now()
   where confirmacion_token = p_token;

  return query select true, 'Cita confirmada.';
end $function$;

GRANT ALL ON FUNCTION public.aceptar_cita_por_token(uuid) TO anon;

GRANT ALL ON FUNCTION public.aceptar_cita_por_token(uuid) TO authenticated;

GRANT ALL ON FUNCTION public.aceptar_cita_por_token(uuid) TO service_role;

CREATE FUNCTION public.actualizar_mis_datos (
  p_nombre              text,
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
  v_existe int;
begin
  select count(*) into v_existe from pacientes where id = auth.uid();
  if v_existe = 0 then return query select false, 'No encontramos tu perfil.'; return; end if;
  if p_nombre is null or length(trim(p_nombre)) < 2 then
    return query select false, 'El nombre no puede quedar vacío.'; return;
  end if;
  if p_fecha_nacimiento is not null and p_fecha_nacimiento > current_date then
    return query select false, 'La fecha de nacimiento no puede ser futura.'; return;
  end if;

  update pacientes
     set nombre = trim(p_nombre),
         telefono = nullif(trim(coalesce(p_telefono,'')), ''),
         fecha_nacimiento = p_fecha_nacimiento,
         contacto_emergencia_nombre = nullif(trim(coalesce(p_emergencia_nombre,'')), ''),
         contacto_emergencia_telefono = nullif(trim(coalesce(p_emergencia_telefono,'')), ''),
         foto_url = coalesce(p_foto_url, foto_url)
   where id = auth.uid();

  return query select true, 'Datos actualizados.';
end $function$;

GRANT ALL ON FUNCTION public.actualizar_mis_datos(text, text, date, text, text, text) TO anon;

GRANT ALL ON FUNCTION public.actualizar_mis_datos(text, text, date, text, text, text) TO authenticated;

GRANT ALL ON FUNCTION public.actualizar_mis_datos(text, text, date, text, text, text) TO service_role;

CREATE FUNCTION public.cancelar_cita (
  p_cita_id uuid,
  p_motivo  text DEFAULT NULL::text
)
  RETURNS TABLE (
    ok             boolean,
    mensaje        text,
    fuera_politica boolean
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_cita citas%rowtype;
  v_horas_minimas int;
  v_horas_faltantes numeric;
  v_quien text;
  v_fuera boolean;
begin
  select * into v_cita from citas where id = p_cita_id;
  if not found then
    return query select false, 'La cita no existe.', false; return;
  end if;

  if auth.uid() = v_cita.paciente_id then v_quien := 'paciente';
  elsif auth.uid() = v_cita.psicologo_id then v_quien := 'psicologo';
  else
    return query select false, 'No tienes permiso para cancelar esta cita.', false; return;
  end if;

  if v_cita.estado = 'cancelada' then
    return query select false, 'Esa cita ya estaba cancelada.', false; return;
  end if;

  if v_cita.fecha_hora < now() then
    return query select false, 'No se puede cancelar una sesión que ya ocurrió.', false; return;
  end if;

  select coalesce(horas_minimas_cancelar, 24) into v_horas_minimas
    from configuracion where psicologo_id = v_cita.psicologo_id;
  v_horas_minimas := coalesce(v_horas_minimas, 24);

  v_horas_faltantes := extract(epoch from (v_cita.fecha_hora - now())) / 3600;
  v_fuera := (v_quien = 'paciente' and v_horas_faltantes < v_horas_minimas);

  update citas
     set estado = 'cancelada', cancelada_en = now(), cancelada_por = v_quien,
         motivo_cancelacion = p_motivo, fuera_de_politica = v_fuera
   where id = p_cita_id;

  return query select true,
    case when v_fuera then
      'Cita cancelada. Quedó fuera de la política de cancelación (menos de ' || v_horas_minimas || ' horas de anticipación).'
    else 'Cita cancelada.' end,
    v_fuera;
end $function$;

GRANT ALL ON FUNCTION public.cancelar_cita(uuid, text) TO anon;

GRANT ALL ON FUNCTION public.cancelar_cita(uuid, text) TO authenticated;

GRANT ALL ON FUNCTION public.cancelar_cita(uuid, text) TO service_role;

CREATE FUNCTION public.crear_cita_para_paciente (
  p_paciente_id      uuid,
  p_fecha_hora       timestamp with time zone,
  p_duracion_minutos integer                  DEFAULT NULL::integer,
  p_precio           numeric                  DEFAULT NULL::numeric
)
  RETURNS TABLE (
    ok      boolean,
    mensaje text,
    token   uuid,
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
  v_token uuid;
  v_id uuid;
begin
  select * into v_paciente from pacientes where id = p_paciente_id;

  if not found or v_paciente.psicologo_id <> auth.uid() then
    return query select false, 'Ese paciente no te pertenece.', null::uuid, null::uuid;
    return;
  end if;

  if p_fecha_hora <= now() then
    return query select false, 'La fecha debe ser futura.', null::uuid, null::uuid;
    return;
  end if;

  select * into v_config from configuracion where psicologo_id = auth.uid();
  v_duracion := coalesce(p_duracion_minutos, v_config.duracion_sesion, 50);

  if v_duracion < 5 or v_duracion > 480 then
    return query select false, 'La duración debe estar entre 5 minutos y 8 horas.', null::uuid, null::uuid;
    return;
  end if;

  select count(*) into v_ocupado from citas
   where psicologo_id = auth.uid()
     and estado in ('pendiente_confirmacion','pendiente_pago','confirmada')
     and fecha_hora < (p_fecha_hora + make_interval(mins => v_duracion))
     and (fecha_hora + make_interval(mins => duracion_minutos)) > p_fecha_hora;

  if v_ocupado > 0 then
    return query select false, 'Ese horario se empalma con otra cita que ya tienes.', null::uuid, null::uuid;
    return;
  end if;

  v_token := gen_random_uuid();

  insert into citas (
    psicologo_id, paciente_id, fecha_hora, duracion_minutos, precio,
    estado, requiere_confirmacion_paciente, confirmacion_token
  ) values (
    auth.uid(), p_paciente_id, p_fecha_hora, v_duracion,
    coalesce(p_precio, v_config.precio_sesion, 0),
    'pendiente_confirmacion', true, v_token
  ) returning id into v_id;

  return query select true, 'Cita creada, pendiente de confirmación.', v_token, v_id;
end $function$;

GRANT ALL ON FUNCTION public.crear_cita_para_paciente(uuid, timestamp WITH time zone, integer, numeric) TO anon;

GRANT ALL ON FUNCTION public.crear_cita_para_paciente(uuid, timestamp WITH time zone, integer, numeric) TO authenticated;

GRANT ALL ON FUNCTION public.crear_cita_para_paciente(uuid, timestamp WITH time zone, integer, numeric) TO service_role;

CREATE FUNCTION public.crear_config_por_defecto()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
begin
  insert into configuracion (psicologo_id) values (new.id)
  on conflict (psicologo_id) do nothing;
  return new;
end $function$;

GRANT ALL ON FUNCTION public.crear_config_por_defecto() TO anon;

GRANT ALL ON FUNCTION public.crear_config_por_defecto() TO authenticated;

GRANT ALL ON FUNCTION public.crear_config_por_defecto() TO service_role;

CREATE FUNCTION public.crear_estado_oauth_google()
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

GRANT ALL ON FUNCTION public.crear_estado_oauth_google() TO anon;

GRANT ALL ON FUNCTION public.crear_estado_oauth_google() TO authenticated;

GRANT ALL ON FUNCTION public.crear_estado_oauth_google() TO service_role;

CREATE FUNCTION public.desconectar_google_calendar()
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
  delete from google_calendar_tokens where psicologo_id = auth.uid();
$function$;

GRANT ALL ON FUNCTION public.desconectar_google_calendar() TO anon;

GRANT ALL ON FUNCTION public.desconectar_google_calendar() TO authenticated;

GRANT ALL ON FUNCTION public.desconectar_google_calendar() TO service_role;

CREATE FUNCTION public.esta_conectado_google_calendar()
  RETURNS boolean
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
  select exists(select 1 from google_calendar_tokens where psicologo_id = auth.uid());
$function$;

GRANT ALL ON FUNCTION public.esta_conectado_google_calendar() TO anon;

GRANT ALL ON FUNCTION public.esta_conectado_google_calendar() TO authenticated;

GRANT ALL ON FUNCTION public.esta_conectado_google_calendar() TO service_role;

CREATE FUNCTION public.obtener_cita_por_token (
  p_token uuid
)
  RETURNS TABLE (
    ok               boolean,
    mensaje          text,
    fecha_hora       timestamp with time zone,
    duracion_minutos integer,
    precio           numeric,
    nombre_paciente  text,
    nombre_psicologo text,
    estado           text
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_cita citas%rowtype;
begin
  select * into v_cita from citas where confirmacion_token = p_token;

  if not found then
    return query select false, 'Esta liga no es válida.', null::timestamptz, null::int, null::numeric, null::text, null::text, null::text;
    return;
  end if;

  return query
    select true, 'ok',
      v_cita.fecha_hora, v_cita.duracion_minutos, v_cita.precio,
      p.nombre, ps.nombre, v_cita.estado
    from pacientes p, psicologos ps
    where p.id = v_cita.paciente_id and ps.id = v_cita.psicologo_id;
end $function$;

GRANT ALL ON FUNCTION public.obtener_cita_por_token(uuid) TO anon;

GRANT ALL ON FUNCTION public.obtener_cita_por_token(uuid) TO authenticated;

GRANT ALL ON FUNCTION public.obtener_cita_por_token(uuid) TO service_role;

CREATE FUNCTION public.rechazar_cita_por_token (
  p_token uuid
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
  select * into v_cita from citas where confirmacion_token = p_token;

  if not found then
    return query select false, 'Esta liga no es válida.'; return;
  end if;

  if v_cita.estado <> 'pendiente_confirmacion' then
    return query select false, 'Esta cita ya fue procesada anteriormente.'; return;
  end if;

  update citas
     set estado = 'cancelada',
         cancelada_en = now(),
         cancelada_por = 'paciente',
         motivo_cancelacion = 'No confirmó la cita propuesta por el psicólogo',
         requiere_confirmacion_paciente = false
   where confirmacion_token = p_token;

  return query select true, 'Cita rechazada.';
end $function$;

GRANT ALL ON FUNCTION public.rechazar_cita_por_token(uuid) TO anon;

GRANT ALL ON FUNCTION public.rechazar_cita_por_token(uuid) TO authenticated;

GRANT ALL ON FUNCTION public.rechazar_cita_por_token(uuid) TO service_role;

CREATE FUNCTION public.reprogramar_cita (
  p_cita_id     uuid,
  p_nueva_fecha timestamp with time zone
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
  v_config configuracion%rowtype;
  v_ocupado int;
  v_horas_faltantes numeric;
begin
  select * into v_cita from citas where id = p_cita_id;
  if not found then return query select false, 'La cita no existe.'; return; end if;

  if auth.uid() <> v_cita.paciente_id and auth.uid() <> v_cita.psicologo_id then
    return query select false, 'No tienes permiso para reprogramar esta cita.'; return;
  end if;

  if v_cita.estado = 'cancelada' then
    return query select false, 'No se puede reprogramar una cita cancelada.'; return;
  end if;

  if v_cita.fecha_hora < now() then
    return query select false, 'No se puede reprogramar una sesión que ya ocurrió.'; return;
  end if;

  if p_nueva_fecha <= now() then
    return query select false, 'La nueva fecha debe ser futura.'; return;
  end if;

  select * into v_config from configuracion where psicologo_id = v_cita.psicologo_id;

  if auth.uid() = v_cita.paciente_id then
    v_horas_faltantes := extract(epoch from (p_nueva_fecha - now())) / 3600;
    if v_horas_faltantes < coalesce(v_config.anticipacion_minima_horas, 0) then
      return query select false, 'Ese horario está dentro de la anticipación mínima de ' || coalesce(v_config.anticipacion_minima_horas, 0) || ' horas.';
      return;
    end if;
  end if;

  select count(*) into v_ocupado from citas
   where psicologo_id = v_cita.psicologo_id and fecha_hora = p_nueva_fecha
     and estado in ('pendiente_pago','confirmada') and id <> p_cita_id;

  if v_ocupado > 0 then
    return query select false, 'Ese horario ya está ocupado.'; return;
  end if;

  update citas
     set reprogramada_desde = coalesce(reprogramada_desde, fecha_hora), fecha_hora = p_nueva_fecha
   where id = p_cita_id;

  return query select true, 'Cita reprogramada.';
end $function$;

GRANT ALL ON FUNCTION public.reprogramar_cita(uuid, timestamp WITH time zone) TO anon;

GRANT ALL ON FUNCTION public.reprogramar_cita(uuid, timestamp WITH time zone) TO authenticated;

GRANT ALL ON FUNCTION public.reprogramar_cita(uuid, timestamp WITH time zone) TO service_role;

CREATE TABLE public.auditoria (
  id             uuid                     DEFAULT gen_random_uuid() NOT NULL,
  admin_email    text                     NOT NULL,
  accion         text                     NOT NULL,
  entidad        text,
  entidad_id     uuid,
  valor_anterior jsonb,
  valor_nuevo    jsonb,
  creado_en      timestamp with time zone DEFAULT now()
);

ALTER TABLE public.auditoria
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.auditoria
  ADD CONSTRAINT auditoria_pkey PRIMARY KEY (id);

GRANT ALL ON public.auditoria TO anon;

GRANT ALL ON public.auditoria TO authenticated;

GRANT ALL ON public.auditoria TO service_role;

CREATE INDEX auditoria_por_fecha ON public.auditoria (creado_en DESC);

CREATE POLICY "admin escribe auditoria" ON public.auditoria
  FOR INSERT
  WITH CHECK (((auth.jwt() ->> 'email'::text) = 'abycmexico@gmail.com'::text));

CREATE POLICY "admin lee auditoria" ON public.auditoria
  FOR SELECT
  USING (((auth.jwt() ->> 'email'::text) = 'abycmexico@gmail.com'::text));

CREATE TABLE public.citas (
  id                             uuid                     DEFAULT gen_random_uuid() NOT NULL,
  psicologo_id                   uuid                     NOT NULL,
  paciente_id                    uuid                     NOT NULL,
  fecha_hora                     timestamp with time zone NOT NULL,
  duracion_minutos               integer                  DEFAULT 50,
  estado                         text                     DEFAULT 'pendiente_pago'::text NOT NULL,
  stripe_payment_id              text,
  videollamada_url               text,
  creado_en                      timestamp with time zone DEFAULT now(),
  precio                         numeric(10,2),
  cancelada_en                   timestamp with time zone,
  cancelada_por                  text,
  motivo_cancelacion             text,
  fuera_de_politica              boolean                  DEFAULT false,
  reprogramada_desde             timestamp with time zone,
  confirmacion_token             uuid                     DEFAULT gen_random_uuid(),
  requiere_confirmacion_paciente boolean                  DEFAULT false,
  confirmada_por_paciente_en     timestamp with time zone
);

ALTER TABLE public.citas
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.citas
  ADD CONSTRAINT citas_cancelada_por_valido CHECK (cancelada_por IS NULL OR (cancelada_por = ANY (ARRAY['paciente'::text, 'psicologo'::text])));

ALTER TABLE public.citas
  ADD CONSTRAINT citas_estado_valido CHECK (estado = ANY (ARRAY['pendiente_confirmacion'::text, 'pendiente_pago'::text, 'confirmada'::text, 'completada'::text, 'cancelada'::text]));

ALTER TABLE public.citas
  ADD CONSTRAINT citas_pkey PRIMARY KEY (id);

GRANT ALL ON public.citas TO anon;

GRANT ALL ON public.citas TO authenticated;

GRANT ALL ON public.citas TO service_role;

CREATE UNIQUE INDEX citas_sin_empalme ON public.citas (psicologo_id, fecha_hora)
  WHERE estado = ANY (ARRAY['pendiente_pago'::text, 'confirmada'::text]);

CREATE POLICY "admin ve todas las citas" ON public.citas
  FOR SELECT
  USING (((auth.jwt() ->> 'email'::text) = 'abycmexico@gmail.com'::text));

CREATE POLICY "paciente actualiza sus citas" ON public.citas
  FOR UPDATE
  USING ((auth.uid() = paciente_id));

CREATE POLICY "paciente crea sus propias citas" ON public.citas
  FOR INSERT
  WITH CHECK ((auth.uid() = paciente_id));

CREATE POLICY "paciente ve sus propias citas" ON public.citas
  FOR SELECT
  USING ((auth.uid() = paciente_id));

CREATE POLICY "psicologo actualiza sus citas" ON public.citas
  FOR UPDATE
  USING ((auth.uid() = psicologo_id));

CREATE POLICY "psicologo ve sus citas" ON public.citas
  FOR SELECT
  USING ((auth.uid() = psicologo_id));

CREATE TABLE public.config_plataforma (
  id                    integer                  DEFAULT 1 NOT NULL,
  mantenimiento_activo  boolean                  DEFAULT false,
  mensaje_mantenimiento text                     DEFAULT 'Praxia está en mantenimiento. Volvemos pronto.'::text,
  actualizado_en        timestamp with time zone DEFAULT now()
);

ALTER TABLE public.config_plataforma
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.config_plataforma
  ADD CONSTRAINT config_plataforma_pkey PRIMARY KEY (id);

ALTER TABLE public.config_plataforma
  ADD CONSTRAINT una_sola_fila CHECK (id = 1);

GRANT ALL ON public.config_plataforma TO anon;

GRANT ALL ON public.config_plataforma TO authenticated;

GRANT ALL ON public.config_plataforma TO service_role;

CREATE POLICY "admin edita config plataforma" ON public.config_plataforma
  FOR UPDATE
  USING (((auth.jwt() ->> 'email'::text) = 'abycmexico@gmail.com'::text));

CREATE POLICY "todos leen config plataforma" ON public.config_plataforma
  FOR SELECT
  USING (true);

CREATE TABLE public.configuracion (
  psicologo_id              uuid                     NOT NULL,
  duracion_sesion           integer                  DEFAULT 50 NOT NULL,
  precio_sesion             numeric(10,2)            DEFAULT 0 NOT NULL,
  moneda                    text                     DEFAULT 'MXN'::text NOT NULL,
  tolerancia_minutos        integer                  DEFAULT 10 NOT NULL,
  anticipacion_minima_horas integer                  DEFAULT 12 NOT NULL,
  dias_max_anticipacion     integer                  DEFAULT 30 NOT NULL,
  descanso_entre_sesiones   integer                  DEFAULT 0 NOT NULL,
  horas_minimas_cancelar    integer                  DEFAULT 24 NOT NULL,
  politica_cancelacion      text,
  nombre_consultorio        text,
  politicas_generales       text,
  actualizado_en            timestamp with time zone DEFAULT now(),
  whatsapp_activo           boolean                  DEFAULT false,
  whatsapp_numero           text,
  codigo_etica              text
);

ALTER TABLE public.configuracion
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.configuracion
  ADD CONSTRAINT config_anticipacion_valida CHECK (anticipacion_minima_horas >= 0 AND anticipacion_minima_horas <= 168);

ALTER TABLE public.configuracion
  ADD CONSTRAINT config_descanso_valido CHECK (descanso_entre_sesiones >= 0 AND descanso_entre_sesiones <= 120);

ALTER TABLE public.configuracion
  ADD CONSTRAINT config_dias_max_validos CHECK (dias_max_anticipacion >= 1 AND dias_max_anticipacion <= 180);

ALTER TABLE public.configuracion
  ADD CONSTRAINT config_duracion_valida CHECK (duracion_sesion >= 15 AND duracion_sesion <= 240);

ALTER TABLE public.configuracion
  ADD CONSTRAINT config_precio_valido CHECK (precio_sesion >= 0::numeric);

ALTER TABLE public.configuracion
  ADD CONSTRAINT configuracion_pkey PRIMARY KEY (psicologo_id);

GRANT ALL ON public.configuracion TO anon;

GRANT ALL ON public.configuracion TO authenticated;

GRANT ALL ON public.configuracion TO service_role;

CREATE POLICY "psicologo crea su configuracion" ON public.configuracion
  FOR INSERT
  WITH CHECK ((auth.uid() = psicologo_id));

CREATE POLICY "psicologo edita su configuracion" ON public.configuracion
  FOR UPDATE
  USING ((auth.uid() = psicologo_id));

CREATE POLICY "psicologo ve su configuracion" ON public.configuracion
  FOR SELECT
  USING ((auth.uid() = psicologo_id));

CREATE TABLE public.consentimientos (
  id             uuid                     DEFAULT gen_random_uuid() NOT NULL,
  paciente_id    uuid                     NOT NULL,
  psicologo_id   uuid                     NOT NULL,
  texto_aceptado text                     NOT NULL,
  version        integer                  DEFAULT 1 NOT NULL,
  aceptado_en    timestamp with time zone DEFAULT now(),
  user_agent     text
);

ALTER TABLE public.consentimientos
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.consentimientos
  ADD CONSTRAINT consentimientos_pkey PRIMARY KEY (id);

GRANT ALL ON public.consentimientos TO anon;

GRANT ALL ON public.consentimientos TO authenticated;

GRANT ALL ON public.consentimientos TO service_role;

CREATE INDEX consentimientos_por_paciente ON public.consentimientos (paciente_id, aceptado_en DESC);

CREATE POLICY "paciente registra su consentimiento" ON public.consentimientos
  FOR INSERT
  WITH CHECK ((auth.uid() = paciente_id));

CREATE POLICY "paciente ve sus consentimientos" ON public.consentimientos
  FOR SELECT
  USING ((auth.uid() = paciente_id));

CREATE POLICY "psicologo ve consentimientos de sus pacientes" ON public.consentimientos
  FOR SELECT
  USING ((auth.uid() = psicologo_id));

CREATE TABLE public.disponibilidad (
  id           uuid                   DEFAULT gen_random_uuid() NOT NULL,
  psicologo_id uuid                   NOT NULL,
  dia_semana   integer                NOT NULL,
  hora_inicio  time without time zone NOT NULL,
  hora_fin     time without time zone NOT NULL,
  activo       boolean                DEFAULT true
);

ALTER TABLE public.disponibilidad
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.disponibilidad
  ADD CONSTRAINT disponibilidad_dia_semana_check CHECK (dia_semana >= 0 AND dia_semana <= 6);

ALTER TABLE public.disponibilidad
  ADD CONSTRAINT disponibilidad_pkey PRIMARY KEY (id);

GRANT ALL ON public.disponibilidad TO anon;

GRANT ALL ON public.disponibilidad TO authenticated;

GRANT ALL ON public.disponibilidad TO service_role;

CREATE POLICY "psicologo administra su disponibilidad" ON public.disponibilidad
  USING ((auth.uid() = psicologo_id));

CREATE TABLE public.documentos (
  id           uuid                     DEFAULT gen_random_uuid() NOT NULL,
  paciente_id  uuid                     NOT NULL,
  psicologo_id uuid                     NOT NULL,
  nombre       text                     NOT NULL,
  ruta         text                     NOT NULL,
  tipo         text,
  mime         text,
  tamano_bytes bigint,
  notas        text,
  subido_en    timestamp with time zone DEFAULT now()
);

ALTER TABLE public.documentos
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.documentos
  ADD CONSTRAINT documentos_pkey PRIMARY KEY (id);

ALTER TABLE public.documentos
  ADD CONSTRAINT documentos_ruta_key UNIQUE (ruta);

GRANT ALL ON public.documentos TO anon;

GRANT ALL ON public.documentos TO authenticated;

GRANT ALL ON public.documentos TO service_role;

CREATE INDEX documentos_por_paciente ON public.documentos (paciente_id, subido_en DESC);

CREATE POLICY "paciente sube sus documentos" ON public.documentos
  FOR INSERT
  WITH CHECK ((auth.uid() = paciente_id));

CREATE POLICY "paciente ve sus documentos" ON public.documentos
  FOR SELECT
  USING ((auth.uid() = paciente_id));

CREATE POLICY "psicologo administra documentos" ON public.documentos
  USING ((auth.uid() = psicologo_id))
  WITH CHECK ((auth.uid() = psicologo_id));

CREATE TABLE public.google_calendar_tokens (
  psicologo_id  uuid                     NOT NULL,
  refresh_token text                     NOT NULL,
  conectado_en  timestamp with time zone DEFAULT now()
);

ALTER TABLE public.google_calendar_tokens
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.google_calendar_tokens
  ADD CONSTRAINT google_calendar_tokens_pkey PRIMARY KEY (psicologo_id);

GRANT ALL ON public.google_calendar_tokens TO anon;

GRANT ALL ON public.google_calendar_tokens TO authenticated;

GRANT ALL ON public.google_calendar_tokens TO service_role;

CREATE TABLE public.google_oauth_estados (
  state        uuid                     DEFAULT gen_random_uuid() NOT NULL,
  psicologo_id uuid                     NOT NULL,
  creado_en    timestamp with time zone DEFAULT now()
);

ALTER TABLE public.google_oauth_estados
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.google_oauth_estados
  ADD CONSTRAINT google_oauth_estados_pkey PRIMARY KEY (state);

GRANT ALL ON public.google_oauth_estados TO anon;

GRANT ALL ON public.google_oauth_estados TO authenticated;

GRANT ALL ON public.google_oauth_estados TO service_role;

CREATE TABLE public.notas_sesion (
  id             uuid                     DEFAULT gen_random_uuid() NOT NULL,
  cita_id        uuid                     NOT NULL,
  psicologo_id   uuid                     NOT NULL,
  contenido      text,
  creado_en      timestamp with time zone DEFAULT now(),
  objetivos      text,
  observaciones  text,
  tareas         text,
  evolucion      text,
  actualizado_en timestamp with time zone DEFAULT now()
);

ALTER TABLE public.notas_sesion
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.notas_sesion
  ADD CONSTRAINT notas_sesion_cita_id_fkey FOREIGN KEY (cita_id) REFERENCES public.citas(id);

ALTER TABLE public.notas_sesion
  ADD CONSTRAINT notas_sesion_pkey PRIMARY KEY (id);

GRANT ALL ON public.notas_sesion TO anon;

GRANT ALL ON public.notas_sesion TO authenticated;

GRANT ALL ON public.notas_sesion TO service_role;

CREATE UNIQUE INDEX notas_una_por_cita ON public.notas_sesion (cita_id);

CREATE POLICY "solo el psicologo ve sus notas" ON public.notas_sesion
  USING ((auth.uid() = psicologo_id));

CREATE TABLE public.pacientes (
  id                           uuid                     NOT NULL,
  nombre                       text                     NOT NULL,
  correo                       text                     NOT NULL,
  psicologo_id                 uuid                     NOT NULL,
  creado_en                    timestamp with time zone DEFAULT now(),
  telefono                     text,
  fecha_nacimiento             date,
  motivo_consulta              text,
  fecha_inicio                 date                     DEFAULT CURRENT_DATE,
  estado                       text                     DEFAULT 'activo'::text NOT NULL,
  observaciones_generales      text,
  contacto_emergencia_nombre   text,
  contacto_emergencia_telefono text,
  foto_url                     text,
  orden                        integer                  DEFAULT 0
);

CREATE POLICY "paciente ve config de su psicologo" ON public.configuracion
  FOR SELECT
  USING ((EXISTS ( SELECT 1
   FROM public.pacientes
  WHERE ((pacientes.id = auth.uid()) AND (pacientes.psicologo_id = configuracion.psicologo_id)))));

CREATE POLICY "paciente ve disponibilidad de su psicologo" ON public.disponibilidad
  FOR SELECT
  USING ((EXISTS ( SELECT 1
   FROM public.pacientes
  WHERE ((pacientes.id = auth.uid()) AND (pacientes.psicologo_id = disponibilidad.psicologo_id)))));

ALTER TABLE public.pacientes
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.pacientes
  ADD CONSTRAINT pacientes_estado_valido CHECK (estado = ANY (ARRAY['activo'::text, 'pausa'::text, 'dado_de_alta'::text, 'archivado'::text]));

ALTER TABLE public.pacientes
  ADD CONSTRAINT pacientes_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id);

ALTER TABLE public.pacientes
  ADD CONSTRAINT pacientes_pkey PRIMARY KEY (id);

ALTER TABLE public.citas
  ADD CONSTRAINT citas_paciente_id_fkey FOREIGN KEY (paciente_id) REFERENCES public.pacientes(id);

ALTER TABLE public.consentimientos
  ADD CONSTRAINT consentimientos_paciente_id_fkey FOREIGN KEY (paciente_id) REFERENCES public.pacientes(id);

ALTER TABLE public.documentos
  ADD CONSTRAINT documentos_paciente_id_fkey FOREIGN KEY (paciente_id) REFERENCES public.pacientes(id);

GRANT ALL ON public.pacientes TO anon;

GRANT ALL ON public.pacientes TO authenticated;

GRANT ALL ON public.pacientes TO service_role;

CREATE INDEX pacientes_por_psicologo ON public.pacientes (psicologo_id, estado);

CREATE POLICY "admin ve todos los pacientes" ON public.pacientes
  FOR SELECT
  USING (((auth.jwt() ->> 'email'::text) = 'abycmexico@gmail.com'::text));

CREATE POLICY "pacientes se registran a si mismos" ON public.pacientes
  FOR INSERT
  WITH CHECK ((auth.uid() = id));

CREATE POLICY "pacientes ven su propio perfil" ON public.pacientes
  FOR SELECT
  USING ((auth.uid() = id));

CREATE POLICY "psicologo edita expediente de sus pacientes" ON public.pacientes
  FOR UPDATE
  USING ((auth.uid() = psicologo_id));

CREATE POLICY "psicologo ve a sus pacientes" ON public.pacientes
  FOR SELECT
  USING ((auth.uid() = psicologo_id));

CREATE TABLE public.psicologos (
  id                 uuid                     NOT NULL,
  nombre             text                     NOT NULL,
  correo             text                     NOT NULL,
  estado             text                     DEFAULT 'pendiente'::text NOT NULL,
  creado_en          timestamp with time zone DEFAULT now(),
  foto_url           text,
  especialidad       text,
  bio                text,
  edad               integer,
  telefono           text,
  cedula_profesional text,
  ciudad             text,
  direccion          text,
  tamano_consultorio text,
  perfil_completo    boolean                  DEFAULT false
);

ALTER TABLE public.psicologos
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.psicologos
  ADD CONSTRAINT psicologos_estado_check CHECK (estado = ANY (ARRAY['pendiente'::text, 'aprobado'::text, 'rechazado'::text]));

ALTER TABLE public.psicologos
  ADD CONSTRAINT psicologos_estado_valido CHECK (estado = ANY (ARRAY['pendiente'::text, 'aprobado'::text, 'rechazado'::text, 'suspendido'::text]));

ALTER TABLE public.psicologos
  ADD CONSTRAINT psicologos_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id);

ALTER TABLE public.psicologos
  ADD CONSTRAINT psicologos_pkey PRIMARY KEY (id);

ALTER TABLE public.citas
  ADD CONSTRAINT citas_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

ALTER TABLE public.configuracion
  ADD CONSTRAINT configuracion_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

ALTER TABLE public.consentimientos
  ADD CONSTRAINT consentimientos_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

ALTER TABLE public.disponibilidad
  ADD CONSTRAINT disponibilidad_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

ALTER TABLE public.documentos
  ADD CONSTRAINT documentos_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

ALTER TABLE public.google_calendar_tokens
  ADD CONSTRAINT google_calendar_tokens_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

ALTER TABLE public.google_oauth_estados
  ADD CONSTRAINT google_oauth_estados_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

ALTER TABLE public.notas_sesion
  ADD CONSTRAINT notas_sesion_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

ALTER TABLE public.pacientes
  ADD CONSTRAINT pacientes_psicologo_id_fkey FOREIGN KEY (psicologo_id) REFERENCES public.psicologos(id);

ALTER TABLE public.psicologos
  ADD CONSTRAINT psicologos_tamano_valido
    CHECK (tamano_consultorio IS NULL OR (tamano_consultorio = ANY (ARRAY['1-5'::text, '6-15'::text, '16-30'::text, '31-50'::text, '50+'::text])));

GRANT ALL ON public.psicologos TO anon;

GRANT ALL ON public.psicologos TO authenticated;

GRANT ALL ON public.psicologos TO service_role;

CREATE TRIGGER trg_config_por_defecto
  AFTER INSERT ON public.psicologos
  FOR EACH ROW
  EXECUTE FUNCTION public.crear_config_por_defecto();

CREATE POLICY "cualquiera autenticado puede registrarse como psicologo" ON public.psicologos
  FOR INSERT
  WITH CHECK ((auth.uid() = id));

CREATE POLICY "psicologos editan su propio perfil" ON public.psicologos
  FOR UPDATE
  USING ((auth.uid() = id));

CREATE POLICY "psicologos ven su propio perfil" ON public.psicologos
  FOR SELECT
  USING ((auth.uid() = id));

CREATE VIEW public.config_publica WITH (security_invoker=off) AS SELECT c.psicologo_id,
    c.nombre_consultorio,
    c.duracion_sesion,
    c.precio_sesion,
    c.moneda,
    c.politicas_generales,
    c.horas_minimas_cancelar,
    c.politica_cancelacion
   FROM (public.configuracion c
     JOIN public.psicologos p ON ((p.id = c.psicologo_id)))
  WHERE (p.estado = 'aprobado'::text);

GRANT ALL ON public.config_publica TO anon;

GRANT ALL ON public.config_publica TO authenticated;

GRANT ALL ON public.config_publica TO service_role;

CREATE VIEW public.ocupacion_psicologo WITH (security_invoker=off) AS SELECT psicologo_id,
    fecha_hora
   FROM public.citas
  WHERE ((estado = ANY (ARRAY['pendiente_pago'::text, 'confirmada'::text])) AND (fecha_hora >= now()));

GRANT ALL ON public.ocupacion_psicologo TO anon;

GRANT ALL ON public.ocupacion_psicologo TO authenticated;

GRANT ALL ON public.ocupacion_psicologo TO service_role;

CREATE VIEW public.psicologos_publicos WITH (security_invoker=off) AS SELECT id,
    nombre,
    foto_url,
    especialidad,
    ciudad,
    bio
   FROM public.psicologos
  WHERE (estado = 'aprobado'::text);

GRANT ALL ON public.psicologos_publicos TO anon;

GRANT ALL ON public.psicologos_publicos TO authenticated;

GRANT ALL ON public.psicologos_publicos TO service_role;
