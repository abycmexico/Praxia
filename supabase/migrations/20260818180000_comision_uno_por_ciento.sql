-- Comision de Praxia sobre lo que se cobra por la plataforma: 1%.
--
-- Se deja baja a proposito. El psicologo ya paga su mensualidad, y encima
-- Stripe le cobra alrededor de 3.6% por transaccion. Con una comision alta
-- le saldria mas barato cobrar por transferencia y usar Praxia solo para
-- registrar, con lo que la funcion quedaria muerta. Al 1% no vale la pena
-- esquivarla.
--
-- Solo aplica a lo cobrado en linea: lo que se cobra en efectivo o por
-- transferencia se registra sin comision, porque ahi Praxia no pone nada.

UPDATE public.config_plataforma SET comision_porcentaje = 1.00;

COMMENT ON COLUMN public.config_plataforma.comision_porcentaje IS
  'Porcentaje que Praxia retiene de cada cobro hecho por la plataforma. Se aplica como application_fee en Stripe Connect: el dinero se reparte en el momento del pago.';
