// Alta del psicologo en Stripe Connect con Accounts v2.
//
// La cuenta es suya, no de Praxia: el dinero de sus pacientes le llega
// directo y Praxia solo toma su comision. Stripe le pide sus datos
// fiscales y bancarios en su propia pantalla; nunca pasan por aqui.
//
// Se usa Accounts v2 porque es lo que Stripe recomienda para integraciones
// nuevas. Ojo: va con una version de API en preview, asi que si Stripe
// cambia el contrato hay que actualizar aqui. La version se fija explicita
// para que un cambio no llegue solo.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const VERSION_API = '2026-07-29.preview';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const responder = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

// Las rutas v2 hablan JSON, a diferencia de las v1 que van form-encoded.
async function stripeV2(ruta: string, clave: string, cuerpo: unknown) {
  const r = await fetch(`https://api.stripe.com/v2/${ruta}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${clave}`,
      'Content-Type': 'application/json',
      'Stripe-Version': VERSION_API,
    },
    body: JSON.stringify(cuerpo),
  });
  const datos = await r.json();
  if (!r.ok) {
    const detalle = datos?.error?.message || datos?.message || JSON.stringify(datos);
    throw new Error(detalle);
  }
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

    const { url_retorno, revisar } = await req.json().catch(() => ({}));
    const base = url_retorno || `${req.headers.get('origin')}/panel-psicologo.html`;

    let cuenta = psi.stripe_account_id;

    // Consultar el estado a Stripe en vez de esperar el webhook.
    //
    // Antes esto dependia solo de 'account.updated': si ese aviso se perdia
    // -o llegaba antes de que el webhook existiera- el psicologo quedaba con
    // los cobros apagados para siempre y su paciente nunca veia como pagar,
    // sin ningun error a la vista. Preguntar es barato y quita esa
    // dependencia de un solo evento que puede no llegar.
    //
    // Se pregunta por la ruta v1: aunque la cuenta se crea con v2, v1 sigue
    // respondiendo por el mismo acct_ y sus campos son estables, a
    // diferencia de los de la version preview.
    if (revisar) {
      if (!cuenta) return responder({ tiene_cuenta: false, alta_completa: false, cobros_activos: false });

      const r = await fetch(`https://api.stripe.com/v1/accounts/${cuenta}`, {
        headers: { Authorization: `Bearer ${CLAVE}` },
      });
      const datos = await r.json();
      if (!r.ok) return responder({ error: datos?.error?.message || 'Stripe no respondió.' }, 500);

      const cobros = datos.charges_enabled === true;
      const alta = datos.details_submitted === true;

      await sb.from('psicologos')
        .update({ stripe_cobros_activos: cobros, stripe_alta_completa: alta })
        .eq('id', psi.id);

      return responder({
        tiene_cuenta: true,
        alta_completa: alta,
        cobros_activos: cobros,
        // Lo que Stripe sigue esperando, para poder decirle que le falta en
        // vez de solo "no puedes cobrar".
        pendiente: datos.requirements?.currently_due ?? [],
      });
    }

    // Se crea una sola vez. Crear otra dejaria al psicologo con dos cuentas
    // y el dinero repartido entre ambas.
    if (!cuenta) {
      const nueva = await stripeV2('core/accounts', CLAVE, {
        contact_email: psi.correo ?? undefined,
        display_name: psi.nombre ?? undefined,
        dashboard: 'express',
        identity: {
          country: 'mx',
          entity_type: 'individual',
        },
        // merchant es la configuracion que permite recibir pagos.
        configuration: {
          merchant: {
            capabilities: {
              card_payments: { requested: true },
            },
          },
        },
        defaults: {
          currency: 'mxn',
          locales: ['es-419'],
          // Las comisiones y las perdidas las asume la cuenta conectada:
          // el servicio lo presta el psicologo, y asi un contracargo de su
          // paciente no le pega al saldo de Praxia.
          responsibilities: {
            fees_collector: 'stripe',
            losses_collector: 'stripe',
          },
        },
        metadata: { psicologo_id: psi.id },
        include: ['configuration.merchant', 'identity', 'requirements'],
      });

      cuenta = nueva.id;

      const { error } = await sb.from('psicologos')
        .update({ stripe_account_id: cuenta }).eq('id', psi.id);

      // Si no se guarda, se aborta: quedarse con una cuenta creada en Stripe
      // que Praxia no conoce es peor que no haberla creado.
      if (error) return responder({ error: 'No se pudo guardar tu cuenta: ' + error.message }, 500);
    }

    const liga = await stripeV2('core/account_links', CLAVE, {
      account: cuenta,
      use_case: {
        type: 'account_onboarding',
        account_onboarding: {
          configurations: ['merchant'],
          refresh_url: `${base}?cobros=reintentar`,
          return_url: `${base}?cobros=listo`,
        },
      },
    });

    return responder({ url: liga.url });
  } catch (e) {
    return responder({ error: String(e?.message || e) }, 500);
  }
});
