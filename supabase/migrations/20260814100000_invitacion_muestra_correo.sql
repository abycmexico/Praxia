-- La pantalla de invitacion ahora deja crear la cuenta ahi mismo, asi que
-- necesita mostrar a que correo va dirigida: si no, el invitado tendria que
-- adivinarlo y solo se enteraria al fallar.
--
-- El codigo de la liga ya es el secreto que protege esto: son 12 caracteres
-- aleatorios y quien la tiene es a quien se la mandaron. La cedula sigue
-- sin exponerse, que no hace falta para crear la cuenta.

-- Se elimina primero porque cambia el tipo de retorno: CREATE OR REPLACE
-- no puede agregar una columna a un RETURNS TABLE existente.
DROP FUNCTION IF EXISTS public.info_publica_invitacion(text);

CREATE FUNCTION public.info_publica_invitacion(p_codigo text)
  RETURNS TABLE (
    nombre_invitado    text,
    correo_invitado    text,
    nombre_consultorio text,
    nombre_responsable text,
    vigente            boolean
  )
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select i.nombre,
         i.correo,
         c.nombre,
         p.nombre,
         (i.usada_por is null and i.expira_en > now())
    from invitaciones_consultorio i
    join consultorios c on c.id = i.consultorio_id
    join psicologos  p on p.id = c.dueno_id
   where i.codigo = p_codigo;
$function$;

REVOKE ALL ON FUNCTION public.info_publica_invitacion(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.info_publica_invitacion(text) TO anon;
GRANT EXECUTE ON FUNCTION public.info_publica_invitacion(text) TO authenticated;
