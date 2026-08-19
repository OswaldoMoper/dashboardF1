-- | Cliente Jolpica (Ergast) — plumbing HTTP de estadísticas históricas.
--
-- Acceso a la API pública de Jolpica (@api.jolpi.ca\/ergast\/f1@) con el cliente
-- @req@. Base de URL propia: NO reusa 'Handler.OpenF1.Manager.fetchList', que está
-- fijado a @openf1Base@ + @session_key=latest@. Si más adelante hay >1 consumidor de
-- Jolpica, se extraerá un cliente compartido (mismo criterio que OpenF1).
--
-- Lo que sí comparte con OpenF1 es la __política de fallo__, y vive en
-- 'Handler.PublicApi.Manager': las dos son redes públicas y no pueden degradar a
-- velocidades distintas. Se importa de allí y no de 'Handler.OpenF1.Manager' para
-- que este cliente no dependa del otro.
module Handler.Historical.Manager
  ( jolpicaBase
  , fetchStandings
  , fetchConstructorStandings
  ) where

import           Config                    (Config)
import           Handler.Historical.Helper (Root)
import           Handler.PublicApi.Manager (publicApiConfig, publicApiOptions)
import           Network.HTTP.Req

-- | Base de la API pública de Jolpica (sucesor de Ergast).
jolpicaBase :: Url 'Https
jolpicaBase = https "api.jolpi.ca" /: "ergast" /: "f1"

-- | Clasificación de pilotos de la temporada en curso (@\/current\/driverStandings@),
-- decodificada a la envoltura 'Root'.
fetchStandings :: Config -> IO Root
fetchStandings cfg = runReq publicApiConfig $ do
  res <-
    req
      GET
      (jolpicaBase /: "current" /: "driverStandings")
      NoReqBody
      jsonResponse
      (publicApiOptions cfg)
  pure (responseBody res)

-- | Clasificación de constructores de la temporada en curso
-- (@\/current\/constructorStandings@). Misma envoltura 'Root': el nivel
-- @StandingsList@ trae @ConstructorStandings@ en vez de @DriverStandings@ y ambas
-- claves son opcionales allí.
fetchConstructorStandings :: Config -> IO Root
fetchConstructorStandings cfg = runReq publicApiConfig $ do
  res <-
    req
      GET
      (jolpicaBase /: "current" /: "constructorStandings")
      NoReqBody
      jsonResponse
      (publicApiOptions cfg)
  pure (responseBody res)
