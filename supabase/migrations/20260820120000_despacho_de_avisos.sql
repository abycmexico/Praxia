-- Despacho automatico de los avisos encolados.
--
-- Sin esto los avisos se quedan en la cola hasta que alguien abra la app, y
-- justo el punto de un push es enterarse cuando NO la tienes abierta.
--
-- pg_net hace la llamada sin bloquear la transaccion, y pg_cron la dispara
-- cada minuto. Un minuto es suficiente: un aviso de solicitud de cita no
-- necesita ser instantaneo, y revisar mas seguido solo gasta.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- La llave de servicio vive en Vault, no escrita en el cuerpo del cron:
-- pg_cron guarda su comando en una tabla que se puede leer.
CREATE OR REPLACE FUNCTION public.despachar_avisos()
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
  AS $function$
declare
  v_url   text;
  v_llave text;
begin
  -- Si no hay nada que mandar, no se gasta una llamada.
  if not exists(select 1 from avisos_pendientes where enviado_en is null and intentos < 3) then
    return;
  end if;

  select decrypted_secret into v_url   from vault.decrypted_secrets where name = 'url_proyecto';
  select decrypted_secret into v_llave from vault.decrypted_secrets where name = 'llave_servicio';

  if v_url is null or v_llave is null then
    raise notice 'Falta configurar url_proyecto o llave_servicio en Vault.';
    return;
  end if;

  perform net.http_post(
    url     := v_url || '/functions/v1/enviar-avisos',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_llave
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 20000
  );
end $function$;

REVOKE ALL ON FUNCTION public.despachar_avisos() FROM PUBLIC;

-- Cada minuto. Se borra antes por si la migracion corre dos veces.
SELECT cron.unschedule('despachar-avisos-praxia')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'despachar-avisos-praxia');

SELECT cron.schedule(
  'despachar-avisos-praxia',
  '* * * * *',
  $$ SELECT public.despachar_avisos(); $$
);

-- Los avisos ya despachados no sirven de nada guardados. Se limpian solos
-- cada noche para que la tabla no crezca sin fin.
SELECT cron.unschedule('limpiar-avisos-praxia')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'limpiar-avisos-praxia');

SELECT cron.schedule(
  'limpiar-avisos-praxia',
  '20 4 * * *',
  $$ DELETE FROM public.avisos_pendientes
      WHERE (enviado_en IS NOT NULL AND enviado_en < now() - interval '7 days')
         OR (intentos >= 3 AND creado_en < now() - interval '7 days'); $$
);
