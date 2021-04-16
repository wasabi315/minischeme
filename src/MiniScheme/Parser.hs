{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module MiniScheme.Parser
  ( parseProg,
    parseExp,
    ParseError,
  )
where

import Control.Exception.Safe
import Control.Monad
import Data.Bifunctor
import Data.Char
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void
import MiniScheme.AST qualified as AST
import Text.Megaparsec hiding (ParseError)
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer qualified as Lexer
import Text.Megaparsec.Error.Builder

parseProg :: Text -> Either ParseError AST.Prog
parseProg = first ParseError . parse pProg ""

parseExp :: Text -> Either ParseError AST.Exp
parseExp = first ParseError . parse pExp ""

newtype ParseError = ParseError (ParseErrorBundle Text Void)

instance Show ParseError where
  show (ParseError e) = errorBundlePretty e

instance Exception ParseError

-- The parser type
type Parser = Parsec Void Text

pProg :: Parser AST.Prog
pProg =
  choice
    [ AST.Def <$> pDefine,
      AST.Exp <$> pExp
    ]

pDefine :: Parser AST.Def
pDefine =
  parened do
    _ <- string "define"
    space1
    i <- pId
    space1
    e <- pExp
    pure $! AST.Const i e

pExp :: Parser AST.Exp
pExp =
  choice
    [ AST.Atom <$> pAtom,
      parened do
        f : xs <- pExp `sepEndBy1` space1
        pure $ AST.App f xs
    ]

pAtom :: Parser AST.Atom
pAtom =
  choice
    [ AST.Bool True <$ string "#t",
      AST.Bool False <$ string "#f",
      AST.Int <$> Lexer.decimal,
      AST.Str <$> pStr,
      AST.Id <$> pId
    ]

pStr :: Parser Text
pStr = between (char '"') (char '"') (Text.concat <$!> many pStr')
  where
    pStr' =
      choice
        [ do
            _ <- char '\\'
            choice
              [ "\n" <$ string "n",
                "\r" <$ string "r",
                "\t" <$ string "t",
                "\"" <$ string "\"",
                "\\" <$ string "\\"
              ],
          takeWhile1P Nothing \c -> c /= '\\' && c /= '"'
        ]

pId :: Parser AST.Id
pId = do
  o <- getOffset
  i <- takeWhile1P Nothing \c ->
    isAlphaNum c
      || c `elem` ("!$%&*+-./<=>?@^_" :: String)
  if i == "."
    then parseError (err o (utok '.'))
    else pure i

parened :: Parser a -> Parser a
parened = between (char '(' *> space) (space <* char ')')
