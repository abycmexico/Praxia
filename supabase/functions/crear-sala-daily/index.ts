import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: CORS
    });
  }
  try {
    const { cita_id } = await req.json();
    if (!cita_id) {
      return new Response(JSON.stringify({
        error: 'Falta cita_id'
      }), {
        status: 400,
        headers: CORS
      });
    }
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({
        error: 'No autorizado'
      }), {
        status: 401,
        headers: CORS
      });
    }
    const userClient = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_ANON_KEY'), {
      global: {
        headers: {
          Authorization: authHeader
        }
      }
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) {
      return new Response(JSON.stringify({
        error: 'No autorizado'
      }), {
        status: 401,
        headers: CORS
      });
    }
    const admin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    const { data: cita, error: citaErr } = await admin.from('citas').select('*').eq('id', cita_id).single();
    if (citaErr || !cita) {
      return new Response(JSON.stringify({
        error: 'Cita no encontrada'
      }), {
        status: 404,
        headers: CORS
      });
    }
    if (cita.psicologo_id !== user.id && cita.paciente_id !== user.id) {
      return new Response(JSON.stringify({
        error: 'No tienes acceso a esta cita'
      }), {
        status: 403,
        headers: CORS
      });
    }
    if (cita.daily_room_url) {
      return new Response(JSON.stringify({
        ok: true,
        url: cita.daily_room_url
      }), {
        headers: CORS
      });
    }
    if (cita.estado !== 'confirmada') {
      return new Response(JSON.stringify({
        error: 'La cita todavía no está confirmada.'
      }), {
        status: 400,
        headers: CORS
      });
    }
    const finCita = new Date(cita.fecha_hora).getTime() + (cita.duracion_minutos + 60) * 60000;
    const expUnix = Math.floor(finCita / 1000);
    const dailyRes = await fetch('https://api.daily.co/v1/rooms', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('DAILY_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        name: `praxia-${cita_id}`,
        privacy: 'private',
        properties: {
          exp: expUnix,
          enable_chat: true,
          enable_screenshare: true,
          eject_at_room_exp: true
        }
      })
    });
    const dailyData = await dailyRes.json();
    if (!dailyRes.ok) {
      return new Response(JSON.stringify({
        error: dailyData.error || 'Error al crear la sala en Daily.co'
      }), {
        status: 500,
        headers: CORS
      });
    }
    await admin.from('citas').update({
      daily_room_url: dailyData.url
    }).eq('id', cita_id);
    return new Response(JSON.stringify({
      ok: true,
      url: dailyData.url
    }), {
      headers: CORS
    });
  } catch (e) {
    return new Response(JSON.stringify({
      error: String(e)
    }), {
      status: 500,
      headers: CORS
    });
  }
});
