-- Enlaza cada plan con su precio recurrente en Stripe.
-- Son identificadores publicos: dicen que precio cobrar, no dan acceso a la
-- cuenta. La clave secreta va aparte, en los secretos del proyecto.

UPDATE public.planes
   SET stripe_price_id = 'price_1U46VAFieIkYL4soLLYq7xpX'
 WHERE id = 'individual';

UPDATE public.planes
   SET stripe_price_id = 'price_1U46WcFieIkYL4somAGHkyMN'
 WHERE id = 'consultorio';
