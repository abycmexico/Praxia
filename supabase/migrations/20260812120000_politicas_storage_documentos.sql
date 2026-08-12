-- El bucket 'documentos' y sus politicas se habian creado a mano en el
-- dashboard, sin quedar versionados ni auditables. Ahi viven documentos
-- clinicos, asi que es el lugar donde una politica de mas significa que un
-- consultorio alcance los archivos de otro.
--
-- Convenciones de ruta que usa el codigo hoy:
--   {psicologo_id}/consultorio/logo.ext     logo del consultorio
--   {psicologo_id}/perfil/foto.ext          foto del psicologo
--   {psicologo_id}/{paciente_id}/{archivo}  documentos clinicos
--   {paciente_id}/perfil/foto.ext           foto del paciente
--
-- Nota sobre el ultimo caso: ahi el primer segmento es el id del expediente,
-- no el del psicologo. Por eso no basta con una sola regla sobre el primer
-- nivel de carpeta.

-- Bucket privado. Todo acceso pasa por URLs firmadas, que es lo que el
-- codigo ya hace con createSignedUrl.
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('documentos', 'documentos', false, 26214400)
ON CONFLICT (id) DO UPDATE
  SET public = false,
      file_size_limit = COALESCE(storage.buckets.file_size_limit, 26214400);

-- Se recrean por nombre para que la migracion sea idempotente.
DROP POLICY IF EXISTS "psicologo administra su carpeta" ON storage.objects;
DROP POLICY IF EXISTS "paciente lee sus documentos" ON storage.objects;
DROP POLICY IF EXISTS "paciente sube sus documentos" ON storage.objects;
DROP POLICY IF EXISTS "paciente administra su perfil" ON storage.objects;

-- 1) El psicologo manda sobre todo lo que cuelga de su propia carpeta:
--    su logo, su foto y los documentos de sus pacientes.
CREATE POLICY "psicologo administra su carpeta"
  ON storage.objects FOR ALL
  TO authenticated
  USING (
    bucket_id = 'documentos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'documentos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- 2) El paciente lee unicamente los documentos de su propio expediente,
--    esten en la carpeta del psicologo que sea.
CREATE POLICY "paciente lee sus documentos"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'documentos'
    AND (storage.foldername(name))[2] = public.mi_paciente_id()::text
  );

-- 3) Y puede subir ahi mismo, pero no sobrescribir ni borrar: el expediente
--    lo administra el psicologo.
CREATE POLICY "paciente sube sus documentos"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'documentos'
    AND (storage.foldername(name))[2] = public.mi_paciente_id()::text
  );

-- 4) Su foto de perfil, que cuelga directo de su id de expediente.
CREATE POLICY "paciente administra su perfil"
  ON storage.objects FOR ALL
  TO authenticated
  USING (
    bucket_id = 'documentos'
    AND (storage.foldername(name))[1] = public.mi_paciente_id()::text
    AND (storage.foldername(name))[2] = 'perfil'
  )
  WITH CHECK (
    bucket_id = 'documentos'
    AND (storage.foldername(name))[1] = public.mi_paciente_id()::text
    AND (storage.foldername(name))[2] = 'perfil'
  );
