-- El panel de administracion no podia hacer su trabajo principal: aprobar
-- psicologos nuevos. La tabla psicologos solo tenia politicas
-- `auth.uid() = id`, asi que el admin se veia unicamente a si mismo en la
-- lista, y el boton Aprobar corria un UPDATE que RLS filtraba a cero filas.
-- Como un UPDATE que no afecta filas no es un error, admin.html mostraba
-- exito y el psicologo se quedaba en 'pendiente' para siempre.

-- El correo del admin estaba repetido literal en varias politicas. Se
-- centraliza aqui para que cambiarlo (o sumar otro admin) sea un solo lugar.
CREATE OR REPLACE FUNCTION public.es_admin()
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SET search_path TO 'public'
  AS $function$
  select coalesce(auth.jwt() ->> 'email', '') = 'abycmexico@gmail.com';
$function$;

REVOKE ALL ON FUNCTION public.es_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.es_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.es_admin() TO service_role;

DROP POLICY IF EXISTS "admin ve todos los psicologos" ON public.psicologos;
DROP POLICY IF EXISTS "admin cambia estado de psicologos" ON public.psicologos;

-- Ver la lista completa para poder revisar solicitudes nuevas.
CREATE POLICY "admin ve todos los psicologos" ON public.psicologos
  FOR SELECT
  TO authenticated
  USING (public.es_admin());

-- Y poder aprobarlos, suspenderlos o rechazarlos.
CREATE POLICY "admin cambia estado de psicologos" ON public.psicologos
  FOR UPDATE
  TO authenticated
  USING (public.es_admin())
  WITH CHECK (public.es_admin());
