// Cobro al paciente: su saldo pendiente o su mensualidad.
//
// El cargo se hace EN la cuenta del psicologo (direct charge): el dinero
// llega a el, no a Praxia. Praxia solo retiene su comision como
// application_fee, que Stripe separa en el mismo momento del pago.
//
// El monto no viene del navegador. Se calcula aqui contra la base, porque
// si lo mandara el cliente cualquiera podria pagar un peso por su mes.

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

    const autorizacion = req.headers.get('Authorization');
    if (!autorizacion) return responder({ error: 'Falta la sesión.' }, 401);

    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: autorizacion } } },
    );

    const { data: { user }, error: errUsuario } = await sb.auth.getUser();
    if (errUsuario || !user) return responder({ error: 'Sesión no válida.' }, 401);

    const { concepto, url_retorno } = await req.json().catch(() => ({}));

    // Quien paga es el paciente de la sesion, no un id que mande el cliente.
    const { data: pacienteId } = await sb.rpc('mi_paciente_id');
    if (!pacienteId) return responder({ error: 'No encontramos tu expediente.' }, 404);

    const { data: paciente } = await sb.from('pacientes')
      .select('id, nombre, correo, psicologo_id').eq('id', pacienteId).maybeSingle();
    if (!paciente) return responder({ error: 'No encontramos tu expediente.' }, 404);

    // Datos del psicologo: se leen con llave de servicio porque el paciente
    // no tiene permiso de ver la cuenta de Stripe de nadie, ni debe tenerlo.
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: psi } = await admin.from('psicologos')
      .select('id, nombre, stripe_account_id, stripe_cobros_activos')
      .eq('id', paciente.psicologo_id).maybeSingle();

    if (!psi?.stripe_account_id || !psi.stripe_cobros_activos) {
      return responder({ error: 'Tu psicólogo todavía no tiene activo el cobro en línea.' }, 400);
    }

    // ---- cuanto se cobra, calculado aqui ----
    let montoPesos = 0;
    let descripcion = '';

    if (concepto === 'mensualidad') {
      const { data: susc } = await admin.from('suscripciones_paciente')
        .select('*, planes_paciente(nombre, precio, sesiones_incluidas)')
        .eq('paciente_id', paciente.id).maybeSingle();

      if (!susc?.planes_paciente) return responder({ error: 'No tienes un plan asignado.' }, 400);
      montoPesos = Number(susc.planes_paciente.precio);
      descripcion = `${susc.planes_paciente.nombre} — ${susc.planes_paciente.sesiones_incluidas} sesiones`;
    } else {
      const { data: cuenta } = await admin.from('estado_cuenta_pacientes')
        .select('saldo').eq('paciente_id', paciente.id).maybeSingle();

      montoPesos = Number(cuenta?.saldo || 0);
      descripcion = 'Sesiones pendientes de pago';
      if (montoPesos <= 0) return responder({ error: 'No tienes nada pendiente por pagar.' }, 400);
    }

    if (!(montoPesos > 0)) return responder({ error: 'No hay monto que cobrar.' }, 400);

    // ---- comision de Praxia ----
    const { data: cfg } = await admin.from('config_plataforma')
      .select('comision_porcentaje').maybeSingle();
    const porcentaje = Number(cfg?.comision_porcentaje ?? 0);

    const centavos = Math.round(montoPesos * 100);
    const comision = Math.round(centavos * porcentaje / 100);

    const base = url_retorno || `${req.headers.get('origin')}/panel-paciente.html`;

    const parametros = new URLSearchParams({
      mode: 'payment',
      'line_items[0][price_data][currency]': 'mxn',
      'line_items[0][price_data][unit_amount]': String(centavos),
      'line_items[0][price_data][product_data][name]': descripcion,
      'line_items[0][price_data][product_data][description]': `Con ${psi.nombre}`,
      'line_items[0][quantity]': '1',
      success_url: `${base}?pago=ok`,
      cancel_url: `${base}?pago=cancelado`,
      locale: 'es',
      customer_email: paciente.correo ?? '',
      'metadata[paciente_id]': paciente.id,
      'metadata[psicologo_id]': psi.id,
      'metadata[concepto]': concepto === 'mensualidad' ? 'mensualidad' : 'saldo',
      // Guardar la tarjeta para que la proxima vez pague de un clic.
      'payment_intent_data[setup_future_usage]': 'off_session',
    });

    if (comision > 0) {
      parametros.set('payment_intent_data[application_fee_amount]', String(comision));
    }

    // El header Stripe-Account hace que el cargo ocurra en la cuenta del
    // psicologo: el dinero es suyo desde el primer momento.
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

    return responder({ url: sesion.url, monto: montoPesos });
  } catch (e) {
    return responder({ error: String(e?.message || e) }, 500);
  }
});
