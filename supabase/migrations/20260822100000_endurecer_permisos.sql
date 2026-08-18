-- ENDURECIMIENTO DE PERMISOS
--
-- Hallazgo de la auditoria: en Praxia ninguna funcion le negaba el permiso a
-- un visitante sin cuenta. Las 56 funciones del esquema publico eran
-- ejecutables por cualquiera con la llave publicable, que esta a la vista en
-- el HTML porque asi debe estar.
--
-- La causa: Supabase concede EXECUTE a anon y authenticated por privilegios
-- por defecto del proyecto. Por eso el patron que veniamos usando
--     REVOKE ALL ON FUNCTION ... FROM PUBLIC
-- no servia de nada: anon no recibia el permiso por PUBLIC, lo recibia por su
-- propio grant. Hay que revocarle a anon por su nombre.
--
-- Casi todas las funciones se salvaban porque validan auth.uid() por dentro.
-- Pero dos no, y esas si eran explotables:
--
--   encolar_aviso            cualquiera podia meter un aviso push con el
--                            texto que quisiera en el telefono de un
--                            psicologo. Un "Tu paciente cancelo, entra aqui"
--                            falso es phishing directo sobre datos clinicos.
--   crear_estado_oauth_google  cualquiera podia insertar filas sin limite.
--
-- Depender de que cada funcion se defienda sola es fragil: basta que una
-- nueva se escriba sin la validacion. El permiso es la primera muralla y
-- estaba abierta.

-- ---------------------------------------------------------------------
-- 1. Solo estas cinco funciones tienen razon para ser publicas
-- ---------------------------------------------------------------------
-- Son las de las paginas a las que se llega por una liga, antes de tener
-- cuenta: confirmar una cita, aceptar una invitacion, activar el acceso de un
-- paciente. Todas piden un token que no se puede adivinar.
DO $$
DECLARE
  f record;
  publicas text[] := ARRAY[
    'obtener_cita_por_token',
    'aceptar_cita_por_token',
    'rechazar_cita_por_token',
    'info_publica_claim',
    'info_publica_invitacion'
  ];
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma, p.proname
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prokind = 'f'
       AND NOT (p.proname = ANY(publicas))
  LOOP
    -- Se revoca tambien de PUBLIC por si alguna quedo con ese grant.
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon, PUBLIC', f.firma);
  END LOOP;
END $$;

-- Se conceden por nombre y no dentro del bucle, para que quede escrito cuales
-- son: una lista explicita se revisa de un vistazo.
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('obtener_cita_por_token','aceptar_cita_por_token',
                         'rechazar_cita_por_token','info_publica_claim',
                         'info_publica_invitacion')
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.firma);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 2. Devolverle a authenticated lo que si necesita
-- ---------------------------------------------------------------------
-- El bucle de arriba revoco de anon, no de authenticated, asi que el panel
-- sigue funcionando. Esto solo repone las que se llaman desde la app.
DO $$
DECLARE
  f record;
  usadas text[] := ARRAY[
    'actualizar_mis_datos','aceptar_invitacion_consultorio','aprobar_solicitud_paciente',
    'cancelar_cita','cancelar_renovacion','canjear_codigo_acceso','cobro_de_la_sesion',
    'consultorios_con_equipo','consumir_sesion_de_plan','crear_cita_para_paciente',
    'crear_consulta_rapida','crear_estado_oauth_google','crear_paciente_directo',
    'crear_plan_de_paciente','definir_acceso_expedientes','desconectar_google_calendar',
    'es_admin','esta_conectado_google_calendar','limite_de_pacientes','mi_consultorio',
    'mi_cupo_de_pacientes','mi_estado_cobros','mi_paciente_id','mi_psicologo_cobra_en_linea',
    'mi_suscripcion','panorama_praxia','psicologos_con_actividad','puedo_ver_expedientes_de',
    'quitar_del_consultorio','quitar_dispositivo_push','reactivar_renovacion',
    'rechazar_solicitud_paciente','registrar_dispositivo_push','registrar_pago',
    'registrar_perfil_psicologo','renovar_mensualidad_paciente','reprogramar_cita',
    'solicitar_acceso_expedientes','solicitar_cita_paciente','soy_dueno_consultorio',
    'suscripcion_vigente','titular_de_mi_suscripcion','vincular_cuenta_paciente'
  ];
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = ANY(usadas)
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.firma);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 3. Las que nadie debe llamar desde fuera
-- ---------------------------------------------------------------------
-- encolar_aviso y despachar_avisos las usan los triggers y el cron, que
-- corren dentro de la base. Ningun navegador tiene por que alcanzarlas, ni
-- siquiera con sesion iniciada: un psicologo con cuenta tampoco deberia poder
-- mandarle avisos al telefono de otro.
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('encolar_aviso','despachar_avisos','revisar_limite_de_pacientes',
                         'crear_suscripcion_de_prueba','crear_config_por_defecto',
                         'notificar_solicitud_cita','notificar_pago_recibido',
                         'notificar_cancelacion')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon, authenticated, PUBLIC', f.firma);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 4. La comision de Praxia deja de ser publica
-- ---------------------------------------------------------------------
-- config_plataforma tenia una politica de lectura para todos, y ahi vive
-- comision_porcentaje. Solo la lee el panel de administracion, asi que no hay
-- motivo para que un competidor -o un psicologo- vea el margen del negocio.
DROP POLICY IF EXISTS "todos leen config plataforma" ON public.config_plataforma;
CREATE POLICY "solo el admin lee la config" ON public.config_plataforma
  FOR SELECT TO authenticated
  USING (public.es_admin());

-- La politica de edicion tenia el correo escrito a mano y no revisaba la fila
-- resultante: sin WITH CHECK se podia cambiar el id de la fila.
DROP POLICY IF EXISTS "admin edita config plataforma" ON public.config_plataforma;
CREATE POLICY "solo el admin edita la config" ON public.config_plataforma
  FOR UPDATE TO authenticated
  USING (public.es_admin()) WITH CHECK (public.es_admin());

-- ---------------------------------------------------------------------
-- 5. Un anonimo no escribe en nada clinico, ni aunque falle una politica
-- ---------------------------------------------------------------------
-- Hoy lo impide RLS. Quitarle tambien el permiso de tabla es la segunda
-- muralla: si algun dia una politica queda mal escrita, el permiso todavia
-- lo frena.
REVOKE INSERT, UPDATE, DELETE ON
  public.psicologos, public.pacientes, public.citas, public.notas_sesion,
  public.pagos, public.documentos, public.consentimientos, public.notificaciones,
  public.configuracion, public.evaluaciones_psicologicas, public.objetivos_terapeuticos,
  public.reportes_pacientes, public.medicamentos, public.disponibilidad,
  public.aceptaciones_terminos, public.auditoria, public.config_plataforma,
  public.google_calendar_tokens, public.google_oauth_estados
FROM anon;
