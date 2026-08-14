// Recibe los avisos de Stripe y mantiene la suscripcion al dia.
//
// La firma se verifica siempre: este endpoint es publico, y sin verificar
// cualquiera podria mandar un "pago exitoso" inventado y activarse el plan
// sin pagar. Por eso tampoco se confia en el cuerpo hasta comprobarla.
//
// Escribe con la llave de servicio porque no hay usuario detras: el que
// llama es Stripe, no una sesion.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const TOLERANCIA_SEGUNDOS = 300; // evita reenvios viejos

function hexAaBytes(hex: string): Uint8Array {
  const b = new Uint8Array(hex.length / 2);
  for (let i = 0; i < b.length; i++) b[i] = parseInt(hex.substr(i * 2, 2), 16);
  return b;
}

// Comparacion en tiempo constante: comparar con === filtra informacion por
// el tiempo que tarda en fallar.
function igualesEnTiempoConstante(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let dif = 0;
  for (let i = 0; i < a.length; i++) dif |= a[i] ^ b[i];
  return dif === 0;
}

async function firmaValida(cuerpo: string, encabezado: string, secreto: string): Promise<boolean> {
  const partes = Object.fromEntries(
    encabezado.split(',').map((p) => p.split('=') as [string, string]),
  );
  const t = partes['t'];
  const v1 = partes['v1'];
  if (!t || !v1) return false;

  const edad = Math.floor(Date.now() / 1000) - Number(t);
  if (!Number.isFinite(edad) || Math.abs(edad) > TOLERANCIA_SEGUNDOS) return false;

  const clave = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secreto),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const firma = await crypto.subtle.sign(
    'HMAC',
    clave,
    new TextEncoder().encode(`${t}.${cuerpo}`),
  );

  return igualesEnTiempoConstante(new Uint8Array(firma), hexAaBytes(v1));
}

Deno.serve(async (req) => {
  const SECRETO = Deno.env.get('STRIPE_WEBHOOK_SECRET');
  if (!SECRETO) return new Response('Falta STRIPE_WEBHOOK_SECRET', { status: 500 });

  const encabezado = req.headers.get('stripe-signature');
  if (!encabezado) return new Response('Falta la firma', { status: 400 });

  const cuerpo = await req.text();
  if (!(await firmaValida(cuerpo, encabezado, SECRETO))) {
    return new Response('Firma no válida', { status: 400 });
  }

  const evento = JSON.parse(cuerpo);
  const dato = evento.data?.object ?? {};

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // El titular viaja en metadata desde que se creo el checkout.
  const titularId = dato.metadata?.titular_id;
  const planId = dato.metadata?.plan_id;

  try {
    switch (evento.type) {
      // Termino de pagar por primera vez.
      case 'checkout.session.completed': {
        if (!titularId) break;
        const finPeriodo = new Date();
        finPeriodo.setMonth(finPeriodo.getMonth() + 1);

        await sb.from('suscripciones').upsert({
          titular_id: titularId,
          plan_id: planId ?? 'individual',
          estado: 'activa',
          fin_periodo: finPeriodo.toISOString(),
          renovacion_automatica: true,
          cancelada_en: null,
          stripe_customer_id: dato.customer,
          stripe_subscription_id: dato.subscription,
          actualizado_en: new Date().toISOString(),
        }, { onConflict: 'titular_id' });
        break;
      }

      // Se cobro un mes: se recorre el fin de periodo a lo que diga Stripe.
      case 'invoice.paid': {
        const idSuscripcion = dato.subscription;
        if (!idSuscripcion) break;
        const fin = dato.lines?.data?.[0]?.period?.end;
        const finPeriodo = fin
          ? new Date(fin * 1000)
          : (() => { const d = new Date(); d.setMonth(d.getMonth() + 1); return d; })();

        await sb.from('suscripciones')
          .update({
            estado: 'activa',
            fin_periodo: finPeriodo.toISOString(),
            actualizado_en: new Date().toISOString(),
          })
          .eq('stripe_subscription_id', idSuscripcion);
        break;
      }

      // Fallo el cobro. No se corta el acceso aqui: Stripe reintenta varios
      // dias, y el periodo pagado sigue corriendo. Solo se marca.
      case 'invoice.payment_failed': {
        if (!dato.subscription) break;
        await sb.from('suscripciones')
          .update({ estado: 'impago', actualizado_en: new Date().toISOString() })
          .eq('stripe_subscription_id', dato.subscription);
        break;
      }

      // Cancelacion o cambio hecho desde Stripe.
      case 'customer.subscription.updated': {
        const cancelaAlFinal = dato.cancel_at_period_end === true;
        const fin = dato.current_period_end ? new Date(dato.current_period_end * 1000) : null;
        const cambios: Record<string, unknown> = {
          renovacion_automatica: !cancelaAlFinal,
          actualizado_en: new Date().toISOString(),
        };
        if (fin) cambios.fin_periodo = fin.toISOString();
        if (cancelaAlFinal) {
          cambios.estado = 'cancelada';
          cambios.cancelada_en = new Date().toISOString();
        } else if (dato.status === 'active') {
          cambios.estado = 'activa';
          cambios.cancelada_en = null;
        }
        await sb.from('suscripciones').update(cambios).eq('stripe_subscription_id', dato.id);
        break;
      }

      // El psicologo avanzo en su alta de Connect. Stripe avisa varias veces
      // durante el tramite; lo que importa es si ya puede cobrar.
      case 'account.updated': {
        const psicologoId = dato.metadata?.psicologo_id;
        const filtro = psicologoId
          ? { columna: 'id', valor: psicologoId }
          : { columna: 'stripe_account_id', valor: dato.id };

        await sb.from('psicologos')
          .update({
            stripe_cobros_activos: dato.charges_enabled === true,
            stripe_alta_completa: dato.details_submitted === true,
          })
          .eq(filtro.columna, filtro.valor);
        break;
      }

      // Se acabo de verdad: ya paso el periodo pagado.
      case 'customer.subscription.deleted': {
        await sb.from('suscripciones')
          .update({
            estado: 'vencida',
            renovacion_automatica: false,
            fin_periodo: new Date().toISOString(),
            actualizado_en: new Date().toISOString(),
          })
          .eq('stripe_subscription_id', dato.id);
        break;
      }
    }
  } catch (e) {
    // Se devuelve 500 a proposito: Stripe reintenta, y es preferible a dar
    // por bueno un evento que no se pudo guardar.
    console.error('Error procesando', evento.type, e);
    return new Response('Error al procesar', { status: 500 });
  }

  return new Response(JSON.stringify({ recibido: true }), {
    headers: { 'Content-Type': 'application/json' },
  });
});
