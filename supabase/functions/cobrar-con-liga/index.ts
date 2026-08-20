// Cobro por liga: el paciente paga sin cuenta y sin contraseña.
//
// Es hermana de pagar-paciente, con una diferencia de fondo: alli quien paga
// se identifica con su sesion, y aqui con el token de la liga. Por eso todo
// lo que decide el cobro -a quien, cuanto, por que- se lee de la base a
// partir del token y NUNCA de lo que mande el navegador. Si el monto viniera
// del cliente, cualquiera podria pagar un peso.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const responder = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const CLAVE = Deno.env.get('STRIPE_SECRET_KEY');
    if (!CLAVE) return responder({ error: 'Falta configurar STRIPE_SECRET_KEY.' }, 500);

    const { cobro_id, url_retorno } = await req.json().catch(() => ({}));
    if (!cobro_id) return responder({ error: 'Falta la liga de cobro.' }, 400);

    // Llave de servicio: quien paga no tiene cuenta, asi que no hay sesion
    // con la cual leer. Lo que protege el cobro es que el token es aleatorio
    // y de un solo uso, no un permiso de base de datos.
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: cobro } = await admin.from('cobros_liga')
      .select('*').eq('id', cobro_id).maybeSingle();

    if (!cobro) return responder({ error: 'Esta liga de pago no existe.' }, 404);
    if (cobro.estado === 'pagado') return responder({ error: 'Este cobro ya fue pagado.' }, 409);
    if (cobro.estado === 'cancelado') return responder({ error: 'Este cobro fue cancelado.' }, 409);
    if (new Date(cobro.expira_en) <= new Date()) {
      return responder({ error: 'Esta liga de pago ya venció. Pídele una nueva a tu psicólogo.' }, 410);
    }

    const { data: psi } = await admin.from('psicologos')
      .select('id, nombre, stripe_account_id, stripe_cobros_activos')
      .eq('id', cobro.psicologo_id).maybeSingle();

    if (!psi?.stripe_account_id || !psi.stripe_cobros_activos) {
      return responder({ error: 'Tu psicólogo todavía no tiene activo el cobro en línea.' }, 400);
    }

    // El correo se usa solo para mandarle su recibo. No se enseña en la
    // pagina de la liga: ahi no debe verse quien es el paciente.
    const { data: paciente } = await admin.from('pacientes')
      .select('id, correo').eq('id', cobro.paciente_id).maybeSingle();

    const { data: cfg } = await admin.from('config_plataforma')
      .select('comision_porcentaje').maybeSingle();
    const porcentaje = Number(cfg?.comision_porcentaje ?? 0);

    const centavos = Math.round(Number(cobro.monto) * 100);
    const comision = Math.round(centavos * porcentaje / 100);

    const base = url_retorno || `${req.headers.get('origin')}/pagar.html`;

    const parametros = new URLSearchParams({
      mode: 'payment',
      'line_items[0][price_data][currency]': 'mxn',
      'line_items[0][price_data][unit_amount]': String(centavos),
      'line_items[0][price_data][product_data][name]': cobro.concepto,
      'line_items[0][price_data][product_data][description]': `Con ${psi.nombre}`,
      'line_items[0][quantity]': '1',
      success_url: `${base}?c=${cobro.id}&pago=ok`,
      cancel_url: `${base}?c=${cobro.id}&pago=cancelado`,
      locale: 'es',
      customer_email: paciente?.correo ?? '',
      // El webhook usa estos datos para registrar el pago y marcar la liga.
      'metadata[paciente_id]': cobro.paciente_id,
      'metadata[psicologo_id]': cobro.psicologo_id,
      'metadata[concepto]': 'liga',
      'metadata[cobro_id]': cobro.id,
    });

    if (comision > 0) {
      parametros.set('payment_intent_data[application_fee_amount]', String(comision));
    }

    // Stripe-Account hace que el cargo ocurra en la cuenta del psicologo: el
    // dinero es suyo desde el primer momento y Praxia no lo intermedia.
    const r = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${CLAVE}`,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Stripe-Account': psi.stripe_account_id,
      },
      body: parametros,
    });

    const sesion = await r.json();
    if (!r.ok) return responder({ error: sesion?.error?.message || 'Stripe rechazó el cobro.' }, 502);

    return responder({ url: sesion.url, monto: Number(cobro.monto) });
  } catch (e) {
    return responder({ error: String(e?.message || e) }, 500);
  }
});
