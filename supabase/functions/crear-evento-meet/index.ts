import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
async function obtenerAccessToken(refreshToken) {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({
      client_id: Deno.env.get('GOOGLE_CLIENT_ID'),
      client_secret: Deno.env.get('GOOGLE_CLIENT_SECRET'),
      refresh_token: refreshToken,
      grant_type: 'refresh_token'
    })
  });
  const data = await res.json();
  if (!res.ok) throw new Error('No se pudo renovar el acceso a Google: ' + JSON.stringify(data));
  return data.access_token;
}
async function crearEventoMeet(accessToken, titulo, inicio, duracionMin) {
  const fin = new Date(inicio.getTime() + duracionMin * 60000);
  const res = await fetch('https://www.googleapis.com/calendar/v3/calendars/primary/events?conferenceDataVersion=1', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      summary: titulo,
      start: {
        dateTime: inicio.toISOString()
      },
      end: {
        dateTime: fin.toISOString()
      },
      conferenceData: {
        createRequest: {
          requestId: crypto.randomUUID(),
          conferenceSolutionKey: {
            type: 'hangoutsMeet'
          }
        }
      }
    })
  });
  const data = await res.json();
  if (!res.ok) throw new Error('No se pudo crear el evento: ' + JSON.stringify(data));
  return data.hangoutLink || data.conferenceData?.entryPoints?.[0]?.uri;
}
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: CORS
    });
  }
  try {
    const { cita_id } = await req.json();
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
    let psicologoId;
    let inicio;
    let duracion;
    let cita = null;
    if (cita_id) {
      const { data: c, error: citaErr } = await admin.from('citas').select('*').eq('id', cita_id).single();
      if (citaErr || !c) {
        return new Response(JSON.stringify({
          error: 'Cita no encontrada'
        }), {
          status: 404,
          headers: CORS
        });
      }
      if (c.psicologo_id !== user.id && c.paciente_id !== user.id) {
        return new Response(JSON.stringify({
          error: 'No tienes acceso a esta cita'
        }), {
          status: 403,
          headers: CORS
        });
      }
      if (c.videollamada_url) {
        return new Response(JSON.stringify({
          ok: true,
          url: c.videollamada_url
        }), {
          headers: CORS
        });
      }
      if (c.estado !== 'confirmada') {
        return new Response(JSON.stringify({
          error: 'La cita todavía no está confirmada.'
        }), {
          status: 400,
          headers: CORS
        });
      }
      cita = c;
      psicologoId = c.psicologo_id;
      inicio = new Date(c.fecha_hora);
      duracion = c.duracion_minutos || 50;
    } else {
      psicologoId = user.id;
      inicio = new Date();
      duracion = 60;
    }
    const { data: tokenRow, error: tokenErr } = await admin.from('google_calendar_tokens').select('refresh_token').eq('psicologo_id', psicologoId).maybeSingle();
    if (tokenErr || !tokenRow) {
      return new Response(JSON.stringify({
        error: 'Este psicólogo todavía no conecta su Google Calendar. Conéctalo en Configuración → Integraciones.'
      }), {
        status: 400,
        headers: CORS
      });
    }
    const accessToken = await obtenerAccessToken(tokenRow.refresh_token);
    const titulo = cita_id ? 'Sesión - Praxia' : 'Consulta rápida - Praxia';
    const url = await crearEventoMeet(accessToken, titulo, inicio, duracion);
    if (cita) {
      await admin.from('citas').update({
        videollamada_url: url
      }).eq('id', cita_id);
    }
    return new Response(JSON.stringify({
      ok: true,
      url
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
