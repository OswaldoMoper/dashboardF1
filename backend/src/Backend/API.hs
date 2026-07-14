-- | API del backend del F1 Functional Dashboard.
--
-- Fase 1: además del endpoint raíz @GET \/home@, expone los endpoints stub de
-- widgets bajo @\/api@ con datos dummy estáticos. Se añaden @\/api\/live@ y @\/api\/historical@.
module Backend.API where

import Common.Types (HistoricalStat (..), LiveTimingRow (..))
import Data.Aeson (ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Servant

-- | Respuesta del endpoint raíz.
newtype Home = Home {message :: Text}
  deriving (Eq, Show, Generic)

instance ToJSON Home

-- | API completa del backend.
--
-- @GET \/home@ → JSON de bienvenida; @GET \/api\/live@ y @GET \/api\/historical@
-- → datos dummy tipados desde @Common.Types@.
type API =
       "home" :> Get '[JSON] Home
  :<|> "api" :> "live" :> Get '[JSON] [LiveTimingRow]
  :<|> "api" :> "historical" :> Get '[JSON] [HistoricalStat]

api :: Proxy API
api = Proxy

server :: Server API
server = homeH :<|> liveH :<|> historicalH
  where
    homeH :: Handler Home
    homeH = pure (Home "F1 Functional Dashboard")

    liveH :: Handler [LiveTimingRow]
    liveH = pure liveDummy

    historicalH :: Handler [HistoricalStat]
    historicalH = pure historicalDummy

-- | Datos dummy de live timing (top 3 estático).
liveDummy :: [LiveTimingRow]
liveDummy =
  [ LiveTimingRow 1 "VER" "Red Bull" "LEADER" "-" "1:29.345"
  , LiveTimingRow 2 "LEC" "Ferrari" "+1.234" "+1.234" "1:29.512"
  , LiveTimingRow 3 "NOR" "McLaren" "+3.877" "+2.643" "1:29.701"
  ]

-- | Datos dummy de estadísticas históricas.
historicalDummy :: [HistoricalStat]
historicalDummy =
  [ HistoricalStat "Wins" 63 "races"
  , HistoricalStat "Pole positions" 44 "quali"
  , HistoricalStat "Fastest laps" 34 "laps"
  ]
