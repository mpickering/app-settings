{-# LANGUAGE DeriveDataTypeable #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
module Data.Serialization (
    Conf,
    SettingInfo(..),
    readConfigFile,
    writeConfigFile,
    ParseException) where

import System.IO
import qualified Data.Text.IO as T
import qualified Data.Map as M
import Text.ParserCombinators.Parsec
import Text.Parsec.Text as T
import Control.Monad (unless, when)
import Control.Exception (throwIO, Exception)
import Data.Typeable (Typeable)
import System.Directory (doesFileExist, copyFile)
import Control.Applicative ((<$>))
import Data.Maybe

data SettingInfo = SettingInfo { value :: String, userSet :: Bool } deriving (Show, Eq)

-- | The in-memory configuration data.
type Conf = M.Map String SettingInfo

-- | The configuration file is in an invalid format.
data ParseException = ParseException FilePath String
    deriving (Show, Typeable)
instance Exception ParseException

readConfigFile :: FilePath -> IO Conf
readConfigFile path = do
    contents <- T.readFile path
    case parse parseConfigFile "" contents of
        Left pe -> throwIO (ParseException path
            $ "Invalid configuration file " ++ show (errorPos pe))
        Right v -> return v

data ConfigElement = ConfigEntry String String | Comment

isConfigEntry :: ConfigElement -> Bool
isConfigEntry (ConfigEntry _ _) = True
isConfigEntry _ = False

parseConfigFile :: T.GenParser st Conf
parseConfigFile = do
    elements <- many $ comment <|> configEntry <|> emptyLine
    let configEntries = filter isConfigEntry elements
    return $ M.fromList $ map (\(ConfigEntry a b) ->
        (a, SettingInfo {value=b, userSet=True})) configEntries

comment :: T.GenParser st ConfigElement
comment = char '#' >> finishLine >> return Comment

configEntry :: T.GenParser st ConfigElement
configEntry = do
    key <- many1 $ noneOf " \t=\r\n"
    char '='
    val <- finishLine
    -- so now we finished the parsing of the classical
    -- key=value, however we support a little bit more,
    -- you can do something like that:
    -- key=[1,2,
    --  3,4,
    --  5, 6]
    -- In that case the value will be
    --  "[1,2,3,4,5, 6]"
    --  => we can continue a setting on the next
    --  line if that lines starts with a leading space.
    blank   <- optionMaybe $ string " "
    fullVal <- if isNothing blank
        then return val
        else do
            firstExtraLine <- finishLine
            rest <- concat <$> many (string " " >> finishLine)
            return $ val ++ firstExtraLine ++ rest
    return $ ConfigEntry key fullVal

finishLine :: T.GenParser st String
finishLine = do
    result <- many $ noneOf "\r\n"
    many1 $ oneOf "\r\n"
    return result

emptyLine :: T.GenParser st ConfigElement
emptyLine = do
    many1 $ oneOf "\r\n"
    return Comment

writeConfigFile :: FilePath -> Conf -> IO ()
writeConfigFile path config = do
    whenM (doesFileExist path) $
        copyFile path $ path ++ ".bak"
    withFile path WriteMode $ \handle -> do
        hPutStrLn handle "# This file is autogenerated. You can change, comment and uncomment settings but text comments you may add will be lost."
        mapM_ (uncurry $ writeConfigEntry handle) $ M.toList config
    where whenM s r = s >>= flip when r

writeConfigEntry :: Handle -> String -> SettingInfo -> IO ()
writeConfigEntry handle key (SettingInfo sValue sUserSet) = do
    unless sUserSet $ hPutStr handle "# "
    hPutStrLn handle $ key ++ "=" ++ wrap sValue

wrap :: String -> String
wrap str = if null rest
        then str
        else first ++ "\n " ++ wrap rest
    where (first, rest) = splitAt 80 str
