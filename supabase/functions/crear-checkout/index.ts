// Abre el checkout de Stripe para contratar un plan.
//
// Quien puede contratar es el titular: el psicologo individual o el
// responsable del consultorio. Un colaborador queda cubierto por la
// suscripcion de su consultorio, asi que no contrata por su cuenta.
//
// El precio no viene del cliente sino de la tabla `planes`. Si el navegador
// mandara el price_id, cualquiera podria pedir el checkout del plan barato
// y quedarse con el caro.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function responder(cuerpo: unknown, status = 200) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY');
    if (!STRIPE_SECRET_KEY) return responder({ error: 'Falta configurar STRIPE_SECRET_KEY.' }, 500);

    const autorizacion = req.headers.get('Authorization');
    if (!autorizacion) return responder({ error: 'Falta la sesión.' }, 401);

    // Cliente con el token del usuario: las políticas de RLS siguen aplicando.
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: autorizacion } } },
    );

    const { data: { user }, error: errUsuario } = await sb.auth.getUser();
    if (errUsuario || !user) return responder({ error: 'Sesión no válida.' }, 401);

    const { plan_id, url_exito, url_cancelar } = await req.json();
    if (!plan_id) return responder({ error: 'Falta indicar el plan.' }, 400);

    // Solo el titular contrata.
    const { data: titular } = await sb.rpc('titular_de_mi_suscripcion');
    if (titular !== user.id) {
      return responder({ error: 'La suscripción la administra el responsable de tu consultorio.' }, 403);
    }

    const { data: plan, error: errPlan } = await sb
      .from('planes')
      .select('id, nombre, stripe_price_id')
      .eq('id', plan_id)
      .eq('activo', true)
      .maybeSingle();

    if (errPlan || !plan) return responder({ error: 'Ese plan no existe.' }, 404);
    if (!plan.stripe_price_id) return responder({ error: `El plan ${plan.nombre} no tiene precio configurado en Stripe.` }, 500);

    // Se reutiliza el cliente de Stripe si ya existe, para no duplicarlo en
    // cada contratacion y que el historial de cobros quede junto.
    const { data: suscripcion } = await sb
      .from('suscripciones')
      .select('stripe_customer_id')
      .eq('titular_id', user.id)
      .maybeSingle();

    const parametros = new URLSearchParams({
      mode: 'subscription',
      'line_items[0][price]': plan.stripe_price_id,
      'line_items[0][quantity]': '1',
      success_url: url_exito || `${req.headers.get('origin')}/panel-psicologo.html?suscripcion=ok`,
      cancel_url: url_cancelar || `${req.headers.get('origin')}/panel-psicologo.html?suscripcion=cancelado`,
      locale: 'es',
      // El webhook necesita saber a quien activarle el plan.
      'metadata[titular_id]': user.id,
      'metadata[plan_id]': plan.id,
      'subscription_data[metadata][titular_id]': user.id,
      'subscription_data[metadata][plan_id]': plan.id,
    });

    if (suscripcion?.stripe_customer_id) {
      parametros.set('customer', suscripcion.stripe_customer_id);
    } else {
      parametros.set('customer_email', user.email ?? '');
    }

    const respuesta = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: parametros,
    });

    const sesion = await respuesta.json();
    if (!respuesta.ok) {
      return responder({ error: sesion?.error?.message || 'Stripe rechazó la solicitud.' }, 502);
    }

    return responder({ url: sesion.url });
  } catch (e) {
    return responder({ error: String(e?.message || e) }, 500);
  }
});
