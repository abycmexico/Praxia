-- NOTIFICACIONES PUSH
--
-- Cada dispositivo donde el psicologo instale la app guarda su propia
-- suscripcion: el mismo psicologo puede tener el telefono y la tablet, y
-- cada uno tiene su endpoint. Por eso la llave es el endpoint y no el
-- usuario.
--
-- Estas suscripciones no llevan nada del paciente. Aun asi, el texto que se
-- envie en un push aparece en la pantalla bloqueada del telefono, donde lo
-- puede leer cualquiera que lo tenga en la mano: por eso los avisos dicen
-- que paso, nunca datos clinicos ni el motivo de una consulta.

CREATE TABLE IF NOT EXISTS public.suscripciones_push (
  endpoint     text PRIMARY KEY,
  psicologo_id uuid NOT NULL REFERENCES public.psicologos(id) ON DELETE CASCADE,
  p256dh       text NOT NULL,
  auth         text NOT NULL,
  dispositivo  text,
  creado_en    timestamptz DEFAULT now(),
  ultimo_envio timestamptz,
  fallos       int NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS suscripciones_push_por_psicologo
  ON public.suscripciones_push (psicologo_id);

ALTER TABLE public.suscripciones_push ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cada quien administra sus dispositivos" ON public.suscripciones_push;
CREATE POLICY "cada quien administra sus dispositivos" ON public.suscripciones_push
  FOR ALL TO authenticated
  USING (psicologo_id = auth.uid())
  WITH CHECK (psicologo_id = auth.uid());

-- Registrar el dispositivo. Va por funcion para que reactivar en un
-- telefono donde ya estaba no cree una fila duplicada ni falle.
CREATE OR REPLACE FUNCTION public.registrar_dispositivo_push(
  p_endpoint    text,
  p_p256dh      text,
  p_auth        text,
  p_dispositivo text DEFAULT NULL
)
  RETURNS TABLE (ok boolean, mensaje text)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return query select false, 'Necesitas haber iniciado sesión.'; return;
  end if;
  if not exists(select 1 from psicologos where id = v_uid) then
    return query select false, 'Solo los psicólogos reciben avisos por ahora.'; return;
  end if;

  insert into suscripciones_push (endpoint, psicologo_id, p256dh, auth, dispositivo)
  values (p_endpoint, v_uid, p_p256dh, p_auth, p_dispositivo)
  on conflict (endpoint) do update
    set psicologo_id = excluded.psicologo_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        dispositivo = excluded.dispositivo,
        fallos = 0;

  return query select true, 'Este dispositivo ya recibe avisos.';
end $function$;

CREATE OR REPLACE FUNCTION public.quitar_dispositivo_push(p_endpoint text)
  RETURNS void
  LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  delete from suscripciones_push
   where endpoint = p_endpoint and psicologo_id = auth.uid();
$function$;

REVOKE ALL ON FUNCTION public.registrar_dispositivo_push(text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quitar_dispositivo_push(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_dispositivo_push(text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quitar_dispositivo_push(text) TO authenticated;

-- ---------------------------------------------------------------------
-- Cola de envio
-- ---------------------------------------------------------------------
-- Los triggers no pueden llamar a internet, asi que en vez de enviar dejan
-- el aviso encolado y una funcion aparte lo despacha. Ademas asi un fallo
-- de la red no revienta la operacion que lo origino: que un push no salga
-- no debe impedir que se agende una cita.

CREATE TABLE IF NOT EXISTS public.avisos_pendientes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  psicologo_id uuid NOT NULL REFERENCES public.psicologos(id) ON DELETE CASCADE,
  titulo       text NOT NULL,
  cuerpo       text,
  url          text,
  enviado_en   timestamptz,
  intentos     int NOT NULL DEFAULT 0,
  creado_en    timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS avisos_pendientes_sin_enviar
  ON public.avisos_pendientes (creado_en) WHERE enviado_en IS NULL;

ALTER TABLE public.avisos_pendientes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "veo mis avisos" ON public.avisos_pendientes;
CREATE POLICY "veo mis avisos" ON public.avisos_pendientes
  FOR SELECT TO authenticated
  USING (psicologo_id = auth.uid());

-- Encola un aviso. Se usa desde los triggers.
CREATE OR REPLACE FUNCTION public.encolar_aviso(
  p_psicologo_id uuid, p_titulo text, p_cuerpo text DEFAULT NULL, p_url text DEFAULT NULL
)
  RETURNS void
  LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  insert into avisos_pendientes (psicologo_id, titulo, cuerpo, url)
  values (p_psicologo_id, p_titulo, p_cuerpo, p_url);
$function$;

-- ---------------------------------------------------------------------
-- Que se avisa
-- ---------------------------------------------------------------------

-- Un paciente pide cita. Ya existia el aviso dentro de la app; ahora
-- ademas suena el telefono, que es lo que hace que se responda a tiempo.
CREATE OR REPLACE FUNCTION public.notificar_solicitud_cita()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare v_nombre text;
begin
  if NEW.estado = 'pendiente_aprobacion' then
    select nombre into v_nombre from pacientes where id = NEW.paciente_id;

    insert into notificaciones (psicologo_id, tipo, titulo, mensaje, cita_id)
    values (NEW.psicologo_id, 'solicitud_cita',
            coalesce(v_nombre,'Un paciente') || ' pidió una sesión',
            to_char(NEW.fecha_hora at time zone 'America/Mexico_City', 'DD/MM " a las " HH24:MI'),
            NEW.id);

    perform public.encolar_aviso(
      NEW.psicologo_id,
      coalesce(v_nombre,'Un paciente') || ' pidió una sesión',
      to_char(NEW.fecha_hora at time zone 'America/Mexico_City', 'DD/MM " a las " HH24:MI') || '. Entra para aprobarla o rechazarla.',
      './app.html'
    );
  end if;
  return NEW;
end $function$;

-- Un paciente paga. Enterarse sin tener que revisar evita el recordatorio
-- incomodo a alguien que ya pago.
CREATE OR REPLACE FUNCTION public.notificar_pago_recibido()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare v_nombre text;
begin
  if NEW.origen = 'en_linea' then
    select nombre into v_nombre from pacientes where id = NEW.paciente_id;

    insert into notificaciones (psicologo_id, tipo, titulo, mensaje)
    values (NEW.psicologo_id, 'pago_recibido',
            'Te pagó ' || coalesce(v_nombre,'un paciente'),
            '$' || to_char(NEW.monto,'FM999,999.00'));

    perform public.encolar_aviso(
      NEW.psicologo_id,
      'Te pagó ' || coalesce(v_nombre,'un paciente'),
      '$' || to_char(NEW.monto,'FM999,999.00') || ' ya está en tu cuenta.',
      './app.html'
    );
  end if;
  return NEW;
end $function$;

DROP TRIGGER IF EXISTS trg_notificar_pago ON public.pagos;
CREATE TRIGGER trg_notificar_pago
  AFTER INSERT ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.notificar_pago_recibido();

-- Un paciente cancela. Es lo que libera o descuadra la agenda del dia.
CREATE OR REPLACE FUNCTION public.notificar_cancelacion()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare v_nombre text;
begin
  -- Solo cuando cancela el paciente: avisarle al psicologo de una
  -- cancelacion que hizo el mismo seria ruido.
  if NEW.estado = 'cancelada' and coalesce(OLD.estado,'') <> 'cancelada'
     and NEW.cancelada_por = 'paciente' then
    select nombre into v_nombre from pacientes where id = NEW.paciente_id;

    insert into notificaciones (psicologo_id, tipo, titulo, mensaje, cita_id)
    values (NEW.psicologo_id, 'cita_cancelada',
            coalesce(v_nombre,'Un paciente') || ' canceló su sesión',
            to_char(NEW.fecha_hora at time zone 'America/Mexico_City', 'DD/MM " a las " HH24:MI'),
            NEW.id);

    perform public.encolar_aviso(
      NEW.psicologo_id,
      coalesce(v_nombre,'Un paciente') || ' canceló su sesión',
      'Era el ' || to_char(NEW.fecha_hora at time zone 'America/Mexico_City', 'DD/MM " a las " HH24:MI') || '.',
      './app.html'
    );
  end if;
  return NEW;
end $function$;

DROP TRIGGER IF EXISTS trg_notificar_cancelacion ON public.citas;
CREATE TRIGGER trg_notificar_cancelacion
  AFTER UPDATE ON public.citas
  FOR EACH ROW EXECUTE FUNCTION public.notificar_cancelacion();
