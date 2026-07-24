-- | Área estrategia de neumáticos — capa de efectos.
--
-- GET a OpenF1 @/stints@ (sesión @latest@), decodificado al tipo crudo de
-- 'Handler.TyreStrategy.Helper' con el 'fetchList' del cliente compartido
-- 'Handler.OpenF1.Manager'. El cruce con @/drivers@ reusa 'fetchDrivers' del
-- mismo cliente (no se redefine aquí). Sin lógica de negocio.
module Handler.TyreStrategy.Manager where

import           Handler.OpenF1.Manager      (fetchList)
import           Handler.TyreStrategy.Helper (Of1Stint)

fetchStints :: IO [Of1Stint]
fetchStints = fetchList "stints"
