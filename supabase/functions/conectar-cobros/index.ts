// Alta del psicologo en Stripe Connect, para que pueda cobrarle a sus
// pacientes.
//
// La cuenta es suya, no de Praxia: el dinero de sus pacientes le llega
// directo y Praxia solo toma su comision. Por eso Stripe le pide a el sus
// datos fiscales y bancarios, en su propia pantalla, y esos datos nunca
// pasan por aqui.
//
// Devuelve una liga de alta que caduca: si la deja a medias, se pide otra.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const responder = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

async function stripe(ruta: string, clave: string, cuerpo?: URLSearchParams) {
  const r = await fetch(`https://api.stripe.com/v1/${ruta}`, {
    method: cuerpo ? 'POST' : 'GET',
    headers: {
      Authorization: `Bearer ${clave}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: cuerpo,
  });
  const datos = await r.json();
  if (!r.ok) throw new Error(datos?.error?.message || 'Stripe rechazó la solicitud.');
  return datos;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const CLAVE = Deno.env.get('STRIPE_SECRET_KEY');
    if (!CLAVE) return responder({ error: 'Falta configurar STRIPE_SECRET_KEY.' }, 500);

    const autorizacion = req.headers.get('Authorization');
    if (!autorizacion) return responder({ error: 'Falta la sesión.' }, 401);

    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: autorizacion } } },
    );

    const { data: { user }, error: errUsuario } = await sb.auth.getUser();
    if (errUsuario || !user) return responder({ error: 'Sesión no válida.' }, 401);

    const { data: psi } = await sb.from('psicologos')
      .select('id, nombre, correo, stripe_account_id').eq('id', user.id).maybeSingle();
    if (!psi) return responder({ error: 'No encontramos tu perfil de psicólogo.' }, 404);

    const { url_retorno } = await req.json().catch(() => ({}));
    const base = url_retorno || `${req.headers.get('origin')}/panel-psicologo.html`;

    let cuenta = psi.stripe_account_id;

    // Se crea una sola vez. Si ya existe, se reusa: crear otra dejaria al
    // psicologo con dos cuentas y el dinero repartido entre ambas.
    if (!cuenta) {
      const nueva = await stripe('accounts', CLAVE, new URLSearchParams({
        type: 'express',
        country: 'MX',
        email: psi.correo ?? '',
        'capabilities[card_payments][requested]': 'true',
        'capabilities[transfers][requested]': 'true',
        'business_type': 'individual',
        'business_profile[product_description]': 'Servicios de psicología',
        'metadata[psicologo_id]': psi.id,
      }));
      cuenta = nueva.id;

      const { error } = await sb.from('psicologos')
        .update({ stripe_account_id: cuenta }).eq('id', psi.id);

      // Si no se guarda, se aborta: quedarse con una cuenta creada en Stripe
      // que Praxia no conoce es peor que no haberla creado.
      if (error) return responder({ error: 'No se pudo guardar tu cuenta: ' + error.message }, 500);
    }

    const liga = await stripe('account_links', CLAVE, new URLSearchParams({
      account: cuenta!,
      refresh_url: `${base}?cobros=reintentar`,
      return_url: `${base}?cobros=listo`,
      type: 'account_onboarding',
    }));

    return responder({ url: liga.url });
  } catch (e) {
    return responder({ error: String(e?.message || e) }, 500);
  }
});
