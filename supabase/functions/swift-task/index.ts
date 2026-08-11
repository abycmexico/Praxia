import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const REDIRECT_URI = 'https://uxbpfyeahqpertamhdxt.supabase.co/functions/v1/google-oauth-callback';
serve(async (req)=>{
  const url = new URL(req.url);
  const code = url.searchParams.get('code');
  const state = url.searchParams.get('state');
  const paginaError = (msg)=>new Response(`<html><body style="font-family:sans-serif;max-width:520px;margin:80px auto;text-align:center;">
        <h2>No se pudo conectar</h2><p>${msg}</p>
      </body></html>`, {
      status: 400,
      headers: {
        'Content-Type': 'text/html'
      }
    });
  if (!code || !state) return paginaError('Falta información en el link. Vuelve a intentarlo desde Configuración en Praxia.');
  const admin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
  const { data: estadoRow, error: estadoErr } = await admin.from('google_oauth_estados').select('*').eq('state', state).maybeSingle();
  if (estadoErr || !estadoRow) {
    return paginaError('Este link ya expiró o no es válido. Vuelve a intentarlo desde Configuración en Praxia.');
  }
  await admin.from('google_oauth_estados').delete().eq('state', state);
  const clientId = Deno.env.get('GOOGLE_CLIENT_ID');
  const clientSecret = Deno.env.get('GOOGLE_CLIENT_SECRET');
  const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({
      code,
      client_id: clientId,
      client_secret: clientSecret,
      redirect_uri: REDIRECT_URI,
      grant_type: 'authorization_code'
    })
  });
  const tokenData = await tokenRes.json();
  if (!tokenRes.ok || !tokenData.refresh_token) {
    return paginaError('Google no otorgó permiso permanente. Si ya habías autorizado Praxia antes, ve a myaccount.google.com/permissions, quita el acceso, y vuelve a intentarlo desde cero.');
  }
  await admin.from('google_calendar_tokens').upsert({
    psicologo_id: estadoRow.psicologo_id,
    refresh_token: tokenData.refresh_token
  });
  const html = `
    <html>
      <body style="font-family: sans-serif; max-width: 500px; margin: 80px auto; text-align: center; padding: 0 20px;">
        <h2>Google Calendar conectado ✓</h2>
        <p>Ya puedes cerrar esta ventana y volver a Praxia.</p>
      </body>
    </html>
  `;
  return new Response(html, {
    headers: {
      'Content-Type': 'text/html'
    }
  });
});
