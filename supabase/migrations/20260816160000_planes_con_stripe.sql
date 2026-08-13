-- El identificador de precio de Stripe vive en el plan, no en el codigo.
-- Cambiar de precio o sumar un plan queda como un UPDATE, sin tocar ni
-- volver a desplegar las funciones.

ALTER TABLE public.planes
  ADD COLUMN IF NOT EXISTS stripe_price_id text;

COMMENT ON COLUMN public.planes.stripe_price_id IS
  'ID del precio recurrente en Stripe (price_...). No es secreto: identifica el precio, no da acceso.';

-- Los precios de la tabla deben coincidir con los de Stripe: si difieren, el
-- panel le muestra una cifra al psicologo y Stripe le cobra otra.
UPDATE public.planes SET precio_mensual = 399 WHERE id = 'individual';
UPDATE public.planes SET precio_mensual = 899 WHERE id = 'consultorio';
