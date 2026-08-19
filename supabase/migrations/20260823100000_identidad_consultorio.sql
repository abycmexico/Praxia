-- IDENTIDAD DEL CONSULTORIO Y DEL PSICOLOGO
--
-- Hasta ahora un consultorio solo tenia nombre y logo. Todo lo demas que ve
-- el paciente -a que hora atienden, a donde llamar, de que se trata el
-- lugar- se lo tenia que preguntar por WhatsApp.
--
-- Estos datos no son decorativos: son los que salen impresos en las
-- constancias y los informes, que son documentos que el paciente entrega en
-- su escuela o su trabajo.

ALTER TABLE public.configuracion
  ADD COLUMN IF NOT EXISTS lema               text,
  ADD COLUMN IF NOT EXISTS descripcion        text,
  ADD COLUMN IF NOT EXISTS telefono_contacto  text,
  ADD COLUMN IF NOT EXISTS correo_contacto    text,
  ADD COLUMN IF NOT EXISTS sitio_web          text,
  ADD COLUMN IF NOT EXISTS direccion_consultorio text,
  ADD COLUMN IF NOT EXISTS horario_atencion   text;

COMMENT ON COLUMN public.configuracion.lema IS
  'Una linea corta bajo el nombre. Lo ve el paciente al entrar a su panel.';
COMMENT ON COLUMN public.configuracion.descripcion IS
  'Parrafo breve sobre el consultorio. Va en el panel del paciente y en los documentos.';
COMMENT ON COLUMN public.configuracion.telefono_contacto IS
  'El del consultorio, no el personal del psicologo: puede ser un conmutador o una recepcion.';

-- El psicologo tambien necesita presentarse. bio y foto_url ya existian; lo
-- que faltaba era como quiere que lo nombren y donde atiende.
ALTER TABLE public.psicologos
  ADD COLUMN IF NOT EXISTS titulo_profesional text,
  ADD COLUMN IF NOT EXISTS anios_experiencia  int,
  ADD COLUMN IF NOT EXISTS enfoque            text;

COMMENT ON COLUMN public.psicologos.titulo_profesional IS
  'Como quiere aparecer: Psic., Mtro., Dr. Se antepone a su nombre en documentos.';
COMMENT ON COLUMN public.psicologos.enfoque IS
  'Corriente con la que trabaja. Es de lo primero que pregunta un paciente que ya fue a terapia.';

-- ---------------------------------------------------------------------
-- Lo que el paciente puede ver de su consultorio
-- ---------------------------------------------------------------------
-- Va por funcion y no abriendo la tabla: configuracion guarda tambien
-- precios, politicas y reglas de agenda que no le tocan al paciente. Una
-- politica de RLS filtra filas, no columnas.
CREATE OR REPLACE FUNCTION public.identidad_de_mi_consultorio()
  RETURNS TABLE (
    nombre       text,
    lema         text,
    descripcion  text,
    telefono     text,
    correo       text,
    sitio_web    text,
    direccion    text,
    horario      text
  )
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
  AS $function$
  select c.nombre_consultorio, c.lema, c.descripcion, c.telefono_contacto,
         c.correo_contacto, c.sitio_web, c.direccion_consultorio, c.horario_atencion
    from configuracion c
    join pacientes p on p.psicologo_id = c.psicologo_id
   where p.id = public.mi_paciente_id();
$function$;

REVOKE ALL ON FUNCTION public.identidad_de_mi_consultorio() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.identidad_de_mi_consultorio() TO authenticated;
