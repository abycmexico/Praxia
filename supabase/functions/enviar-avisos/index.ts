// Despacha los avisos encolados a los dispositivos del psicologo.
//
// Web Push exige firmar un JWT con la llave VAPID (ES256) y cifrar el
// contenido con las llaves del navegador. Aqui se firma el JWT y se manda
// el push SIN cuerpo cifrado: el service worker recibe el aviso y muestra
// un texto fijo. Cifrar el payload requiere ECDH+HKDF+AES-GCM, y para lo
// que necesitamos no vale la pena: el texto del aviso aparece en la
// pantalla bloqueada del telefono, donde no deberia ir nada del paciente
// de todos modos.
//
// Se llama sola desde un cron, o a mano para probar.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const responder = (c: unknown, s = 200) =>
  new Response(JSON.stringify(c), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } });

function base64url(datos: ArrayBuffer | Uint8Array): string {
  const bytes = datos instanceof Uint8Array ? datos : new Uint8Array(datos);
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function desdeBase64url(txt: string): Uint8Array {
  const s = txt.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(s + '='.repeat((4 - s.length % 4) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

// El JWT de VAPID le prueba al servidor de push que el envio viene de
// nosotros. Va firmado con la llave privada, que solo vive en los secretos.
async function firmarVapid(aud: string, privadaB64: string, publicaB64: string, sujeto: string) {
  const encabezado = base64url(new TextEncoder().encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const cuerpo = base64url(new TextEncoder().encode(JSON.stringify({
    aud,
    exp: Math.floor(Date.now() / 1000) + 12 * 3600,
    sub: sujeto,
  })));

  const privada = desdeBase64url(privadaB64);
  const publica = desdeBase64url(publicaB64); // 65 bytes: 0x04 + X(32) + Y(32)

  const jwk = {
    kty: 'EC',
    crv: 'P-256',
    d: base64url(privada),
    x: base64url(publica.slice(1, 33)),
    y: base64url(publica.slice(33, 65)),
    ext: true,
  };

  const llave = await crypto.subtle.importKey(
    'jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'],
  );

  const firma = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    llave,
    new TextEncoder().encode(`${encabezado}.${cuerpo}`),
  );

  return `${encabezado}.${cuerpo}.${base64url(firma)}`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const PUBLICA = Deno.env.get('VAPID_PUBLIC_KEY');
  const PRIVADA = Deno.env.get('VAPID_PRIVATE_KEY');
  const SUJETO = Deno.env.get('VAPID_SUBJECT') || 'mailto:hola@praxia.mx';

  if (!PUBLICA || !PRIVADA) return responder({ error: 'Faltan las llaves VAPID.' }, 500);

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // Se toman pocos por vuelta: mas vale despachar seguido que intentar
  // vaciar la cola de golpe y que la funcion se quede sin tiempo.
  const { data: avisos } = await sb.from('avisos_pendientes')
    .select('*').is('enviado_en', null).lt('intentos', 3)
    .order('creado_en').limit(40);

  if (!avisos?.length) return responder({ enviados: 0, mensaje: 'No hay avisos pendientes.' });

  let enviados = 0, sinDispositivo = 0, fallidos = 0;

  for (const aviso of avisos) {
    const { data: dispositivos } = await sb.from('suscripciones_push')
      .select('*').eq('psicologo_id', aviso.psicologo_id);

    if (!dispositivos?.length) {
      // Sin dispositivos no hay a donde mandarlo. Se marca como despachado
      // para que no se quede reintentando por siempre; el aviso igual quedo
      // guardado en notificaciones, que es lo que ve dentro de la app.
      await sb.from('avisos_pendientes')
        .update({ enviado_en: new Date().toISOString() }).eq('id', aviso.id);
      sinDispositivo++;
      continue;
    }

    let algunoOk = false;

    for (const d of dispositivos) {
      try {
        const url = new URL(d.endpoint);
        const jwt = await firmarVapid(url.origin, PRIVADA, PUBLICA, SUJETO);

        const r = await fetch(d.endpoint, {
          method: 'POST',
          headers: {
            TTL: '86400',
            Urgency: 'normal',
            Authorization: `vapid t=${jwt}, k=${PUBLICA}`,
          },
        });

        if (r.ok) {
          algunoOk = true;
          await sb.from('suscripciones_push')
            .update({ ultimo_envio: new Date().toISOString(), fallos: 0 })
            .eq('endpoint', d.endpoint);
        } else if (r.status === 404 || r.status === 410) {
          // El navegador desinstalo la app o revoco el permiso: la
          // suscripcion ya no existe y guardarla solo acumula basura.
          await sb.from('suscripciones_push').delete().eq('endpoint', d.endpoint);
        } else {
          await sb.from('suscripciones_push')
            .update({ fallos: (d.fallos || 0) + 1 }).eq('endpoint', d.endpoint);
        }
      } catch (_) {
        fallidos++;
      }
    }

    await sb.from('avisos_pendientes').update(
      algunoOk
        ? { enviado_en: new Date().toISOString() }
        : { intentos: (aviso.intentos || 0) + 1 },
    ).eq('id', aviso.id);

    if (algunoOk) enviados++;
  }

  return responder({ enviados, sinDispositivo, fallidos, revisados: avisos.length });
});
