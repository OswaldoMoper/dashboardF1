-- | Lo que quien monta una tarjeta le pone dentro, sin que la tarjeta sepa qué es: lo que
-- va junto a su título, lo que va bajo su cabecera, los pilotos que destacan sus filas y
-- las sesiones que se suman a la que se ve. Lo usan los grupos ('Widgets.Groups').
module Widgets.Card
  ( CardExtras (..)
  ) where

import           Common.Comparison (GroupPick)
import           Common.Session (SessionKey)
import           Data.Text      (Text)
import           Reflex.Dom     (Dynamic)

data CardExtras t m a = CardExtras
  { cardBeside    :: m ()
    -- ^ Junto al título, en la cabecera.
  , cardUnder     :: m a
    -- ^ Bajo la cabecera; lo que devuelve es lo que devuelve la tarjeta.
  , cardHighlight :: Dynamic t [Text]
    -- ^ Las siglas de los pilotos cuyas filas se destacan.
  , cardSessions  :: Dynamic t (Maybe SessionKey, [SessionKey])
    -- ^ La sesión que se ve ('Nothing' si no se sabe) y las que se le suman, en su orden.
  , cardPicks     :: Dynamic t [GroupPick]
    -- ^ Lo que cada grupo suma a Lap Comparison, en el orden de los grupos.
  }
