-- | @dashboardF1-e2e-datos \<carpeta\>@: escribe en esa carpeta @api.har@ y
-- @live-feed-p3.json@, lo que la e2e sirve como @\/api\/*@ ('E2eDatos'). Sobrescribe
-- los dos.
module Main (main) where

import           Data.Aeson           (encode)
import qualified Data.ByteString.Lazy as BL
import           E2eDatos             (feedP3, harJson)
import           System.Environment   (getArgs)
import           System.Exit          (die)
import           System.FilePath      ((</>))

main :: IO ()
main = do
  args <- getArgs
  case args of
    [dir] -> do
      BL.writeFile (dir </> "api.har") (encode harJson)
      BL.writeFile (dir </> "live-feed-p3.json") (encode feedP3)
    _ -> die "uso: dashboardF1-e2e-datos <carpeta>"
